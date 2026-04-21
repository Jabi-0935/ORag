package com.example.orag

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.chaquo.python.Python
import com.chaquo.python.PyObject
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
	private val CHANNEL = "orag"
	private val STREAM_CHANNEL = "orag_stream"
	private val INIT_CHANNEL = "orag_init_progress"

	@Volatile
	private var apiModule: PyObject? = null

	@Volatile
	private var streamSink: EventChannel.EventSink? = null

	@Volatile
	private var initSink: EventChannel.EventSink? = null

	/**
	 * Latch used to block the Kotlin handler thread until Python's
	 * worker finishes generation (signalled by the __DONE__ sentinel).
	 * Without this, the handler returns immediately because
	 * api.chat_stream() / api.ask_rag() are non-blocking (they
	 * dispatch to a background worker and return "OK" at once).
	 */
	@Volatile
	private var streamDoneLatch: CountDownLatch? = null

	/**
	 * Captured sources JSON from the __SOURCES__ sentinel token.
	 * Set by onStreamToken when it intercepts a __SOURCES__:{json} token
	 * during RAG streaming, then read by the ragStream handler to include
	 * in the MethodChannel result.
	 */
	@Volatile
	private var capturedSourcesJson: String? = null

	/**
	 * Called from Python (via Chaquopy invoke) for each generated token.
	 * Runs synchronously on the Python worker thread.
	 *
	 * Intercepts sentinel tokens (__DONE__, __BUSY__, __SOURCES__) and
	 * only forwards real content tokens to the Flutter EventChannel sink.
	 */
	fun onStreamToken(token: String) {
		// Intercept __DONE__ — Python's end-of-stream sentinel.
		// Send __STREAM_END__ to Flutter and signal the latch so the
		// Kotlin handler thread can return the MethodChannel result.
		if (token == "__DONE__") {
			runOnUiThread {
				streamSink?.success("__STREAM_END__")
			}
			streamDoneLatch?.countDown()
			return
		}

		// Intercept __BUSY__ — worker queue is full.
		if (token == "__BUSY__") {
			runOnUiThread {
				streamSink?.success("__BUSY__")
			}
			streamDoneLatch?.countDown()
			return
		}

		// Intercept __SOURCES__:{json} — RAG source attribution data.
		// Store the JSON for later inclusion in the MethodChannel result.
		// This arrives BEFORE __DONE__ (Python sends sources first).
		if (token.startsWith("__SOURCES__:")) {
			capturedSourcesJson = token.removePrefix("__SOURCES__:")
			return
		}

		// Regular content token — forward to Flutter
		runOnUiThread {
			streamSink?.success(token)
		}
	}

	/**
	 * Called from Python (via Chaquopy invoke) for init progress events.
	 * Forwards JSON string to the Flutter init EventChannel sink.
	 */
	fun onInitProgress(jsonData: String) {
		runOnUiThread {
			initSink?.success(jsonData)
		}
	}

	private fun ensureApiModule(): PyObject {
		apiModule?.let { return it }
		synchronized(this) {
			apiModule?.let { return it }
			if (!Python.isStarted()) {
				Python.start(AndroidPlatform(this))
			}

			// Inject Android paths into llm_runtime module before any init runs.
			try {
				val llmRuntime = Python.getInstance().getModule("llm_runtime")
				val nativeLibDir = applicationInfo.nativeLibraryDir
				val filesDir = filesDir.absolutePath
				llmRuntime.callAttr("set_android_paths", nativeLibDir, filesDir)
				Log.i("ORAG", "Injected nativeLibraryDir=$nativeLibDir, filesDir=$filesDir")
			} catch (e: Exception) {
				Log.w("ORAG", "Failed to inject Android paths", e)
			}

			val module = Python.getInstance().getModule("api")
			apiModule = module
			return module
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		// --- EventChannel for streaming tokens ---
		EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					streamSink = events
					Log.d("ORAG", "Stream listener attached")
				}
				override fun onCancel(arguments: Any?) {
					streamSink = null
					Log.d("ORAG", "Stream listener cancelled")
				}
			})

		// --- EventChannel for init progress ---
		EventChannel(flutterEngine.dartExecutor.binaryMessenger, INIT_CHANNEL)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					initSink = events
					Log.d("ORAG", "Init progress listener attached")
				}
				override fun onCancel(arguments: Any?) {
					initSink = null
					Log.d("ORAG", "Init progress listener cancelled")
				}
			})

		// --- MethodChannel for RPC calls ---
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
			.setMethodCallHandler { call, result ->
				if (call.method == "initPython") {
					val modelPath = call.argument<String>("model_path") ?: ""

					Thread {
						try {
							val api = ensureApiModule()
							api.callAttr(
								"init_with_progress",
								modelPath,
								this@MainActivity::onInitProgress
							)

							runOnUiThread {
								result.success(true)
							}
							Log.i("ORAG", "Python init completed: $modelPath")
						} catch (e: Exception) {
							val errorJson = """{"state":"error","progress":1.0,"message":"${e.message?.replace("\"", "\\\"") ?: "Unknown error"}"}"""
							runOnUiThread {
								initSink?.success(errorJson)
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "Python init failed", e)
						}
					}.start()

				} else if (call.method == "getStatus") {
					Thread {
						try {
							val api = ensureApiModule()
							val statusObj = api.callAttr("get_status")

							val statusMap = HashMap<String, Any?>()
							val pyDict = statusObj.asMap()
							for ((key, value) in pyDict) {
								val k = key.toString()
								when (k) {
									"state" -> statusMap[k] = value.toString()
									"progress" -> statusMap[k] = value.toDouble()
									"message" -> statusMap[k] = value.toString()
								}
							}

							runOnUiThread {
								result.success(statusMap)
							}
						} catch (e: Exception) {
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
						}
					}.start()

				} else if (call.method == "chatStream") {
					val query = call.argument<String>("query") ?: ""

					Thread {
						try {
							val api = ensureApiModule()

							// Create a latch so we block this thread until
							// Python's worker finishes (sends __DONE__).
							val latch = CountDownLatch(1)
							streamDoneLatch = latch

							// chat_stream() returns "OK" immediately (non-blocking).
							// Tokens arrive asynchronously via onStreamToken().
							val response = api.callAttr(
								"chat_stream", query, this@MainActivity::onStreamToken
							)

							// If the worker rejected the task (BUSY), the __BUSY__
							// sentinel already signalled the latch in onStreamToken.
							// Otherwise, wait for __DONE__ (up to 5 minutes).
							latch.await(300, TimeUnit.SECONDS)

							runOnUiThread {
								// __STREAM_END__ was already sent by onStreamToken
								// when it saw __DONE__. Just return the result.
								result.success(response.toString())
							}
						} catch (e: Exception) {
							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "chatStream failed", e)
						} finally {
							streamDoneLatch = null
						}
					}.start()

				} else if (call.method == "stop") {
					// Cancel active generation via the GenerationController.
					// This sets a threading.Event that the HTTP streaming loop
					// checks — the loop breaks early and the worker completes.
					Thread {
						try {
							ensureApiModule().callAttr("cancel_generation")
							runOnUiThread { result.success(true) }
						} catch (e: Exception) {
							runOnUiThread { result.success(true) }  // non-fatal
						}
					}.start()

				} else if (call.method == "clearMemory") {
					Thread {
						try {
							ensureApiModule().callAttr("clear_memory")
							runOnUiThread { result.success(true) }
						} catch (e: Exception) {
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
						}
					}.start()

				// ---- Document management ----

				} else if (call.method == "uploadDocument") {
					val filePath = call.argument<String>("file_path") ?: ""
					Thread {
						try {
							val response = ensureApiModule().callAttr("upload_document", filePath)
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
							Log.e("ORAG", "uploadDocument failed", e)
						}
					}.start()

				} else if (call.method == "listDocuments") {
					Thread {
						try {
							val response = ensureApiModule().callAttr("list_docs")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}.start()

				} else if (call.method == "deleteDocument") {
					val docId = call.argument<Int>("doc_id") ?: 0
					Thread {
						try {
							val response = ensureApiModule().callAttr("delete_doc", docId)
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}.start()

				} else if (call.method == "clearDocuments") {
					Thread {
						try {
							val response = ensureApiModule().callAttr("clear_docs")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}.start()

				// ---- RAG streaming ----

				} else if (call.method == "ragStream") {
					val query = call.argument<String>("query") ?: ""
					Thread {
						try {
							val api = ensureApiModule()
							capturedSourcesJson = null

							val latch = CountDownLatch(1)
							streamDoneLatch = latch

							// ask_rag() returns "OK" immediately (non-blocking).
							// Python sends __SOURCES__ then __DONE__ via callback.
							val response = api.callAttr(
								"ask_rag", query, this@MainActivity::onStreamToken
							)

							// Wait for __DONE__ (up to 5 minutes)
							latch.await(300, TimeUnit.SECONDS)

							// By now, __SOURCES__ has been captured (it arrives
							// before __DONE__), and __STREAM_END__ was sent to
							// Flutter by onStreamToken.
							val sources = capturedSourcesJson ?: "[]"
							val resultJson = """{"status":"${response.toString()}","sources":$sources}"""

							runOnUiThread {
								result.success(resultJson)
							}
						} catch (e: Exception) {
							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "ragStream failed", e)
						} finally {
							streamDoneLatch = null
						}
					}.start()

				} else if (call.method == "getEngineHealth") {
					Thread {
						try {
							val response = ensureApiModule().callAttr("get_engine_health")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}.start()

				} else {
					result.notImplemented()
				}
			}
	}
}
