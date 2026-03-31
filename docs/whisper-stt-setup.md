# Local STT Dictation on Ubuntu 24.04
## Management Summary for Nerds

> **Goal:** Hold a hotkey → speak → release → text appears in whatever window is focused.  
> Fully local, GPU-accelerated, system-wide. No cloud. No OpenCode coupling.

---

## Architecture Overview

```
RIGHT_CTRL held
  └─ evdev watches keyboard events
  └─ open mic stream now, buffer audio

RIGHT_CTRL released
  └─ stop/close mic stream
  └─ WAV written to tmpfile (16kHz, mono, 16-bit PCM)
  └─ POST → whisper-server (CUDA, small.en) → localhost:5555
  └─ ~200–400ms inference on RTX A1000
  └─ ydotool type → focused window (works system-wide on X11 and Wayland)
  └─ notify-send feedback notifications
```

Three background services, one Python script:

| Service | Role |
|---|---|
| `whisper.service` | whisper-server, CUDA, localhost:5555 |
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
uv --version   # should show uv x.y.z
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

Canonical source for this unit: `systemd/templates/whisper.service.in`

The installer renders that template into `~/.config/systemd/user/whisper.service` using your
actual repo path. Important behaviors from the template:

- joins `speech.target` via `PartOf=speech.target`
- reads `LOCAL_SPEECH_WHISPER_PORT` from `~/.config/local-speech/dictation.env`
- binds `whisper-server` to `127.0.0.1`
- remaps the endpoint to `/v1/audio/transcriptions`

Inspect the template source and installed result any time with:

```bash
sed -n '1,160p' systemd/templates/whisper.service.in
systemctl --user cat whisper
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now speech.target
```

**✓ Verify this step:**
```bash
# Service and target should show active (running)
systemctl --user status speech.target whisper

# HTTP endpoint alive check — 404 means wrong path, 400/405 means server is up
curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:5555/v1/audio/transcriptions
# → 400 or 405 (not 404)

# Full HTTP round-trip using the smoke WAV from step 3
curl http://localhost:5555/v1/audio/transcriptions \
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

### 5c — Ensure the service unit exists

The apt package may or may not have installed a user service unit. Check first:

```bash
systemctl --user cat ydotoold 2>/dev/null || echo "UNIT MISSING"
```

If the unit is missing, this repo already carries the canonical unit at `systemd/user/ydotoold.service`.
`scripts/install.sh` copies it into `~/.config/systemd/user/ydotoold.service` for you.

You can inspect the repo source and installed result directly:

```bash
sed -n '1,120p' systemd/user/ydotoold.service
systemctl --user cat ydotoold
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now speech.target
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
REPO_ROOT=/path/to/local-speech
cd "$REPO_ROOT"
./scripts/select-device.sh
```

This writes the chosen keyboard path to `~/.config/local-speech/dictation.env` as `LOCAL_SPEECH_KEYBOARD_DEVICE`.
The same file also carries `LOCAL_SPEECH_WHISPER_PORT`, which defaults to `5555`.

**✓ Verify this step:**
```bash
grep '^LOCAL_SPEECH_KEYBOARD_DEVICE=' ~/.config/local-speech/dictation.env
```

---

## Step 7 — Dictation script

Use the repo copy at `dictation.py`; do not maintain a second pasted copy in the docs.

The script uses [PEP 723](https://peps.python.org/pep-0723/) inline metadata, so `uv` resolves runtime dependencies automatically.

Current implementation notes:

- dependencies are `evdev`, `sounddevice`, and `requests`
- the recorder uses `sounddevice.RawInputStream`, not `InputStream`, to avoid the indirect NumPy runtime requirement in the array callback path
- captured PCM frames are buffered as raw bytes and written to a temporary WAV with Python's built-in `wave` module
- the Whisper endpoint is built from `LOCAL_SPEECH_WHISPER_PORT`, defaulting to `5555`
- transcription output is normalized before typing so multiline responses do not inject literal Enter keypresses into the focused app

Key runtime knobs in the current script:

```text
LOCAL_SPEECH_KEYBOARD_DEVICE  keyboard event device path
LOCAL_SPEECH_WHISPER_PORT     optional Whisper port override, default 5555
RIGHT_CTRL                    hold to record, release to transcribe
16000 Hz mono int16           microphone capture format
```

**✓ Verify this step:**
```bash
# Run directly first — much easier to see errors than via systemd
# uv will create an isolated venv and install deps on first run (~10s),
# then it's cached and subsequent runs are instant
./scripts/run-dictation.sh

# Expected output in terminal:
#   Dictation ready. Hold KEY_RIGHTCTRL to record. device=/dev/input/by-id/...

# Now test the full loop:
# 1. Focus a text field (terminal, browser, anywhere)
# 2. Hold RIGHT_CTRL → should see a "Recording started" notification
# 3. Say something
# 4. Release RIGHT_CTRL → should see a "Recording stopped" notification
# 5. ~1s later → text typed into focused window

# Ctrl-C to exit when satisfied
```


---

## Step 8 — Dictation systemd unit

Once the script works interactively, promote the whole speech stack to a persistent target.
The target manages `whisper.service`, `ydotoold.service`, and `dictation.service` together.

Canonical repo files for this stack:

- `systemd/user/speech.target`
- `systemd/templates/dictation.service.in`
- `systemd/templates/whisper.service.in`
- `systemd/user/ydotoold.service`

`scripts/install.sh` installs or renders these into `~/.config/systemd/user/`.

Inspect the repo sources and installed units with:

```bash
sed -n '1,120p' systemd/user/speech.target
sed -n '1,160p' systemd/templates/dictation.service.in
sed -n '1,160p' systemd/templates/whisper.service.in
sed -n '1,120p' systemd/user/ydotoold.service
systemctl --user cat speech.target
systemctl --user cat dictation
systemctl --user cat whisper
systemctl --user cat ydotoold
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now speech.target
```

**✓ Verify this step:**
```bash
# Target and all three services should show active
systemctl --user status speech.target whisper ydotoold dictation

# Live log — hold key, watch events flow through
journalctl --user -fu dictation

# Final sanity: full dictation cycle with all services running as daemons
# (same test as Step 7 but now via the service, not the foreground script)
```

---

## Feedback UX

Two notification states visible in the corner of the screen:

| Event | Notification | Urgency |
|---|---|---|
| Key down | Recording started | normal |
| Key up | Recording stopped | normal |

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
- If you changed ports, confirm `LOCAL_SPEECH_WHISPER_PORT` matches the service and client side
- Restart after updating: `systemctl --user restart whisper`

**`Mic open failed: No module named 'numpy'`**
- You are likely running an older dictation script that still uses `sounddevice.InputStream`
- The current repo version uses `sounddevice.RawInputStream` specifically to avoid that dependency
- Re-run from the checked-out repo with `./scripts/run-dictation.sh` and restart `dictation.service` after updating

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
- Run the script directly with `./scripts/run-dictation.sh` to see errors before using the service

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
