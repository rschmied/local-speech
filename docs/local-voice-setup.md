# Local Voice Setup on Ubuntu 24.04

This guide combines the local Kokoro TTS and whisper.cpp dictation setup for a `local-speech` clone into one reference.

Both services run fully local, use the existing NVIDIA/CUDA stack, and expose simple localhost APIs:

- Kokoro TTS: `http://localhost:8880/v1/audio/speech`
- Whisper STT: `http://localhost:8080/v1/audio/transcriptions`

Shared assumptions:

- Ubuntu 24.04 with a working NVIDIA driver and CUDA toolkit
- `uv` is available directly, or via `mise`
- The `local-speech` repo can be cloned anywhere; examples use `REPO_ROOT`
- `whisper.cpp` and `Kokoro-FastAPI` are cloned inside that repo before service installation
- On a 4 GB GPU, the current recommended Whisper model is `small.en` so STT can coexist with Kokoro on GPU

Recommended base packages:

```bash
sudo apt install build-essential cmake git ffmpeg jq curl
sudo apt install nvidia-cuda-toolkit
sudo apt install libasound2-dev libnotify-bin ydotool espeak-ng
```

Quick verification:

```bash
REPO_ROOT=/path/to/local-speech

nvidia-smi
nvcc --version
uv --version
notify-send "STT/TTS" "Notifications work"
```

Important prerequisite:

- `scripts/install.sh` does not clone `whisper.cpp`
- `scripts/install.sh` does not build `whisper.cpp`
- `scripts/install.sh` does not clone `Kokoro-FastAPI`
- `scripts/install.sh` does not provision model assets for you
- `scripts/install.sh` does not create or repair the `Kokoro-FastAPI` virtual environment for you
- complete the clone, build, and model download steps in this guide first, then install the user units

## Text to Speech

### Overview

Kokoro-FastAPI provides an OpenAI-compatible local TTS endpoint on port `8880`.

```text
curl / script / app
  -> POST http://localhost:8880/v1/audio/speech
  -> Kokoro-FastAPI (uvicorn, GPU, PyTorch)
  -> returns WAV/MP3/FLAC audio bytes
  -> pipe to pw-play or save to file
```

Kokoro keeps RAM and VRAM allocated while running, so the best pattern is to start it when needed and stop it when done.

### Step 1 - Clone Kokoro-FastAPI

```bash
cd "$REPO_ROOT"
git clone https://github.com/remsky/Kokoro-FastAPI.git
cd "$REPO_ROOT"/Kokoro-FastAPI
```

Verify the repo looks right:

```bash
ls
# Expected: start-gpu.sh, start-cpu.sh, api/, docker/, ...
```

### Step 2 - Pin Python for the project

Kokoro-FastAPI is safest on Python `3.12`.

```bash
cd "$REPO_ROOT"/Kokoro-FastAPI
mise local python 3.12
mise exec python -- python --version
# Expected: Python 3.12.x
```

### Step 3 - Download Kokoro models

This step is treated as mandatory setup for this repo, even if Kokoro can sometimes fetch missing assets lazily on first service start.

```bash
cd "$REPO_ROOT"/Kokoro-FastAPI
uv run python docker/scripts/download_model.py \
  --output api/src/models/v1_0
```

Verify the weights exist:

```bash
ls "$REPO_ROOT/Kokoro-FastAPI/api/src/models/v1_0/"
```

### Step 4 - Test it interactively first

Before the first manual startup in a fresh clone, initialize the Kokoro virtual environment:

```bash
cd "$REPO_ROOT"/Kokoro-FastAPI
uv venv
```

If this repo was copied or moved from another path and Kokoro fails with `Failed to spawn: uvicorn`, delete the stale environment and recreate it:

```bash
cd "$REPO_ROOT"/Kokoro-FastAPI
rm -rf .venv
uv venv
```

```bash
cd "$REPO_ROOT"/Kokoro-FastAPI
./start-gpu.sh
```

In a second terminal:

```bash
curl -s http://localhost:8880/v1/audio/voices | jq .

curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Kokoro TTS is working correctly.","voice":"af_bella","response_format":"wav"}' \
  | pw-play --channels=1 --rate=24000 -
```

Optional GPU check during inference:

```bash
nvidia-smi dmon -s u -d 1
```

Stop the server with `Ctrl-C` once the test succeeds.

### Step 5 - Install the user service

The installer renders this unit using your actual clone path:

```ini
# ~/.config/systemd/user/kokoro-tts.service
[Unit]
Description=Kokoro TTS server (GPU)
After=network.target

[Service]
ExecStart=/usr/bin/env bash /absolute/path/to/local-speech/Kokoro-FastAPI/start-gpu.sh
WorkingDirectory=/absolute/path/to/local-speech/Kokoro-FastAPI
Restart=on-failure
RestartSec=5
Environment=HOME=%h

[Install]
WantedBy=default.target
```

Load the unit, but do not enable it at boot:

