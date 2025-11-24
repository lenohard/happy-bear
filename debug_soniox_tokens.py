#!/usr/bin/env python3
"""
Debug script to examine Soniox token structure.
"""

import os
import sys
import time
import requests
import json
from pathlib import Path

SONIOX_API_BASE_URL = "https://api.soniox.com"

def debug_soniox_tokens(audio_file_path):
    """Test Soniox API and print detailed token information."""

    # Get API key
    api_key = os.environ.get("SONIOX_API_KEY")
    if not api_key:
        print("❌ SONIOX_API_KEY not set. Run: export SONIOX_API_KEY=<your-key>")
        return False

    print("🔑 Using Soniox API key:", api_key[:20] + "...")

    audio_file = Path(audio_file_path)
    if not audio_file.exists():
        print(f"❌ Audio file not found: {audio_file}")
        return False

    print(f"📝 Using audio file: {audio_file} ({audio_file.stat().st_size} bytes)")

    # Create session with API key
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {api_key}"

    try:
        # Step 1: Upload file
        print("\n📤 Step 1: Uploading file...")
        with open(audio_file, "rb") as f:
            res = session.post(
                f"{SONIOX_API_BASE_URL}/v1/files",
                files={"file": f}
            )

        print(f"   Status: {res.status_code}")

        if res.status_code not in (200, 201):
            print(f"❌ Upload failed with status {res.status_code}")
            print(f"   Response: {res.text}")
            return False

        file_response = res.json()
        file_id = file_response.get("id")
        print(f"   ✅ File uploaded: {file_id}")

        # Step 2: Create transcription
        print("\n🎯 Step 2: Creating transcription...")
        config = {
            "file_id": file_id,
            "model": "stt-async-preview",
            "language_hints": ["en"],
            "enable_speaker_diarization": True,
            "enable_language_identification": True,
        }

        res = session.post(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions",
            json=config
        )

        print(f"   Status: {res.status_code}")

        if res.status_code not in (200, 201):
            print(f"❌ Transcription creation failed with status {res.status_code}")
            print(f"   Response: {res.text}")
            return False

        transcription_response = res.json()
        transcription_id = transcription_response.get("id")
        print(f"   ✅ Transcription created: {transcription_id}")

        # Step 3: Poll for completion (max 5 minutes)
        print("\n⏳ Step 3: Waiting for transcription...")
        for i in range(300):
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
                if i % 10 == 0:
                    print(f"   Status: {status} (wait {i}s)")

            time.sleep(1)
        else:
            print(f"❌ Transcription timed out after 300s")
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

        # Print first 50 tokens in detail
        print("\n" + "="*80)
        print("FIRST 50 TOKENS (detailed):")
        print("="*80)
        for i, token in enumerate(tokens[:50]):
            text = token.get("text", "")
            start_ms = token.get("start_ms")
            end_ms = token.get("end_ms")
            speaker = token.get("speaker")
            language = token.get("language")
            confidence = token.get("confidence")
            
            # Show if token has spaces
            has_space = " " in text
            space_indicator = " [HAS SPACE]" if has_space else ""
            
            print(f"Token {i:3d}: '{text}'{space_indicator}")
            print(f"          start={start_ms}ms, end={end_ms}ms, speaker={speaker}, lang={language}, conf={confidence}")

        # Show combined text
        print("\n" + "="*80)
        print("COMBINED TEXT (joining with spaces):")
        print("="*80)
        combined = " ".join(t.get("text", "") for t in tokens[:50])
        print(combined)

        # Show combined text (joining without spaces)
        print("\n" + "="*80)
        print("COMBINED TEXT (joining without spaces):")
        print("="*80)
        combined_no_space = "".join(t.get("text", "") for t in tokens[:50])
        print(combined_no_space)

        # Cleanup
        print("\n🧹 Cleanup...")
        session.delete(f"{SONIOX_API_BASE_URL}/v1/files/{file_id}")
        session.delete(f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}")
        print("   ✅ Cleaned up resources")

        return True

    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python debug_soniox_tokens.py <audio_file_path>")
        sys.exit(1)
    
    audio_file = sys.argv[1]
    success = debug_soniox_tokens(audio_file)
    sys.exit(0 if success else 1)
