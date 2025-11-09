#!/usr/bin/env python3
"""
Minimal Soniox API test - just test file upload and basic transcription flow.
"""

import os
import sys
import time
import requests
from pathlib import Path

SONIOX_API_BASE_URL = "https://api.soniox.com"

def test_soniox_api():
    """Test Soniox API with minimal audio file."""

    # Get API key
    api_key = os.environ.get("SONIOX_API_KEY")
    if not api_key:
        print("❌ SONIOX_API_KEY not set. Run: export SONIOX_API_KEY=<your-key>")
        return False

    print("🔑 Using Soniox API key:", api_key[:20] + "...")

    # Create test audio file (1-second silence in MP3 format)
    # Using a minimal valid MP3 file
    mp3_bytes = bytes.fromhex(
        "fffb1000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000"
        "00000000000000000000000000000000000000000000000000000000000000"
    )

    test_file = Path("/tmp/test_soniox.mp3")
    test_file.write_bytes(mp3_bytes)
    print(f"📝 Created test file: {test_file} ({len(mp3_bytes)} bytes)")

    # Create session with API key
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {api_key}"

    try:
        # Step 1: Upload file
        print("\n📤 Step 1: Uploading file...")
        with open(test_file, "rb") as f:
            res = session.post(
                f"{SONIOX_API_BASE_URL}/v1/files",
                files={"file": f}
            )

        print(f"   Status: {res.status_code}")
        print(f"   Response: {res.text[:200]}")

        if res.status_code not in (200, 201):
            print(f"❌ Upload failed with status {res.status_code}")
            return False

        try:
            file_response = res.json()
            file_id = file_response.get("id")
            if not file_id:
                print(f"❌ No file ID in response: {file_response}")
                return False
            print(f"   ✅ File uploaded: {file_id}")
        except Exception as e:
            print(f"❌ Failed to parse response: {e}")
            return False

        # Step 2: Create transcription
        print("\n🎯 Step 2: Creating transcription...")
        config = {
            "file_id": file_id,
            "model": "stt-async-preview",
            "language_hints": ["en"],
            "enable_speaker_diarization": False,
            "enable_language_identification": False,
        }

        res = session.post(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions",
            json=config
        )

        print(f"   Status: {res.status_code}")
        print(f"   Response: {res.text[:200]}")

        # Accept both 200 and 201 (Created)
        if res.status_code not in (200, 201):
            print(f"❌ Transcription creation failed with status {res.status_code}")
            return False

        try:
            transcription_response = res.json()
            transcription_id = transcription_response.get("id")
            if not transcription_id:
                print(f"❌ No transcription ID in response: {transcription_response}")
                return False
            print(f"   ✅ Transcription created: {transcription_id}")
        except Exception as e:
            print(f"❌ Failed to parse response: {e}")
            return False

        # Step 3: Poll for completion (max 30 seconds)
        print("\n⏳ Step 3: Waiting for transcription...")
        for i in range(30):
            res = session.get(
                f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}"
            )

            if res.status_code != 200:
                print(f"❌ Status check failed: {res.status_code}")
                return False

            status_data = res.json()
            status = status_data.get("status")

            if status == "completed":
                print(f"   ✅ Completed in {i} seconds")
                break
            elif status == "error":
                error_msg = status_data.get("error_message", "Unknown")
                print(f"❌ Transcription error: {error_msg}")
                return False
            else:
                if i % 5 == 0:
                    print(f"   Status: {status} (wait {i}s)")

            time.sleep(1)
        else:
            print(f"❌ Transcription timed out after 30s")
            return False

        # Step 4: Retrieve transcript
        print("\n📥 Step 4: Retrieving transcript...")
        res = session.get(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}/transcript"
        )

        if res.status_code != 200:
            print(f"❌ Transcript retrieval failed: {res.status_code}")
            return False

        transcript_data = res.json()
        tokens = transcript_data.get("tokens", [])
        print(f"   ✅ Retrieved {len(tokens)} tokens")

        # Cleanup
        print("\n🧹 Cleanup...")
        session.delete(f"{SONIOX_API_BASE_URL}/v1/files/{file_id}")
        session.delete(f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}")
        print("   ✅ Cleaned up resources")

        print("\n✅ All tests passed!")
        return True

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        test_file.unlink(missing_ok=True)

if __name__ == "__main__":
    success = test_soniox_api()
    sys.exit(0 if success else 1)
