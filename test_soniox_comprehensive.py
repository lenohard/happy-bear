#!/usr/bin/env python3
"""
Soniox API comprehensive test with real audio file.
Tests file upload → transcription creation → polling → retrieval.
"""

import os
import sys
import time
import json
import requests
from pathlib import Path

SONIOX_API_BASE_URL = "https://api.soniox.com"

def main():
    # Get API key
    api_key = os.environ.get("SONIOX_API_KEY")
    if not api_key:
        print("❌ SONIOX_API_KEY not set. Run: export SONIOX_API_KEY=<your-key>")
        return False

    # Find test audio file
    test_audio = Path("/Users/senaca/projects/audiobook-player/AudiobookPlayer/test-1min.mp3")
    if not test_audio.exists():
        print(f"❌ Test audio not found: {test_audio}")
        return False

    file_size = test_audio.stat().st_size
    print(f"📝 Test Audio: {test_audio.name} ({file_size / 1024:.1f} KB)")
    print(f"🔑 API Key: {api_key[:20]}...")
    print(f"🌐 Base URL: {SONIOX_API_BASE_URL}\n")

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {api_key}"

    try:
        # === Step 1: Upload File ===
        print("=" * 60)
        print("📤 STEP 1: Uploading Audio File")
        print("=" * 60)

        with open(test_audio, "rb") as f:
            res = session.post(
                f"{SONIOX_API_BASE_URL}/v1/files",
                files={"file": f}
            )

        print(f"Request: POST /v1/files")
        print(f"Status Code: {res.status_code}")

        if res.status_code not in (200, 201):
            print(f"❌ FAILED: {res.text}")
            return False

        file_response = res.json()
        file_id = file_response.get("id")
        print(f"✅ SUCCESS")
        print(f"   File ID: {file_id}")
        print(f"   Created: {file_response.get('created_at')}")
        print()

        # === Step 2: Create Transcription ===
        print("=" * 60)
        print("🎯 STEP 2: Create Transcription Job")
        print("=" * 60)

        config = {
            "file_id": file_id,
            "model": "stt-async-preview",
            "language_hints": ["zh", "en"],
            "enable_speaker_diarization": True,
            "enable_language_identification": True,
            "context": "Audiobook transcription"
        }

        res = session.post(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions",
            json=config
        )

        print(f"Request: POST /v1/transcriptions")
        print(f"Payload: {json.dumps(config, indent=2)}")
        print(f"Status Code: {res.status_code}")

        if res.status_code not in (200, 201):
            print(f"❌ FAILED: {res.text}")
            return False

        transcription_response = res.json()
        transcription_id = transcription_response.get("id")
        print(f"✅ SUCCESS")
        print(f"   Transcription ID: {transcription_id}")
        print(f"   Status: {transcription_response.get('status')}")
        print(f"   Created: {transcription_response.get('created_at')}")
        print()

        # === Step 3: Poll for Completion ===
        print("=" * 60)
        print("⏳ STEP 3: Wait for Transcription (max 120 seconds)")
        print("=" * 60)

        start_time = time.time()
        poll_count = 0

        while True:
            res = session.get(
                f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}"
            )

            if res.status_code != 200:
                print(f"❌ Status check failed: {res.status_code}")
                return False

            status_data = res.json()
            status = status_data.get("status")
            elapsed = time.time() - start_time
            poll_count += 1

            if status == "completed":
                print(f"✅ COMPLETED in {elapsed:.1f}s ({poll_count} polls)")
                break
            elif status == "error":
                error_msg = status_data.get("error_message", "Unknown")
                print(f"❌ ERROR: {error_msg}")
                return False
            else:
                if poll_count == 1 or poll_count % 10 == 0:
                    print(f"   [{elapsed:.1f}s] Status: {status}")

            if elapsed > 120:
                print(f"❌ Timeout after 120s")
                return False

            time.sleep(1)

        print()

        # === Step 4: Retrieve Transcript ===
        print("=" * 60)
        print("📥 STEP 4: Retrieve Transcript")
        print("=" * 60)

        res = session.get(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}/transcript"
        )

        print(f"Request: GET /v1/transcriptions/{transcription_id}/transcript")
        print(f"Status Code: {res.status_code}")

        if res.status_code != 200:
            print(f"❌ FAILED: {res.text}")
            return False

        transcript_data = res.json()
        tokens = transcript_data.get("tokens", [])

        print(f"✅ SUCCESS")
        print(f"   Token Count: {len(tokens)}")

        # Extract text and stats
        if tokens:
            text_parts = []
            for token in tokens:
                text_parts.append(token.get("text", ""))

            full_text = "".join(text_parts)
            first_token_ms = tokens[0].get("start_ms", 0)
            last_token = tokens[-1]
            last_end_ms = last_token.get("end_ms") or (last_token.get("start_ms", 0) + last_token.get("duration_ms", 0))

            duration_sec = (last_end_ms or 0) / 1000.0

            print(f"   Text Length: {len(full_text)} characters")
            print(f"   Duration: {duration_sec:.1f} seconds")
            print(f"\n   Preview (first 300 chars):")
            print(f"   {full_text[:300]}")
            if len(full_text) > 300:
                print("   ...")

        print()

        # === Step 5: Cleanup ===
        print("=" * 60)
        print("🧹 STEP 5: Cleanup")
        print("=" * 60)

        res1 = session.delete(f"{SONIOX_API_BASE_URL}/v1/files/{file_id}")
        res2 = session.delete(f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}")

        print(f"Delete file: {res1.status_code}")
        print(f"Delete transcription: {res2.status_code}")

        if res1.status_code in (200, 204) and res2.status_code in (200, 204):
            print(f"✅ Cleanup successful")
        else:
            print(f"⚠️  Cleanup may have issues")

        print()
        print("=" * 60)
        print("✅ ALL TESTS PASSED!")
        print("=" * 60)
        print(f"\n📊 Summary:")
        print(f"   • File upload: ✅ {file_size / 1024:.1f} KB")
        print(f"   • Transcription creation: ✅")
        print(f"   • Processing time: {elapsed:.1f}s")
        print(f"   • Tokens: {len(tokens)}")
        print(f"   • Text length: {len(full_text)} chars")

        return True

    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