```bash
systemctl --user daemon-reload
```

Start and stop it on demand:

```bash
systemctl --user start kokoro-tts
systemctl --user stop kokoro-tts
```

Useful shell aliases:

```bash
alias tts-on="systemctl --user start kokoro-tts"
alias tts-off="systemctl --user stop kokoro-tts"
```

### Step 6 - Verify the service

```bash
systemctl --user start kokoro-tts
systemctl --user status kokoro-tts
journalctl --user -fu kokoro-tts
```

API checks:

```bash
curl -s http://localhost:8880/v1/audio/voices | jq '.voices | length'

curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"TTS service is running correctly.","voice":"af_bella","response_format":"wav"}' \
  | pw-play --channels=1 --rate=24000 -
```

### API quick reference

```bash
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kokoro",
    "input": "Your text here.",
    "voice": "af_bella",
    "response_format": "wav"
  }' --output output.wav
```

Useful variations:

```bash
# MP3 output
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Fast speech.","voice":"af_bella","response_format":"mp3","speed":1.3}' \
  --output fast.mp3

# Blended voice
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Blended voice.","voice":"af_bella+af_sky","response_format":"wav"}' \
  --output blended.wav
```

List voices:

```bash
curl -s http://localhost:8880/v1/audio/voices | jq -r '.voices[]'
```

### Convenience script

Save as `~/bin/speak`, make executable:

```bash
#!/usr/bin/env bash
VOICE="${SPEAK_VOICE:-af_bella}"
TEXT="${1:-$(cat)}"
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"kokoro\",\"input\":$(echo "$TEXT" | jq -Rs .),\"voice\":\"$VOICE\",\"response_format\":\"wav\"}" \
  | pw-play --channels=1 --rate=24000 -
```

```bash
chmod +x ~/bin/speak
```

### Notes and troubleshooting

- Kokoro typically uses roughly `0.5-1.0 GB` VRAM on GPU
- Keep Whisper on `small.en` if you want both services running together on a 4 GB card
- If GPU memory is tight, switch Kokoro to CPU by testing `start-cpu.sh` instead
- If startup fails, check `journalctl --user -fu kokoro-tts`
- If `pw-play` is missing, install `pipewire-audio-client-libraries`

## Speech to Text

### Overview

This setup gives you a local dictation workflow:

- hold a hotkey
- speak
- release
- text is transcribed by whisper.cpp and typed into the focused window with `ydotool`

The STT side consists of three user services:

- `whisper.service` - local whisper.cpp server on port `8080`
- `ydotoold.service` - input injection daemon
- `dictation.service` - hotkey watcher and orchestration script

The current model choice is `small.en`, specifically to leave enough VRAM for Kokoro GPU at the same time.

### Step 1 - Build whisper.cpp with CUDA

```bash
cd "$REPO_ROOT"
git clone https://github.com/ggml-org/whisper.cpp
cd "$REPO_ROOT"/whisper.cpp

cmake -B build -DGGML_CUDA=1
cmake --build build --config Release -j"$(nproc)"
```

Verify the build:

```bash
ls "$REPO_ROOT/whisper.cpp/build/bin/"
grep "GGML_CUDA:BOOL" "$REPO_ROOT/whisper.cpp/build/CMakeCache.txt"
# Expected: GGML_CUDA:BOOL=1
```

### Step 2 - Download the Whisper model

Use `small.en` for the current balanced setup:

```bash
cd "$REPO_ROOT"/whisper.cpp
./models/download-ggml-model.sh small.en
```

Verify the model and a local smoke test:

```bash
ls -lh "$REPO_ROOT/whisper.cpp/models/ggml-small.en.bin"

ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 3 -c:a pcm_s16le /tmp/smoke.wav
"$REPO_ROOT/whisper.cpp/build/bin/whisper-cli" \
  -m "$REPO_ROOT/whisper.cpp/models/ggml-small.en.bin" \
  -f /tmp/smoke.wav
```

In the output, look for CUDA initialization lines such as:

- `use gpu = 1`
- `ggml_cuda_init: found ... CUDA devices`

### Step 3 - Install the Whisper user service

The installer renders this unit using your actual clone path:

```ini
# ~/.config/systemd/user/whisper.service
[Unit]
Description=whisper.cpp STT server (CUDA)
PartOf=stt.target

[Service]
ExecStart=/absolute/path/to/local-speech/whisper.cpp/build/bin/whisper-server \
  --model /absolute/path/to/local-speech/whisper.cpp/models/ggml-small.en.bin \
  --host 127.0.0.1 \
  --port 8080 \
  --convert \
  --inference-path "/v1/audio/transcriptions"
Restart=on-failure

[Install]
WantedBy=stt.target
```

Load and start the STT target:

```bash
systemctl --user daemon-reload
systemctl --user enable --now stt.target
```

Verify:

