# local-speech

Local speech tooling for Ubuntu 24.04 using:

- `whisper.cpp` for speech to text
- `Kokoro-FastAPI` for text to speech
- user-level `systemd` units for lifecycle management

This repository is an integration layer. It keeps the local helper scripts,
service units, target unit, and documentation in one place.

## Repository layout

- `dictation.py` - hotkey dictation script
- `which-device.py` - interactive keyboard selector that writes runtime config
- `bin/say4` - local TTS playback helper
- `config/dictation.env.example` - sample runtime configuration
- `systemd/templates/` - canonical service unit templates rendered at install time
- `systemd/user/` - canonical static user units such as `ydotoold.service` and `speech.target`
- `docs/` - setup and reference documentation
- `scripts/common.sh` - launcher detection shared by helper scripts
- `scripts/check.sh` - environment and dependency checks
- `scripts/install.sh` - install STT units, TTS units, or both from canonical repo files
- `scripts/select-device.sh` - launch the interactive keyboard selector with detected tooling
- `scripts/run-dictation.sh` - launch dictation with detected tooling
- `scripts/uninstall.sh` - remove installed units and helper script

## Scope

This repo does not bundle:

- NVIDIA drivers
- CUDA itself
- model binaries
- upstream repos such as `whisper.cpp` and `Kokoro-FastAPI`

It does provide:

- documented prerequisites
- service templates rendered for the actual clone path at install time
- helper scripts
- validation tooling

## Quick start

Prerequisite before service installation depends on what you want to install:

- for `--stt`: clone `whisper.cpp` into your `local-speech` repo, build it, and download the required Whisper model files
- for `--tts`: clone `Kokoro-FastAPI` into your `local-speech` repo
- for `--tts`: treat Kokoro model download as mandatory setup as well, even if Kokoro may fetch missing assets on first start
- for `--tts`: create the Kokoro virtual environment explicitly with `uv venv` before first manual startup if it does not already exist
- for `--all`: do both sets of prerequisites

In other words, `scripts/install.sh` installs the integration layer and user units, but it does not clone, build, or provision the upstream engines for you.

Run the environment checks first:

```bash
./scripts/check.sh
```

Install the user units from this repo:

```bash
./scripts/install.sh --stt   # whisper + dictation + ydotoold + speech.target
./scripts/install.sh --tts   # kokoro-tts + ~/bin/say4
./scripts/install.sh --all   # both stacks (default if no flag is given)
```

For `--stt`, these paths must already exist inside the repo:

- `whisper.cpp/build/bin/whisper-server`
- `whisper.cpp/models/ggml-small.en.bin`

For `--tts`, these paths should exist:

- `Kokoro-FastAPI/start-gpu.sh`
- `Kokoro-FastAPI/.venv/` initialized for the current clone path

And operationally you should also have Kokoro model assets prepared before relying on the service.

If `Kokoro-FastAPI` was copied or moved from another path, remove its `.venv` and recreate it in the new location before starting the service.

Select the keyboard device for dictation after an STT install:

```bash
./scripts/select-device.sh
```

Run dictation manually from the current clone:

```bash
./scripts/run-dictation.sh
```

Remove installed assets later if needed:

```bash
./scripts/uninstall.sh
```

Focused setup docs:

- `docs/kokoro-tts-setup.md` - Kokoro clone, model prep, venv notes, and TTS service details
- `docs/whisper-stt-setup.md` - whisper.cpp build, model download, dictation, and speech target details

## Notes

- Speech services are grouped under `speech.target`
- `ydotoold` uses `%t/ydotool.sock`
- Dictation reads `LOCAL_SPEECH_KEYBOARD_DEVICE` from `~/.config/local-speech/dictation.env`
- Whisper port defaults to `5555` and can be overridden with `LOCAL_SPEECH_WHISPER_PORT`
- `scripts/install.sh` renders units using the actual clone path of the repo and can install STT, TTS, or both independently
- The installer and helper scripts prefer `/usr/bin/mise exec uv -- ...` and fall back to plain `uv` only if needed
- Current recommended Whisper model for 4 GB VRAM systems is `small.en`
