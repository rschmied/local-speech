# Local TTS with Kokoro-FastAPI on Ubuntu 24.04
## Management Summary for Nerds

> **Goal:** A locally running, GPU-accelerated TTS service exposing an OpenAI-compatible
> `/v1/audio/speech` endpoint on port 8880. No Docker, no cloud. Uses existing CUDA install.

---

## Architecture Overview

```
curl / script / app
  └─ POST http://localhost:8880/v1/audio/speech  {"input": "...", "voice": "af_bella"}
  └─ Kokoro-FastAPI (uvicorn, GPU, PyTorch)
  └─ returns WAV/MP3/FLAC audio bytes
  └─ pipe to pw-play or save to file
```

One background service, started **on demand** (not always-on):

| Service | Role |
|---|---|
| `kokoro-tts.service` | Kokoro-FastAPI, GPU, localhost:8880 |

---

## Why not Docker?

The NVIDIA Container Toolkit is only needed to pass a GPU into a Docker container.
Since CUDA is already installed natively (from the whisper.cpp setup), running
Kokoro-FastAPI directly via `uv` is simpler, lighter, and uses the same GPU without
any container overhead.

---

## VRAM considerations

The RTX A1000 has 4GB VRAM, shared between all GPU workloads.

| Service | VRAM |
|---|---|
| whisper-server (`large-v3`) | ~3.0 GB |
| whisper-server (`small.en`) | ~0.6 GB |
| Kokoro-FastAPI (GPU) | ~0.5–1.0 GB |
| Kokoro-FastAPI (CPU) | 0 GB |

**Recommendation: use `small.en` for the whisper dictation service** (see STT doc).
This frees up enough VRAM to run Kokoro on GPU simultaneously (~3.4GB total).

`large-v3` and Kokoro GPU cannot safely coexist in 4GB — use one or the other,
or run Kokoro on CPU when using `large-v3` for STT.

---

## On-demand vs always-on

Kokoro holds ~500MB RAM and ~500–1000MB VRAM while running, even when idle.
**Do not enable the service at boot** — start and stop it manually as needed.

Add aliases to `~/.config/fish/config.fish`:

```fish
alias tts-on="systemctl --user start kokoro-tts"
alias tts-off="systemctl --user stop kokoro-tts"
```

Or for bash (`~/.bashrc`):
```bash
alias tts-on="systemctl --user start kokoro-tts"
alias tts-off="systemctl --user stop kokoro-tts"
```

Startup takes ~10–15 seconds on first use (model load). Subsequent starts are faster.

---

## Why not Docker?

The NVIDIA Container Toolkit is only needed to pass a GPU into a Docker container.
Since CUDA is already installed natively (from the whisper.cpp setup), running
Kokoro-FastAPI directly via `uv` is simpler, lighter, and uses the same GPU without
any container overhead.

---

## Prerequisites

These should already be present from the whisper.cpp setup:

- CUDA toolkit + NVIDIA driver (verified via `nvidia-smi`)
- `mise` at `/usr/bin/mise` with `uv` available
- `git`

Additional dependency needed by Kokoro for phoneme fallback on unknown words:

```bash
sudo apt install espeak-ng
```

**✓ Verify:**
```bash
espeak-ng --version       # should show espeak-ng version
nvidia-smi                # GPU still visible
uv --version
```

---

## Step 1 — Clone Kokoro-FastAPI

**Repo:** https://github.com/remsky/Kokoro-FastAPI

```bash
git clone https://github.com/remsky/Kokoro-FastAPI.git
cd Kokoro-FastAPI
```

**✓ Verify:**
```bash
ls
# Expected: start-gpu.sh  start-cpu.sh  docker/  api/  ...

# Inspect the start script — useful to understand what uv env it creates
cat start-gpu.sh
```

---

## Step 2 — Pin Python version

Kokoro-FastAPI works on Python 3.10–3.12. Python 3.13 has spacy compatibility
issues (yanked package warnings). Pin the project to 3.12 via mise to be safe,
even if your global is 3.10 (which also works):

```bash
cd Kokoro-FastAPI
mise local python 3.12
```

This writes a `.mise.toml` in the project dir — only this directory uses 3.12.
Your global Python is unaffected.

**✓ Verify:**
```bash
mise exec python -- python --version
# → Python 3.12.x
```

---

## Step 3 — Download models

The model weights are not included in the repo and must be downloaded separately.
A helper script is provided:

```bash
cd Kokoro-FastAPI
mise exec uv -- uv run python docker/scripts/download_model.py \
  --output api/src/models/v1_0
```

This downloads the Kokoro-82M weights (~330MB) into the expected path.

**✓ Verify:**
```bash
ls api/src/models/v1_0/
# Should contain .pt model files and voice pack files
```

---

## Step 4 — Test run interactively

Before making it a service, confirm it starts and uses the GPU:

First ensure the project-local virtual environment exists for this clone path:

```bash
cd Kokoro-FastAPI
uv venv
```

If `Kokoro-FastAPI` was copied or moved from another location and startup fails with
`Failed to spawn: uvicorn`, the old `.venv` likely contains stale entrypoints.
Recreate it in the current path:

```bash
cd Kokoro-FastAPI
rm -rf .venv
uv venv
```

```bash
cd Kokoro-FastAPI
./start-gpu.sh
```

This uses `uv` internally to create an isolated environment and start uvicorn.
Watch the startup output for:
```
INFO:     Uvicorn running on http://0.0.0.0:8880
```
GPU confirmation appears on first inference request (PyTorch logs CUDA device).

