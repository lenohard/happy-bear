#!/usr/bin/env python3
"""
Test script for Soniox speech-to-text API.
Transcribes test.mp3 and displays the result with speaker diarization.
Saves multiple output formats including timestamps.
"""

import os
import sys
import time
import json
import argparse
import requests
from typing import Optional, Tuple
from pathlib import Path
from textwrap import dedent

SONIOX_API_BASE_URL = "https://api.soniox.com"
DEFAULT_SEGMENT_GAP_MS = 1500  # Start new segment if same speaker pauses longer than this
DEFAULT_CONTEXT = dedent(
    """
    反派影评 (Fanpai Film Review)
    Film review podcast with multiple hosts discussing movies.
    常见术语: 电影, 导演, 演员, 剧情, 镜头, 叙事, 蒙太奇
    """
).strip()


def transcribe_local_file(audio_path: str, verbose: bool = True, extra_context: Optional[str] = None) -> dict:
    """
    Transcribe a local audio file using Soniox API.

    Args:
        audio_path: Path to local audio file
        verbose: Print progress messages

    Returns:
        Dictionary containing transcript text and raw token data
    """
    # Get API key from environment
    api_key = os.environ.get("SONIOX_API_KEY")
    if not api_key:
        raise RuntimeError(
            "Missing SONIOX_API_KEY.\n"
            "1. Get your API key at https://console.soniox.com\n"
            "2. Run: export SONIOX_API_KEY=<YOUR_API_KEY>"
        )

    # Verify file exists
    if not Path(audio_path).exists():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    # Create authenticated session
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {api_key}"

    # Step 1: Upload file
    if verbose:
        print(f"📤 Uploading file: {Path(audio_path).name}")
    with open(audio_path, "rb") as f:
        res = session.post(
            f"{SONIOX_API_BASE_URL}/v1/files",
            files={"file": f}
        )
    res.raise_for_status()
    file_id = res.json()["id"]
    if verbose:
        print(f"   File ID: {file_id}")

    # Step 2: Create transcription
    if verbose:
        print("🎯 Creating transcription...")
    context_parts = [DEFAULT_CONTEXT]
    if extra_context:
        context_parts.append(extra_context.strip())

    config = {
        "file_id": file_id,
        "model": "stt-async-preview",
        "language_hints": ["zh", "en"],  # Chinese and English
        "enable_speaker_diarization": True,  # Identify speakers
        "enable_language_identification": True,  # Detect language per token
        "context": "\n\n".join(context_parts),
    }

    res = session.post(
        f"{SONIOX_API_BASE_URL}/v1/transcriptions",
        json=config
    )
    res.raise_for_status()
    transcription_id = res.json()["id"]
    if verbose:
        print(f"   Transcription ID: {transcription_id}")

    # Step 3: Wait for completion
    if verbose:
        print("⏳ Waiting for transcription to complete...")
    start_time = time.time()
    poll_count = 0

    while True:
        res = session.get(
            f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}"
        )
        res.raise_for_status()
        data = res.json()

        poll_count += 1
        elapsed = time.time() - start_time

        if data["status"] == "completed":
            if verbose:
                print(f"✅ Completed in {elapsed:.1f}s after {poll_count} polls")
            break
        elif data["status"] == "error":
            error_msg = data.get("error_message", "Unknown error")
            raise Exception(f"Transcription failed: {error_msg}")
        elif data["status"] in ["queued", "processing"]:
            if verbose and poll_count % 5 == 0:  # Print update every 5 polls
                print(f"   Status: {data['status']} (elapsed: {elapsed:.1f}s)")
        else:
            if verbose:
                print(f"   Unknown status: {data['status']}")

        time.sleep(1)  # Poll every second

    # Step 4: Get transcript
    if verbose:
        print("📥 Retrieving transcript...")
    res = session.get(
        f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}/transcript"
    )
    res.raise_for_status()
    result = res.json()

    # Step 5: Clean up
    if verbose:
        print("🧹 Cleaning up...")
    session.delete(f"{SONIOX_API_BASE_URL}/v1/transcriptions/{transcription_id}")
    session.delete(f"{SONIOX_API_BASE_URL}/v1/files/{file_id}")

    # Render tokens into readable text
    text = render_tokens(result["tokens"])

    return {
        "text": text,
        "tokens": result["tokens"],
        "token_count": len(result["tokens"]),
        "processing_time": elapsed,
    }


def token_time_bounds(token: dict) -> Tuple[int, int]:
    """
    Return start/end timestamps in milliseconds for a token.

    Soniox tokens usually contain either end_ms or duration_ms; fall back safely to
    zero-length ranges if timing metadata is missing.
    """
    start_ms = token.get("start_ms") or 0
    end_ms = token.get("end_ms")

    if end_ms is None:
        duration_ms = token.get("duration_ms")
        if duration_ms is not None:
            end_ms = start_ms + duration_ms
        else:
            end_ms = start_ms

    return start_ms, end_ms


