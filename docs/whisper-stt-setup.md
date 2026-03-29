# Local STT Dictation on Ubuntu 24.04
## Management Summary for Nerds

> **Goal:** Hold a hotkey → speak → release → text appears in whatever window is focused.  
> Fully local, GPU-accelerated, system-wide. No cloud. No OpenCode coupling.

---

## Architecture Overview

```
RIGHT_CTRL held
  └─ evdev watches keyboard events
  └─ mic-mode=hold   → open mic stream now, buffer audio
  └─ mic-mode=always → mic stream already open, start buffering now

RIGHT_CTRL released
  └─ mic-mode=hold   → stop/close mic stream
  └─ WAV written to tmpfile (16kHz, mono, 16-bit PCM)
  └─ POST → whisper-server (CUDA, small.en) → localhost:8080
  └─ ~200–400ms inference on RTX A1000
  └─ ydotool type → focused window (works system-wide on X11 and Wayland)
  └─ notify-send feedback notifications
```

Three background services, one Python script:

| Service | Role |
|---|---|
| `whisper.service` | whisper-server, CUDA, localhost:8080 |
| `ydotoold.service` | synthetic input daemon |
| `dictation.service` | hotkey watcher + orchestration script |

---

## Hardware

Tested/designed for: **NVIDIA RTX A1000 (4GB VRAM)** on Ubuntu 24.04 (Noble).

Model sizing on your GPU:

| Model | VRAM | Latency (est.) | Notes |
|---|---|---|---|
| `tiny.en` | ~200 MB | <100ms | Overkill fast |
| `base.en` | ~300 MB | ~100ms | Good for testing |
| `small.en` | ~600 MB | ~200ms | Better accuracy |
| `medium.en` | ~1.5 GB | ~500ms | Very good |
| `large-v3` | ~3 GB | ~600–900ms | Best accuracy, but tight with other GPU workloads |

`.en` suffix = English-only but faster. Drop it for multilingual.

Current service config in this guide uses `small.en` so Whisper and Kokoro GPU can coexist on a 4GB card.

---

## A note on X11 vs Wayland

**ydotool works on both — no changes needed to this guide.** Unlike `xdotool` (which talks to the X server and breaks on Wayland), ydotool uses the Linux kernel's `uinput` framework to emulate a physical input device. The display server is never involved. It works identically on X11, Wayland, and even a bare text console.

---

## Step 1 — Prerequisites

```bash
# Build tools
sudo apt install build-essential cmake git ffmpeg

# Audio
sudo apt install libasound2-dev

# CUDA toolkit (verify driver compatibility first)
sudo apt install nvidia-cuda-toolkit

# Python deps — handled automatically by uv at runtime (no manual install needed)
# uv is managed via mise — no separate install needed.
# Verify mise knows about uv:
mise list uv

# Synthetic input
sudo apt install ydotool

# Notifications
sudo apt install libnotify-bin
```

**✓ Verify this step:**
```bash
nvidia-smi                  # should show GPU name, driver version, VRAM
nvcc --version              # should show CUDA release X.Y
gcc --version               # should show GCC present
mise exec uv -- uv --version   # should show uv x.y.z
notify-send "Test" "notify-send works"   # should pop a desktop notification
```

---

## Step 2 — Build whisper.cpp with CUDA

**Repo:** https://github.com/ggml-org/whisper.cpp

```bash
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp

cmake -B build -DGGML_CUDA=1
cmake --build build --config Release -j$(nproc)
```

**✓ Verify this step:**
```bash
# Binaries should exist
ls build/bin/
# Expected: whisper-cli  whisper-server  whisper-stream  (and others)

# NOTE: --help does NOT report CUDA status in current whisper.cpp versions.
# CUDA is confirmed at runtime (Step 3) when the model loads, not here.
# Check cmake found it instead:
grep "GGML_CUDA:BOOL" build/CMakeCache.txt
# → GGML_CUDA:BOOL=1
```

> If `GGML_CUDA:BOOL=0`: check that `nvcc` was on PATH during cmake. Clean and retry:
> `rm -rf build && cmake -B build -DGGML_CUDA=1`