**✓ Verify (in a second terminal while the server is running):**
```bash
# List available voices
curl -s http://localhost:8880/v1/audio/voices | jq .

# Full round-trip — generate speech and play immediately
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Kokoro TTS is working correctly.","voice":"af_bella","response_format":"wav"}' \
  | pw-play --channels=1 --rate=24000 -

# Confirm GPU is being used during inference
nvidia-smi dmon -s u -d 1
# → SM% should spike on first request
```

Ctrl-C to stop the server once confirmed working.

If you instead see `ModuleNotFoundError` during startup right after recreating `.venv`, run `uv venv` first and then rerun `./start-gpu.sh` so the environment exists before the script tries to install and launch dependencies.

---

## Step 5 — systemd user service

> **Do not use `--now` or `enable` here** — the service is managed on demand,
> not started at boot. See the on-demand section above.

The installer renders this unit using your actual clone path, and uses either plain `uv` or `mise`-managed `uv` depending on what is available.

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

```bash
# Load the unit but do NOT enable or start it
systemctl --user daemon-reload

# Start manually when needed
systemctl --user start kokoro-tts

# Stop when done
systemctl --user stop kokoro-tts
```

**✓ Verify:**
```bash
# Start it
systemctl --user start kokoro-tts

# Allow ~15s for startup, then check status
systemctl --user status kokoro-tts

# Live logs during startup
journalctl --user -fu kokoro-tts

# API alive
curl -s http://localhost:8880/v1/audio/voices | jq '.voices | length'
# → number of available voices (should be 10+)

# Full round-trip
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"TTS service is running correctly.","voice":"af_bella","response_format":"wav"}' \
  | pw-play --channels=1 --rate=24000 -

# Stop when done testing
systemctl --user stop kokoro-tts
```

---

## API reference

**Endpoint:** `POST http://localhost:8880/v1/audio/speech`
**Auth:** none required by default

```bash
# Minimal request
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "model": "kokoro",
    "input": "Your text here.",
    "voice": "af_bella",
    "response_format": "wav"
  }' --output output.wav

# Supported response_format values: wav, mp3, opus, flac

# Speed control (0.5 = slow, 1.0 = normal, 2.0 = fast)
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Fast speech.","voice":"af_bella","response_format":"mp3","speed":1.3}' \
  --output fast.mp3

# Voice blending
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"kokoro","input":"Blended voice.","voice":"af_bella+af_sky","response_format":"wav"}' \
  --output blended.wav
```

---

## Available voices

```bash
# List all voices from the running service
curl -s http://localhost:8880/v1/audio/voices | jq -r '.voices[]'
```

Common voices:

| Voice | Description |
|---|---|
| `af_bella` | American Female — warm, natural |
| `af_sky` | American Female — lighter |
| `af_heart` | American Female — expressive |
| `am_adam` | American Male |
| `bm_george` | British Male |
| `bf_emma` | British Female |

Voices can be blended with `+`: `"af_bella+af_sky"`

---

## Convenience script: speak

Save as `~/bin/speak`, make executable:

```bash
#!/usr/bin/env bash
# speak — pipe text to Kokoro TTS and play immediately
# Usage: speak "Hello world"
#        echo "Hello world" | speak
#        SPEAK_VOICE=bm_george speak "Hello"
VOICE="${SPEAK_VOICE:-af_bella}"
TEXT="${1:-$(cat)}"
curl -s -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"kokoro\",\"input\":$(echo "$TEXT" | jq -Rs .),\"voice\":\"$VOICE\",\"response_format\":\"wav\"}" \
  | pw-play --channels=1 --rate=24000 -
```

```bash
chmod +x ~/bin/speak

# Usage
speak "Dictation is ready"
echo "Build complete" | speak
SPEAK_VOICE=bm_george speak "Hello from a British voice"
```

---

## Latency budget (RTX A1000, af_bella)

| Phase | Time |
|---|---|
| HTTP POST to localhost | ~5ms |
| Kokoro inference (GPU, ~10 words) | ~100–300ms |
| Audio playback start | ~50ms |
| **Total text → first audio** | **~200–400ms** |

Kokoro-82M is fast on GPU — short phrases feel near-instant.
On CPU expect ~2–5s per phrase, still usable for non-interactive TTS.

---

## Troubleshooting

**Service fails to start**
- Check `journalctl --user -fu kokoro-tts` for the actual error
- Confirm `start-gpu.sh` is executable: `chmod +x start-gpu.sh`
- Confirm model weights downloaded: `ls api/src/models/v1_0/`
- Confirm Python version: `mise exec python -- python --version` → 3.12.x

**spacy yanked warning during startup**
- Harmless — uv resolves a compatible version automatically. Not an error.

**Out of VRAM / CUDA out of memory**
- Switch whisper dictation service to `small.en` (see STT doc)
- Or run Kokoro on CPU: use `start-cpu.sh` instead of `start-gpu.sh` in the unit

**`pw-play` not found**
- Install: `sudo apt install pipewire-audio-client-libraries`
- Alternative: `paplay` (PulseAudio) or `aplay` (ALSA)

**No GPU utilisation during inference**
- Check PyTorch sees CUDA:
  `cd Kokoro-FastAPI && mise exec uv -- uv run python -c "import torch; print(torch.cuda.is_available())"`
- Should print `True`

**`espeak-ng` errors in logs**
- Install: `sudo apt install espeak-ng`
- Only needed as fallback for unusual words — not fatal if missing

**Port 8880 already in use**
- Check: `ss -tlnp | grep 8880`
- Change port in `start-gpu.sh` if needed

---

## Links

- Kokoro-FastAPI: https://github.com/remsky/Kokoro-FastAPI
- Kokoro model (HuggingFace): https://huggingface.co/hexgrad/Kokoro-82M
- Kokoro voices reference: https://github.com/remsky/Kokoro-FastAPI/blob/master/api/src/core/openai_mappings.json
