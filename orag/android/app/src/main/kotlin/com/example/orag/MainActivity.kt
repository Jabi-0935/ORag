package com.example.orag

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.chaquo.python.Python
import com.chaquo.python.PyObject
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import android.util.Log
import java.util.concurrent.Executors

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

	// Cache the last init progress event so we can replay it when
	// a new EventChannel listener attaches (survives stream reconnections).
	@Volatile
	private var lastInitJson: String? = null

	// Track whether init has been started (to avoid re-triggering)
	@Volatile
	private var initStarted: Boolean = false

	// Cached status for non-blocking getStatus calls
	@Volatile
	private var cachedStatus: HashMap<String, Any?> = hashMapOf(
		"state" to "idle",
		"progress" to 0.0,
		"message" to "Preparing AI engine…"
	)

	// Managed thread pool: serializes Python calls (GIL already serializes),
	// prevents thread exhaustion from rapid user input
	private val pythonExecutor = Executors.newSingleThreadExecutor { r ->
		Thread(r, "orag-python").apply { isDaemon = true }
	}

	/**
	 * Called from Python (via Chaquopy invoke) for each generated token.
	 * Forwards the token to the Flutter EventChannel sink on the UI thread.
	 */
	fun onStreamToken(token: String) {
		runOnUiThread {
			streamSink?.success(token)
		}
	}

	/**
	 * Called from Python (via Chaquopy invoke) for init progress events.
	 * Forwards JSON string to the Flutter init EventChannel sink.
	 * Also caches the event and updates cachedStatus for polling fallback.
	 */
	fun onInitProgress(jsonData: String) {
		lastInitJson = jsonData
		// Update cached status from the JSON
		try {
			val parsed = org.json.JSONObject(jsonData)
			val newStatus = HashMap<String, Any?>()
			newStatus["state"] = parsed.optString("state", "idle")
			newStatus["progress"] = parsed.optDouble("progress", 0.0)
			newStatus["message"] = parsed.optString("message", "")
			cachedStatus = newStatus
		} catch (e: Exception) {
			Log.w("ORAG", "Failed to parse init JSON for cache", e)
		}
		runOnUiThread {
			initSink?.success(jsonData)
		}
	}

	private fun ensureApiModule(): PyObject {
		apiModule?.let { return it }
		synchronized(this) {
			apiModule?.let { return it }
			if (!Python.isStarted()) {
				Log.i("ORAG", "Starting Python runtime...")
				Python.start(AndroidPlatform(this))
				Log.i("ORAG", "Python runtime started.")
			}

			// Inject Android paths into llm module before any init runs.
			try {
				val llm = Python.getInstance().getModule("llm")
				val nativeLibDir = applicationInfo.nativeLibraryDir
				val filesDir = filesDir.absolutePath
				Log.i("ORAG", "Injecting paths: lib=$nativeLibDir, files=$filesDir")
				llm.callAttr("set_android_paths", nativeLibDir, filesDir)
			} catch (e: Exception) {
				Log.w("ORAG", "Failed to inject Android paths", e)
			}

			Log.i("ORAG", "Loading 'api' module...")
			val module = Python.getInstance().getModule("api")
			Log.i("ORAG", "'api' module loaded successfully.")
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
		// When a new listener attaches, immediately replay the last cached
		// progress event so the UI doesn't get stuck on "Preparing…".
		EventChannel(flutterEngine.dartExecutor.binaryMessenger, INIT_CHANNEL)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					initSink = events
					Log.d("ORAG", "Init progress listener attached")
					// Replay last known event immediately
					val cached = lastInitJson
					if (cached != null) {
						Log.d("ORAG", "Replaying cached init event: $cached")
						events?.success(cached)
					}
				}
				override fun onCancel(arguments: Any?) {
					// Do NOT null out initSink — keep forwarding events even
					// if Flutter temporarily disconnects the stream.
					Log.d("ORAG", "Init progress listener cancelled (sink kept)")
				}
			})

		// --- MethodChannel for RPC calls ---
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
			.setMethodCallHandler { call, result ->
				if (call.method == "initPython") {
					val modelPath = call.argument<String>("model_path") ?: ""

					pythonExecutor.execute {
						try {
							val api = ensureApiModule()

							// Use init_with_progress which pushes events via onInitProgress
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
							// Route error through onInitProgress to update cached status
							val errorJson = """{"state":"error","progress":1.0,"message":"${e.message?.replace("\"", "\\\"") ?: "Unknown error"}"}"""
							onInitProgress(errorJson)
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "Python init failed", e)
						}
					}

				} else if (call.method == "getStatus") {
					// Non-blocking: return the cached status from onInitProgress
					// instead of calling into Python (which would deadlock on
					// the init lock if init_with_progress is still running).
					result.success(HashMap(cachedStatus))

				} else if (call.method == "chatStream") {
					val query = call.argument<String>("query") ?: ""

					pythonExecutor.execute {
						try {
							val api = ensureApiModule()

							// Pass a Kotlin method reference to Python.
							// Chaquopy makes it callable via .invoke() on
							// the Python side.
							val response = api.callAttr(
								"chat_stream", query, this@MainActivity::onStreamToken
							)

							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								result.success(response.toString())
							}
						} catch (e: Exception) {
							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "chatStream failed", e)
						}
					}

				} else if (call.method == "chat") {
					val query = call.argument<String>("query") ?: ""

					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("chat", query)

							runOnUiThread {
								result.success(response.toString())
							}
						} catch (e: Exception) {
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
						}
					}
				} else if (call.method == "stop") {
					pythonExecutor.execute {
						try {
							ensureApiModule().callAttr("stop_generation")
							runOnUiThread { result.success(true) }
						} catch (e: Exception) {
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
						}
					}
				} else if (call.method == "clearMemory") {
					pythonExecutor.execute {
						try {
							ensureApiModule().callAttr("clear_memory")
							runOnUiThread { result.success(true) }
						} catch (e: Exception) {
							runOnUiThread {
								result.error("ERROR", e.message, null)
							}
						}
					}

				// ---- Document management ----

				} else if (call.method == "uploadDocument") {
					val filePath = call.argument<String>("file_path") ?: ""
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("upload_document", filePath)
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
							Log.e("ORAG", "uploadDocument failed", e)
						}
					}

				} else if (call.method == "listDocuments") {
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("list_docs")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}

				} else if (call.method == "deleteDocument") {
					val docId = call.argument<Int>("doc_id") ?: 0
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("delete_doc", docId)
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}

				} else if (call.method == "clearDocuments") {
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("clear_docs")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}

				// ---- RAG streaming ----

				} else if (call.method == "ragStream") {
					val query = call.argument<String>("query") ?: ""
					pythonExecutor.execute {
						try {
							val api = ensureApiModule()
							val response = api.callAttr(
								"ask_rag", query, this@MainActivity::onStreamToken
							)
							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								// response is JSON with answer + sources
								result.success(response.toString())
							}
						} catch (e: Exception) {
							runOnUiThread {
								streamSink?.success("__STREAM_END__")
								result.error("ERROR", e.message, null)
							}
							Log.e("ORAG", "ragStream failed", e)
						}
					}

				} else if (call.method == "getEngineHealth") {
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("get_engine_health")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}

				} else if (call.method == "getInitLogs") {
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("get_init_logs")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.success("Failed to get logs: ${e.message}") }
						}
					}

				} else if (call.method == "getResourceUsage") {
					pythonExecutor.execute {
						try {
							val response = ensureApiModule().callAttr("get_resource_usage")
							runOnUiThread { result.success(response.toString()) }
						} catch (e: Exception) {
							runOnUiThread { result.error("ERROR", e.message, null) }
						}
					}

				} else {
					result.notImplemented()
				}
			}
	}
}