---

## Step 3 — Download a model

```bash
cd whisper.cpp

# Helper script (recommended)
./models/download-ggml-model.sh small.en

# Or manually from HuggingFace:
# https://huggingface.co/ggerganov/whisper.cpp/tree/main
```

**✓ Verify this step:**
```bash
ls -lh models/ggml-small.en.bin
# Should show a few hundred MB

# Generate a silent WAV (no mic needed) and run inference
# CUDA init happens at model load regardless of audio content
ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le /tmp/smoke.wav
./build/bin/whisper-cli -m models/ggml-small.en.bin -f /tmp/smoke.wav

# Expected in output:
#   whisper_init_with_params_no_state: use gpu    = 1
#   ggml_cuda_init: found 1 CUDA devices (Total VRAM: XXXX MiB):
#     Device 0: NVIDIA RTX A1000 Laptop GPU, compute capability 8.6 ...
# This confirms GPU is active. Transcription output will be empty (silent audio).
```

---

## Step 4 — whisper-server systemd unit

> **Note:** whisper-server's default endpoint is `/inference`, not `/v1/audio/transcriptions`.
> The `--inference-path` flag remaps it to the OpenAI-compatible path so the dictation
> script works without modification.

```ini
# ~/.config/systemd/user/whisper.service
[Unit]
Description=whisper.cpp STT server (CUDA)

[Service]
ExecStart=%h/Projects/local-speech/whisper.cpp/build/bin/whisper-server \
  --model %h/Projects/local-speech/whisper.cpp/models/ggml-small.en.bin \
  --host 127.0.0.1 \
  --port 8080 \
  --convert \
  --inference-path "/v1/audio/transcriptions"
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now whisper
```

**✓ Verify this step:**
```bash
# Service should show active (running)
systemctl --user status whisper

# HTTP endpoint alive check — 404 means wrong path, 400/405 means server is up
curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:8080/v1/audio/transcriptions
# → 400 or 405 (not 404)

# Full HTTP round-trip using the smoke WAV from step 3
curl http://localhost:8080/v1/audio/transcriptions \
  -F file=@/tmp/smoke.wav \
  -F model=whisper-1 \
  -F response_format="json" | jq .
# → {"text": ""} for silent audio, or transcribed words if you used a real recording
```

The `--convert` flag lets whisper-server accept non-WAV input via ffmpeg (handy for quick tests with arbitrary audio files).

---

## Step 5 — ydotoold setup

### 5a — udev rule for /dev/uinput

ydotoold uses the kernel's `uinput` device, which is not accessible by default to normal users. A udev rule fixes this permanently:

```bash
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/60-uinput.rules

sudo udevadm control --reload-rules
sudo udevadm trigger /dev/uinput

# Confirm permissions
ls -la /dev/uinput
# → crw-rw---- root input ...
```

### 5b — Add yourself to the input group

```bash
sudo usermod -aG input $USER
```

**Log out and back in before continuing** — group membership is only picked up at login.

### 5c — Create the service unit

The apt package may or may not have installed a user service unit. Check first:

```bash
systemctl --user cat ydotoold 2>/dev/null || echo "UNIT MISSING"
```

**If the unit is missing** (shows `UNIT MISSING`): create it manually:

```ini
# ~/.config/systemd/user/ydotoold.service
[Unit]
Description=ydotool input automation daemon
After=graphical-session.target
PartOf=stt.target

[Service]
ExecStart=/usr/bin/ydotoold --socket %t/ydotool.sock
Restart=on-failure
RestartSec=1s

[Install]
WantedBy=stt.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now stt.target
```

### 5d — Set YDOTOOL_SOCKET in your shell

This setup uses the per-user runtime dir via `$XDG_RUNTIME_DIR/ydotool.sock`.
Export the variable so `ydotool` and ad-hoc commands always find it.

**bash** — add to `~/.bashrc`:
```bash
echo 'export YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/ydotool.sock"' >> ~/.bashrc
source ~/.bashrc
```