```bash
systemctl --user status whisper

curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:8080/v1/audio/transcriptions
# Expected: 400 or 405, not 404

curl http://localhost:8080/v1/audio/transcriptions \
  -F file=@/tmp/smoke.wav \
  -F model=whisper-1 \
  -F response_format=json | jq .
```

### Step 4 - Set up ydotool

`ydotool` is what makes dictation system-wide. It injects text into the currently focused window on both X11 and Wayland.

#### 4a - Allow access to `/dev/uinput`

```bash
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/60-uinput.rules

sudo udevadm control --reload-rules
sudo udevadm trigger /dev/uinput
ls -la /dev/uinput
```

#### 4b - Add your user to the `input` group

```bash
sudo usermod -aG input "$USER"
```

Log out and back in before continuing.

#### 4c - Ensure the daemon service exists

Current user unit:

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

Start it through the STT target:

```bash
systemctl --user daemon-reload
systemctl --user enable --now stt.target
```

#### 4d - Export the socket path

For bash:

```bash
echo 'export YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/ydotool.sock"' >> ~/.bashrc
source ~/.bashrc
```

For fish:

```fish
echo 'set -gx YDOTOOL_SOCKET $XDG_RUNTIME_DIR/ydotool.sock' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Verify the full ydotool path:

```bash
groups | grep input
systemctl --user status ydotoold
ls "$XDG_RUNTIME_DIR/ydotool.sock"
ydotool type -- "hello from ydotool"
```

### Step 5 - Configure the dictation script

The guide assumes the repo already exists and `dictation.py` is run with `uv`.
The keyboard device is parameterized via `LOCAL_SPEECH_KEYBOARD_DEVICE`, typically stored in
`~/.config/local-speech/dictation.env`.

Select the keyboard interactively:

```bash
cd "$REPO_ROOT"
./scripts/select-device.sh
```

This writes the selected device path into `~/.config/local-speech/dictation.env`.

Important script settings:

- keyboard device path from `LOCAL_SPEECH_KEYBOARD_DEVICE`
- hotkey, currently `KEY_RIGHTCTRL`
- Whisper URL, currently `http://localhost:8080/v1/audio/transcriptions`

Run it directly first:

```bash
./scripts/run-dictation.sh
```


### Step 5a - Add a combined STT target

Use this target to manage the whole speech-to-text stack together:

```ini
# ~/.config/systemd/user/stt.target
[Unit]
Description=Local speech-to-text stack
Wants=whisper.service ydotoold.service dictation.service
After=graphical-session.target

[Install]
WantedBy=default.target
```

### Step 6 - Install the dictation user service

The installer renders this unit using your actual clone path and either plain `uv` or `mise exec uv -- uv run`, depending on what is available:

```ini
# ~/.config/systemd/user/dictation.service
[Unit]
Description=Whisper hotkey dictation
After=whisper.service ydotoold.service
PartOf=stt.target

[Service]
EnvironmentFile=-%h/.config/local-speech/dictation.env
Environment=YDOTOOL_SOCKET=%t/ydotool.sock
ExecStart=/usr/bin/env uv run /absolute/path/to/local-speech/dictation.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=stt.target
```

Load and start the STT target:

```bash
systemctl --user daemon-reload
systemctl --user enable --now stt.target
```

Verify all STT services:

```bash
systemctl --user status stt.target whisper ydotoold dictation
journalctl --user -fu dictation
```

### Step 7 - End-to-end verification

With all three services running:

```bash
systemctl --user status stt.target whisper ydotoold dictation
```

Then test the live flow:

1. focus a text field
2. hold `RIGHT_CTRL`
3. speak a short phrase
4. release the key
5. confirm the text appears where the cursor is

Useful checks if something is wrong:

```bash
curl -s http://localhost:8080/v1/audio/transcriptions
journalctl --user -fu whisper
journalctl --user -fu dictation
systemctl --user status ydotoold
```

### Notes and troubleshooting

- `small.en` is the current recommended model because it leaves enough VRAM for Kokoro GPU
- If you switch Whisper to `large-v3`, expect much tighter VRAM pressure on a 4 GB card
- If `ydotoold` fails with `failed to open uinput device`, re-check the udev rule and `/dev/uinput` permissions
- If `ydotool type` does nothing, confirm the daemon is running and `YDOTOOL_SOCKET=$XDG_RUNTIME_DIR/ydotool.sock`
- If Whisper returns `404`, the service is missing `--inference-path "/v1/audio/transcriptions"`
- If the hotkey is never detected, rerun `./scripts/select-device.sh` and restart `dictation.service`

## Links

- whisper.cpp: https://github.com/ggml-org/whisper.cpp
- whisper.cpp models: https://huggingface.co/ggerganov/whisper.cpp
- Kokoro-FastAPI: https://github.com/remsky/Kokoro-FastAPI
- Kokoro model: https://huggingface.co/hexgrad/Kokoro-82M
- ydotool: https://github.com/ReimuNotMoe/ydotool
- evdev Python: https://python-evdev.readthedocs.io