def group_tokens_by_speaker(final_tokens: list[dict], gap_ms: int = DEFAULT_SEGMENT_GAP_MS) -> list[dict]:
    """
    Merge consecutive tokens that share the same speaker into diarized segments.

    Args:
        final_tokens: Tokens returned by the Soniox transcript API
        gap_ms: Maximum silence (in ms) allowed between tokens to stay in the same segment

    Returns:
        List of segments with speaker label, start/end time, and aggregated text
    """
    segments: list[dict] = []
    current_segment: Optional[dict] = None

    for token in final_tokens:
        speaker = token.get("speaker") or "unknown"
        start_ms, end_ms = token_time_bounds(token)
        text = token["text"]

        if current_segment is None:
            current_segment = {
                "speaker": speaker,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "text": text,
            }
            continue

        speaker_changed = speaker != current_segment["speaker"]
        long_pause = start_ms - current_segment["end_ms"] > gap_ms

        if speaker_changed or long_pause:
            segments.append(current_segment)
            current_segment = {
                "speaker": speaker,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "text": text,
            }
        else:
            current_segment["text"] += text
            current_segment["end_ms"] = max(current_segment["end_ms"], end_ms)

    if current_segment is not None:
        segments.append(current_segment)

    return segments


def render_tokens(final_tokens: list[dict]) -> str:
    """
    Convert token array into readable transcript with speaker labels.

    Args:
        final_tokens: List of token dictionaries from API

    Returns:
        Formatted transcript string
    """
    text_parts: list[str] = []
    current_speaker: Optional[str] = None
    current_language: Optional[str] = None

    for token in final_tokens:
        text = token["text"]
        speaker = token.get("speaker") or "unknown"
        language = token.get("language")

        if speaker != current_speaker:
            if current_speaker is not None:
                text_parts.append("\n\n")
            current_speaker = speaker
            current_language = None
            text_parts.append(f"Speaker {current_speaker}:")

        if language is not None and language != current_language:
            current_language = language
            text_parts.append(f"\n[{current_language}] ")
            text = text.lstrip()

        text_parts.append(text)

    return "".join(text_parts)


def render_tokens_with_timestamps(final_tokens: list[dict]) -> str:
    """
    Convert token array into readable transcript with timestamps and speaker labels.

    Args:
        final_tokens: List of token dictionaries from API

    Returns:
        Formatted transcript string with timestamps
    """
    segments = group_tokens_by_speaker(final_tokens)
    if not segments:
        return ""

    text_parts: list[str] = []

    for segment in segments:
        start = format_time(segment["start_ms"])
        end = format_time(segment["end_ms"])
        speaker = segment["speaker"]
        segment_text = segment["text"].strip()
        if not segment_text:
            continue
        text_parts.append(f"[{start} --> {end}] Speaker {speaker}:\n{segment_text}\n")

    return "\n".join(text_parts).strip()


def format_time(ms: int) -> str:
    """Convert milliseconds to HH:MM:SS.mmm format."""
    seconds = ms / 1000.0
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"


def tokens_to_srt(final_tokens: list[dict], chunk_duration_ms: int = 5000) -> str:
    """
    Convert tokens to SRT subtitle format, grouping tokens into chunks.

    Args:
        final_tokens: List of token dictionaries from API
        chunk_duration_ms: Max duration for each subtitle chunk in milliseconds

    Returns:
        SRT formatted string
    """
    if not final_tokens:
        return ""

    srt_parts = []
    chunk_index = 1
    chunk_tokens = []
    chunk_start_ms = None
    chunk_end_ms = None

    for token in final_tokens:
        text = token["text"]
        start_ms, end_ms = token_time_bounds(token)

        # Start new chunk
        if chunk_start_ms is None:
            chunk_start_ms = start_ms
            chunk_tokens = [text]
            chunk_end_ms = end_ms
        # Continue chunk if within duration limit
        elif (end_ms - chunk_start_ms) <= chunk_duration_ms:
            chunk_tokens.append(text)
            chunk_end_ms = end_ms
        # Finalize current chunk and start new one
        else:
            # Write chunk to SRT
            srt_parts.append(f"{chunk_index}\n")
            srt_parts.append(f"{format_srt_time(chunk_start_ms)} --> {format_srt_time(chunk_end_ms)}\n")
            srt_parts.append(f"{''.join(chunk_tokens).strip()}\n\n")

            # Start new chunk
            chunk_index += 1
            chunk_start_ms = start_ms
            chunk_tokens = [text]
            chunk_end_ms = end_ms

    # Write final chunk
    if chunk_tokens:
        srt_parts.append(f"{chunk_index}\n")
        srt_parts.append(f"{format_srt_time(chunk_start_ms)} --> {format_srt_time(chunk_end_ms)}\n")
        srt_parts.append(f"{''.join(chunk_tokens).strip()}\n")

    return "".join(srt_parts)