**fish** — add to `~/.config/fish/config.fish`:
```fish
echo 'set -gx YDOTOOL_SOCKET $XDG_RUNTIME_DIR/ydotool.sock' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

The dictation service also sets it directly with `%t/ydotool.sock`, so the service does not depend on shell startup files.

**✓ Verify this step:**
```bash
# Confirm group membership took effect
groups | grep input
# → output should include "input"

# Daemon should be running
systemctl --user status ydotoold

# Socket should exist at the correct path
ls "$XDG_RUNTIME_DIR/ydotool.sock"

# Live type test — focus any text field first, then:
ydotool type -- "hello from ydotool"
# → text should appear at cursor, in any app, on X11 or Wayland
```

---

## Step 6 — Find your keyboard device

```bash
cd ~/Projects/local-speech
./which-device.py
```

This writes the chosen keyboard path to `~/.config/local-speech/dictation.env` as `LOCAL_SPEECH_KEYBOARD_DEVICE`.

**✓ Verify this step:**
```bash
grep '^LOCAL_SPEECH_KEYBOARD_DEVICE=' ~/.config/local-speech/dictation.env
```

---

## Step 7 — Dictation script

Save as `~/Projects/local-speech/dictation.py`:

The script uses [PEP 723](https://peps.python.org/pep-0723/) inline metadata so `uv` can
manage dependencies automatically — no manual `pip install` needed.

```python
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
    device_path = (cli_value or os.environ.get(DEVICE_ENV_VAR, "")).strip() or DEFAULT_DEVICE

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
```

**✓ Verify this step:**
```bash
# Run directly first — much easier to see errors than via systemd
# uv will create an isolated venv and install deps on first run (~10s),
# then it's cached and subsequent runs are instant
uv run ~/Projects/local-speech/dictation.py --mic-mode hold

# Expected output in terminal:
#   Dictation ready. Hold KEY_RIGHTCTRL to record. mic-mode=hold

# Now test the full loop:
# 1. Focus a text field (terminal, browser, anywhere)
# 2. Hold RIGHT_CTRL → should see 🎙 Recording... notification
# 3. Say something
# 4. Release RIGHT_CTRL → should see ⏳ Transcribing...
# 5. ~1s later → ✓ notification + text typed into focused window

# Ctrl-C to exit when satisfied

# Optional low-latency mode: keep the mic open continuously
uv run ~/Projects/local-speech/dictation.py --mic-mode always
```

### Mic modes

| Mode | Behavior | Tradeoff |
|---|---|---|
| `hold` | Default. Open the mic only while RIGHT_CTRL is held | Mic indicator matches capture time; slightly higher startup latency |
| `always` | Keep the mic stream open continuously and only buffer while recording | Lowest latency; Ubuntu shows the mic in use all the time |

---

## Step 8 — Dictation systemd unit

Once the script works interactively, promote the whole STT stack to a persistent target.
The target manages `whisper.service`, `ydotoold.service`, and `dictation.service` together.

```ini
# ~/.config/systemd/user/stt.target
[Unit]
Description=Local speech-to-text stack
Wants=whisper.service ydotoold.service dictation.service
After=graphical-session.target

[Install]
WantedBy=default.target
```

```ini
# ~/.config/systemd/user/dictation.service
[Unit]
Description=Whisper hotkey dictation
After=whisper.service ydotoold.service
PartOf=stt.target

[Service]
EnvironmentFile=-%h/.config/local-speech/dictation.env
Environment=YDOTOOL_SOCKET=%t/ydotool.sock
ExecStart=/usr/bin/env mise exec uv -- uv run %h/Projects/local-speech/dictation.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=stt.target
```

```ini
# ~/.config/systemd/user/whisper.service
[Unit]
Description=whisper.cpp STT server (CUDA)
PartOf=stt.target

[Service]
ExecStart=%h/Projects/local-speech/whisper.cpp/build/bin/whisper-server \
  --model %h/Projects/local-speech/whisper.cpp/models/ggml-small.en.bin \
  --host 127.0.0.1 \
  --port 8080 \
  --convert \
  --inference-path "/v1/audio/transcriptions"
