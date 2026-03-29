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
- `systemd/templates/` - rendered service unit templates
- `systemd/user/` - static user units such as `ydotoold.service` and `stt.target`
- `docs/` - setup and reference documentation
- `scripts/common.sh` - launcher detection shared by helper scripts
- `scripts/check.sh` - environment and dependency checks
- `scripts/install.sh` - install units into `~/.config/systemd/user`
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

Run the environment checks first:

```bash
./scripts/check.sh
```

Install the user units from this repo:

```bash
./scripts/install.sh
```

Select the keyboard device for dictation:

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

Then review the main setup guide:

```text
docs/local-voice-setup.md
```

## Notes

- STT services are grouped under `stt.target`
- `ydotoold` uses `%t/ydotool.sock`
- Dictation reads `LOCAL_SPEECH_KEYBOARD_DEVICE` from `~/.config/local-speech/dictation.env`
- `scripts/install.sh` renders units using the actual clone path of the repo
- The installer and helper scripts prefer plain `uv` when available and fall back to `mise exec uv -- ...`
- Current recommended Whisper model for 4 GB VRAM systems is `small.en`
