#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "evdev",
#   "sounddevice",
#   "requests",
# ]
# ///
"""
dictation.py — hold RIGHT_CTRL to record, release to transcribe and type.

Usage:  uv run dictation.py [--device /dev/input/by-id/...]
        chmod +x dictation.py && ./dictation.py [--device /dev/input/by-id/...]

Requires: ydotoold running, user in 'input' group, YDOTOOL_SOCKET set
Works on both X11 and Wayland.
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import wave

import evdev
import requests
import sounddevice as sd

# ── Config ────────────────────────────────────────────────────────────────────
DEVICE_ENV_VAR = "LOCAL_SPEECH_KEYBOARD_DEVICE"
WHISPER_PORT_ENV_VAR = "LOCAL_SPEECH_WHISPER_PORT"
DEFAULT_DEVICE_ID = "YOUR-KEYBOARD-BY-ID-NAME-HERE"
DEFAULT_DEVICE = f"/dev/input/by-id/{DEFAULT_DEVICE_ID}"
HOTKEY = evdev.ecodes.KEY_RIGHTCTRL
DEFAULT_WHISPER_PORT = "5555"
RATE = 16000
# ─────────────────────────────────────────────────────────────────────────────

recording = False
frames: list[bytes] = []
dev: evdev.InputDevice | None = None
stream: sd.RawInputStream | None = None
state_lock = threading.Lock()
notify_lock = threading.Lock()
notification_id: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--device",
        help=f"Keyboard device path. Overrides ${DEVICE_ENV_VAR} if set.",
    )
    return parser.parse_args()


args = parse_args()


def resolve_device_path(cli_value: str | None) -> str:
    device_path = (
        cli_value or os.environ.get(DEVICE_ENV_VAR, "")
    ).strip() or DEFAULT_DEVICE

    if "YOUR-KEYBOARD-BY-ID-NAME-HERE" in device_path:
        raise SystemExit(
            f"No keyboard device configured. Set {DEVICE_ENV_VAR} or run ./which-device.py."
        )

    if not os.path.exists(device_path):
        raise SystemExit(
            f"Keyboard device not found: {device_path}. Update {DEVICE_ENV_VAR} or rerun ./which-device.py."
        )

    return device_path


def resolve_whisper_url() -> str:
    port = (
        os.environ.get(WHISPER_PORT_ENV_VAR, DEFAULT_WHISPER_PORT).strip()
        or DEFAULT_WHISPER_PORT
    )
    return f"http://localhost:{port}/v1/audio/transcriptions"


def notify(msg: str) -> None:
    global notification_id

    command = [
        "notify-send",
        "--icon",
        "audio-input-microphone",
        "--expire-time",
        "2000",
        "--transient",
        "--print-id",
    ]

    with notify_lock:
        if notification_id is not None:
            command.extend(["--replace-id", notification_id])

        command.extend(["Dictation", msg])

        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
            )
        except Exception:
            return

        if result.returncode != 0:
            return

        new_id = result.stdout.strip()
        if new_id:
            notification_id = new_id


def shutdown(sig=None, frame=None) -> None:
    """Release keyboard grab and exit cleanly on Ctrl-C or SIGTERM."""
    global recording, stream

    if dev is not None:
        try:
            dev.ungrab()
        except Exception:
            pass

    with state_lock:
        recording = False
        frames.clear()
        current_stream = stream
        stream = None

    if current_stream is not None:
        try:
            current_stream.stop()
        except Exception:
            pass
        try:
            current_stream.close()
        except Exception:
            pass

    print("Dictation stopped. Keyboard released.")
    sys.exit(0)


def audio_callback(indata, *_):
    with state_lock:
        if recording:
            frames.append(bytes(indata))


def open_stream() -> sd.RawInputStream:
    new_stream = sd.RawInputStream(
        samplerate=RATE,
        channels=1,
        dtype="int16",
        callback=audio_callback,
    )
    new_stream.start()
    return new_stream


def start_recording() -> bool:
    global recording, stream

    with state_lock:
        if recording:
            return False

    try:
        new_stream = open_stream()
    except Exception as e:
        print(f"Mic open failed: {e}", file=sys.stderr)
        return False

    with state_lock:
        frames.clear()
        stream = new_stream
        recording = True

    return True


def stop_recording() -> list[bytes]:
    global recording, stream

    with state_lock:
        if not recording:
            return []
        recording = False
        current_stream = stream

    if current_stream is not None:
        try:
            current_stream.stop()
        except Exception:
            pass
        try:
            current_stream.close()
        except Exception:
            pass

    with state_lock:
        captured_frames = list(frames)
        frames.clear()
        stream = None

    return captured_frames


def transcribe_and_type(captured_frames: list[bytes]) -> None:
    notify("Recording stopped")

    if not captured_frames:
        return

    audio = b"".join(captured_frames)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        with wave.open(f, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(RATE)
            wav_file.writeframes(audio)
        try:
            with open(f.name, "rb") as audio_file:
                r = requests.post(
                    WHISPER,
                    files={"file": audio_file},
                    data={"model": "whisper-1"},
                    timeout=30,
                )
            text = r.json().get("text", "").strip()
        except Exception as e:
            print(f"Transcription error: {e}", file=sys.stderr)
            return

    if text:
        # Variant A
        # split() without arguments splits by any whitespace (including \n)
        # and removes empty strings, effectively collapsing multiple spaces.
        text = " ".join(text.split()).strip()

        # Variant B
        # 1. Replace one or more newlines (and surrounding whitespace) with an ellipsis
        # This turns "Hello\n\nWorld" into "Hello... World"
        # text = re.sub(r"\s*\n+\s*", " ... ", text).strip()

        # 2. (Optional) Collapse any remaining double spaces elsewhere
        # text = re.sub(r" +", " ", text)

        # Variant C
        # 1. Handle protected punctuation: Keep '?' or '!' and just add the ellipsis after.
        # Logic: If there's a ? or !, keep it (\1) and add the ellipsis.
        # text = re.sub(r"([?!])\s*\n+\s*", r"\1 ... ", text)

        # 2. Handle soft punctuation: Replace '.', ',', or just plain newlines with ellipsis.
        # Logic: If it's a period/comma/nothing followed by a newline, swap it all for '... '
        # text = re.sub(r"[.,]?\s*\n+\s*", "... ", text)

        # 3. Final polish: Collapse any resulting double spaces
        # text = re.sub(r" +", " ", text).strip()

        subprocess.run(
            ["ydotool", "type", "--key-delay=1", "--", text], stderr=subprocess.DEVNULL
        )


# ── Main ──────────────────────────────────────────────────────────────────────
signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

DEVICE = resolve_device_path(args.device)
WHISPER = resolve_whisper_url()
dev = evdev.InputDevice(DEVICE)

try:
    print(
        f"Dictation ready. Hold {evdev.ecodes.KEY[HOTKEY]} to record. device={DEVICE}"
    )

    for event in dev.read_loop():
        if event.type != evdev.ecodes.EV_KEY:
            continue

        key = evdev.categorize(event)
        if type(key) is not evdev.KeyEvent:
            continue

        if key.scancode != HOTKEY:
            continue

        if key.keystate == key.key_down and not recording:
            if start_recording():
                notify("Recording started")

        elif key.keystate == key.key_up and recording:
            captured_frames = stop_recording()
            threading.Thread(
                target=transcribe_and_type, args=(captured_frames,), daemon=True
            ).start()

except KeyboardInterrupt:
    shutdown()