Restart=on-failure

[Install]
WantedBy=stt.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now stt.target
```

**✓ Verify this step:**
```bash
# Target and all three services should show active
systemctl --user status stt.target whisper ydotoold dictation

# Live log — hold key, watch events flow through
journalctl --user -fu dictation

# Final sanity: full dictation cycle with all services running as daemons
# (same test as Step 7 but now via the service, not the foreground script)
```

---

## Feedback UX

Three notification states visible in the corner of the screen:

| Event | Notification | Urgency |
|---|---|---|
| Key down | 🎙 Recording... | low (subtle) |
| Key up | ⏳ Transcribing... | normal |
| Done | ✓ first 60 chars of text | normal, auto-dismiss |
| Error | ⚠ message | critical |

---

## OpenCode integration

**Nothing special needed.** The dictation script types into whatever window has focus. When OpenCode's TUI input is focused, voice input lands there directly. OpenCode never knows Whisper is involved.

For reference, the community project `voice-opencode` exists for bi-directional voice (STT + TTS via OpenCode's session API at `localhost:4096`) if you ever want that:
https://github.com/jp-cruz/voice-opencode

OpenCode also supports non-interactive mode for scripting:
```bash
opencode -p "$(transcribe /tmp/audio.wav)"
```

---

## Latency budget (RTX A1000, `small.en`)

| Phase | Time |
|---|---|
| WAV write to tmpfile | ~10ms |
| HTTP POST to localhost | ~5ms |
| Whisper inference (CUDA, `small.en`) | ~200–400ms |
| ydotool type | ~10ms |
| **Total key-release → text** | **~300–500ms** |

To improve accuracy: switch to `large-v3` if you can spare the VRAM. To keep Kokoro GPU available at the same time, stay on `small.en`.

---

## Troubleshooting

**`ydotoold` fails with `failed to open uinput device`**
- The udev rule in Step 5a is missing or hasn't taken effect
- Confirm: `ls -la /dev/uinput` should show `crw-rw---- root input`
- If permissions are wrong: re-run `sudo udevadm trigger /dev/uinput`
- If still failing: reboot — udev rules for character devices sometimes need a full cycle

**`ydotool type` does nothing**
- Check `ydotoold` is running: `systemctl --user status ydotoold`
- Check group: `groups | grep input` — logout/login required after `usermod`
- Check socket exists: `ls "$XDG_RUNTIME_DIR/ydotool.sock"`
- Check env var: `echo $YDOTOOL_SOCKET` → should be `$XDG_RUNTIME_DIR/ydotool.sock`

**whisper-server returns 404**
- Missing `--inference-path "/v1/audio/transcriptions"` in the service unit
- Restart after updating: `systemctl --user restart whisper`

**whisper-server not using GPU**
- Verify CUDA compiled in: `grep "GGML_CUDA:BOOL" build/CMakeCache.txt` → should be `1`
- Watch `nvidia-smi` while transcribing — GPU utilisation should spike
- Look for `ggml_cuda_init: found 1 CUDA devices` in whisper-cli output (Step 3)
- Clean rebuild if needed: `rm -rf build && cmake -B build -DGGML_CUDA=1`

**`dev.grab()` fails with permission error**
- Must be in `input` group; logout/login required after `usermod`

**Hotkey not detected**
- Confirm device path with evdev listing in Step 6
- Some keyboards expose multiple event nodes — try each `-kbd` entry
- Run the script directly with `uv run ~/Projects/local-speech/dictation.py` to see errors before using the service

**Notifications not appearing from systemd service**
- Test manually: `notify-send "Test" "hello"`
- If that works but the service doesn't notify, add to `[Service]` in the unit file:
  `Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus`

---

## Links

- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- whisper.cpp models (HuggingFace): https://huggingface.co/ggerganov/whisper.cpp
- ydotool: https://github.com/ReimuNotMoe/ydotool
- evdev Python: https://python-evdev.readthedocs.io
- voice-opencode (community): https://github.com/jp-cruz/voice-opencode
- OpenCode: https://github.com/sst/opencode