def format_srt_time(ms: int) -> str:
    """Convert milliseconds to SRT time format (HH:MM:SS,mmm)."""
    seconds = ms / 1000.0
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    millisecs = int((ms % 1000))
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millisecs:03d}"


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Test Soniox transcription with optional context file support."
    )
    parser.add_argument(
        "audio_path",
        nargs="?",
        default="test.mp3",
        help="Path to local audio file to transcribe (default: test.mp3)",
    )
    parser.add_argument(
        "--context",
        type=Path,
        dest="context_file",
        help="Path to a text file whose content will be appended to the transcription context.",
    )
    parser.add_argument(
        "--suffix",
        type=str,
        help="Optional suffix appended to the output directory name (transcription_output/<audio>_<suffix>/soniox).",
    )
    return parser.parse_args()


def main():
    """Main entry point for the test script."""
    args = parse_args()
    audio_path = args.audio_path
    extra_context: Optional[str] = None

    if args.context_file:
        if not args.context_file.exists():
            raise FileNotFoundError(f"Context file not found: {args.context_file}")
        extra_context = args.context_file.read_text(encoding="utf-8")
        print(f"🧠 Loaded context from {args.context_file} ({len(extra_context)} characters)")

    print(f"🎙️  Soniox Speech-to-Text Test")
    print(f"=" * 60)

    try:
        result = transcribe_local_file(audio_path, verbose=True, extra_context=extra_context)

        input_path = Path(audio_path)
        base_name = input_path.stem
        audio_filename = input_path.name
        audio_absolute_path = str(input_path.resolve())
        suffix = (args.suffix or "").strip()
        output_dir_base = base_name if not suffix else f"{base_name}_{suffix}"
        output_dir = Path("transcription_output") / output_dir_base / "soniox"
        output_dir.mkdir(parents=True, exist_ok=True)

        # Calculate duration from last token
        if result['tokens']:
            _, duration_ms = token_time_bounds(result['tokens'][-1])
            duration_sec = duration_ms / 1000.0
        else:
            duration_ms = 0
            duration_sec = 0

        print(f"\n{'=' * 60}")
        print(f"📊 Statistics:")
        print(f"   Token count: {result['token_count']}")
        print(f"   Processing time: {result['processing_time']:.1f}s")
        print(f"   Audio duration: {duration_sec:.1f}s ({duration_sec/60:.1f} minutes)")
        print(f"   Character count: {len(result['text'])}")
        print(f"\n{'=' * 60}")
        print(f"📝 Transcript Preview (first 500 chars):\n")
        print(result["text"][:500])
        if len(result["text"]) > 500:
            print("...")

        # Save multiple formats
        print(f"\n💾 Saving outputs...")

        # 1. Plain text transcript
        txt_path = output_dir / f"{base_name}_soniox.txt"
        txt_path.write_text(result["text"], encoding="utf-8")
        print(f"   ✓ Plain text: {txt_path}")

        # 2. Transcript with timestamps
        timestamped_text = render_tokens_with_timestamps(result["tokens"])
        timestamped_path = output_dir / f"{base_name}_soniox_timestamped.txt"
        timestamped_path.write_text(timestamped_text, encoding="utf-8")
        print(f"   ✓ With timestamps: {timestamped_path}")

        # 3. Raw JSON with all token data
        json_path = output_dir / f"{base_name}_soniox_tokens.json"
        speaker_segments = group_tokens_by_speaker(result["tokens"])

        json_data = {
            "audio_file": audio_absolute_path,
            "processing_time": result['processing_time'],
            "token_count": result['token_count'],
            "duration_ms": duration_ms,
            "tokens": result['tokens'],
            "speaker_segments": speaker_segments,
        }
        json_path.write_text(json.dumps(json_data, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"   ✓ JSON with tokens: {json_path}")

        diarization_json_path = output_dir / f"{base_name}_soniox_diarization.json"
        diarization_json_path.write_text(
            json.dumps(
                {
                    "audio_file": audio_absolute_path,
                    "speaker_segments": speaker_segments,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"   ✓ Speaker diarization: {diarization_json_path}")

        # 4. SRT subtitle format (5-second chunks)
        srt_content = tokens_to_srt(result["tokens"], chunk_duration_ms=5000)
        srt_path = output_dir / f"{base_name}_soniox.srt"
        srt_path.write_text(srt_content, encoding="utf-8")
        print(f"   ✓ SRT subtitles: {srt_path}")

        print(f"\n✅ All outputs saved successfully!")

    except Exception as e:
        print(f"\n❌ Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
