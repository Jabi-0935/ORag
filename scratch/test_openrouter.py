import requests
import json

OPENROUTER_API_KEY = "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"
MODEL_ID = "google/gemini-flash-1.5"

def test_openrouter():
    print(f"Testing OpenRouter with model {MODEL_ID}...")
    try:
        response = requests.post(
            url="https://openrouter.ai/api/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {OPENROUTER_API_KEY}",
                "Content-Type": "application/json",
            },
            data=json.dumps({
                "model": MODEL_ID,
                "messages": [
                    {"role": "user", "content": "Hello, are you working?"}
                ]
            }),
            timeout=10
        )
        print(f"Status Code: {response.status_code}")
        print(f"Response: {response.text}")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    test_openrouter()
