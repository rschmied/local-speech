#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "evdev",
#   "sounddevice",
#   "scipy",
#   "requests",
#   "numpy",
# ]
# ///
"""
dictation.py — hold RIGHT_CTRL to record, release to transcribe and type.

Usage:  uv run dictation.py [--mic-mode hold|always]
        chmod +x dictation.py && ./dictation.py [--mic-mode hold|always]

Requires: ydotoold running, user in 'input' group, YDOTOOL_SOCKET set
Works on both X11 and Wayland.
"""

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import threading

import evdev
import numpy
import requests
import sounddevice as sd
from scipy.io.wavfile import write as wav_write

# ── Config ────────────────────────────────────────────────────────────────────
DEVICE_ENV_VAR = "LOCAL_SPEECH_KEYBOARD_DEVICE"
DEFAULT_DEVICE_ID = "YOUR-KEYBOARD-BY-ID-NAME-HERE"
DEFAULT_DEVICE = f"/dev/input/by-id/{DEFAULT_DEVICE_ID}"
HOTKEY = evdev.ecodes.KEY_RIGHTCTRL
WHISPER = "http://localhost:8080/v1/audio/transcriptions"
RATE = 16000
EXIT_KEY = evdev.ecodes.KEY_ESC  # or KEY_Q, whatever you prefer
# ─────────────────────────────────────────────────────────────────────────────

recording = False
frames: list = []
dev: evdev.InputDevice | None = None
stream: sd.InputStream | None = None
state_lock = threading.Lock()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--device",
        help=f"Keyboard device path. Overrides ${DEVICE_ENV_VAR} if set.",
    )
    parser.add_argument(
        "--mic-mode",
        choices=("hold", "always"),
        default="hold",
        help="'hold' opens the mic only while the hotkey is held; 'always' keeps it open for lower latency.",
    )
    return parser.parse_args()


args = parse_args()
MIC_MODE = args.mic_mode


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


def notify(msg: str, urgency: str = "normal") -> None:
    subprocess.Popen(
        ["notify-send", "-t", "2000", "-u", urgency, "Dictation", msg],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


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
            frames.append(indata.copy())


def open_stream() -> sd.InputStream:
    new_stream = sd.InputStream(
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

    new_stream = None
    if MIC_MODE == "hold":
        try:
            new_stream = open_stream()
        except Exception as e:
            notify(f"⚠ Mic open failed: {e}", urgency="critical")
            return False

    with state_lock:
        frames.clear()
        if MIC_MODE == "hold":
            stream = new_stream
        recording = True

    return True


def stop_recording() -> list:
    global recording, stream

    with state_lock:
        if not recording:
            return []
        recording = False
        current_stream = stream if MIC_MODE == "hold" else None

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
        if MIC_MODE == "hold":
            stream = None

    return captured_frames


def ensure_always_stream() -> None:
    global stream

    try:
        stream = open_stream()
    except Exception as e:
        notify(f"⚠ Mic open failed: {e}", urgency="critical")
        raise SystemExit(1) from e


def transcribe_and_type(captured_frames: list) -> None:
    if not captured_frames:
        notify("⚠ No audio captured", urgency="critical")
        return

    notify("⏳ Transcribing...")

    audio = numpy.concatenate(captured_frames)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_write(f.name, RATE, audio)
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
            notify(f"⚠ Error: {e}", urgency="critical")
            return

    if text:
        # Replace newlines with spaces — don't want Enter keypresses mid-dictation
        text = text.replace("\n", " ").strip()
        subprocess.run(
            ["ydotool", "type", "--key-delay=1", "--", text], stderr=subprocess.DEVNULL
        )

        notify(f"✓ {text[:60]}{'...' if len(text) > 60 else ''}")
    else:
        notify("⚠ No transcription returned", urgency="low")


# ── Main ──────────────────────────────────────────────────────────────────────
signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

if MIC_MODE == "always":
    ensure_always_stream()

DEVICE = resolve_device_path(args.device)
dev = evdev.InputDevice(DEVICE)

try:
    # dev.grab()  # exclusive grab — prevents hotkey firing system shortcuts while held
    print(
        f"Dictation ready. Hold {evdev.ecodes.KEY[HOTKEY]} to record. mic-mode={MIC_MODE} device={DEVICE}"
    )

    for event in dev.read_loop():
        if event.type != evdev.ecodes.EV_KEY:
            continue
        key = evdev.categorize(event)
        # # Exit on ESC (since keyboard is grabbed, Ctrl-C can't reach us)
        # if key.scancode == EXIT_KEY and key.keystate == key.key_down:
        #     shutdown()

        if key.scancode != HOTKEY:
            continue

        if key.keystate == key.key_down and not recording:
            if start_recording():
                notify("🎙 Recording...", urgency="low")

        elif key.keystate == key.key_up and recording:
            captured_frames = stop_recording()
            threading.Thread(
                target=transcribe_and_type, args=(captured_frames,), daemon=True
            ).start()

except KeyboardInterrupt:
    shutdown()

# finally:
#     # Fallback: ensure grab is always released even on unexpected exceptions
#     try:
#         dev.ungrab()
#     except Exception:
#         pass
