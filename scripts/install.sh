#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/local-speech"
. "$ROOT_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/install.sh [--stt] [--tts] [--all]

Install local-speech user units for the selected stack:
  --stt   install whisper/dictation/ydotoold/speech.target
  --tts   install kokoro-tts.service and ~/bin/say4
  --all   install both stacks (default)
EOF
}

render_template() {
  local src="$1"
  local dest="$2"

  python3 - "$src" "$dest" "$ROOT_DIR" "$DICTATION_EXEC" "$KOKORO_EXEC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
root = sys.argv[3]
dictation_exec = sys.argv[4]
kokoro_exec = sys.argv[5]

text = src.read_text()
text = text.replace("__LOCAL_SPEECH_ROOT__", root)
text = text.replace("__DICTATION_EXEC__", dictation_exec)
text = text.replace("__KOKORO_EXEC__", kokoro_exec)
dest.write_text(text)
PY
}

INSTALL_STT=0
INSTALL_TTS=0

if [ "$#" -eq 0 ]; then
  INSTALL_STT=1
  INSTALL_TTS=1
else
  for arg in "$@"; do
    case "$arg" in
      --stt)
        INSTALL_STT=1
        ;;
      --tts)
        INSTALL_TTS=1
        ;;
      --all)
        INSTALL_STT=1
        INSTALL_TTS=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$arg" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
fi

local_speech_detect_launchers

DICTATION_EXEC="$LOCAL_SPEECH_DICTATION_EXEC"
WHICH_DEVICE_EXEC="$LOCAL_SPEECH_WHICH_DEVICE_EXEC"
KOKORO_EXEC="$LOCAL_SPEECH_KOKORO_EXEC"
LAUNCH_MODE="$LOCAL_SPEECH_LAUNCH_MODE"

mkdir -p "$UNIT_DIR"
mkdir -p "$CONFIG_DIR"

missing=0

if [ "$INSTALL_STT" -eq 1 ]; then
  for required_path in \
    "$ROOT_DIR/whisper.cpp/build/bin/whisper-server" \
    "$ROOT_DIR/whisper.cpp/models/ggml-small.en.bin"
  do
    if [ ! -e "$required_path" ]; then
      printf 'Missing STT prerequisite: %s\n' "$required_path" >&2
      missing=1
    fi
  done
fi

if [ "$INSTALL_TTS" -eq 1 ]; then
  for required_path in \
    "$ROOT_DIR/Kokoro-FastAPI/start-gpu.sh"
  do
    if [ ! -e "$required_path" ]; then
      printf 'Missing TTS prerequisite: %s\n' "$required_path" >&2
      missing=1
    fi
  done
fi

if [ "$missing" -ne 0 ]; then
  printf 'Provision the upstream assets for the selected install mode, then rerun scripts/install.sh.\n' >&2
  exit 1
fi

if [ "$INSTALL_STT" -eq 1 ]; then
  render_template "$ROOT_DIR/systemd/templates/whisper.service.in" "$UNIT_DIR/whisper.service"
  chmod 0644 "$UNIT_DIR/whisper.service"
  install -m 0644 "$ROOT_DIR/systemd/user/ydotoold.service" "$UNIT_DIR/ydotoold.service"
  render_template "$ROOT_DIR/systemd/templates/dictation.service.in" "$UNIT_DIR/dictation.service"
  chmod 0644 "$UNIT_DIR/dictation.service"
  rm -f "$UNIT_DIR/stt.target"
  install -m 0644 "$ROOT_DIR/systemd/user/speech.target" "$UNIT_DIR/speech.target"

  if [ ! -f "$CONFIG_DIR/dictation.env" ]; then
    install -m 0644 "$ROOT_DIR/config/dictation.env.example" "$CONFIG_DIR/dictation.env"
  fi
fi

if [ "$INSTALL_TTS" -eq 1 ]; then
  render_template "$ROOT_DIR/systemd/templates/kokoro-tts.service.in" "$UNIT_DIR/kokoro-tts.service"
  chmod 0644 "$UNIT_DIR/kokoro-tts.service"

  mkdir -p "$HOME/bin"
  install -m 0755 "$ROOT_DIR/bin/say4" "$HOME/bin/say4"
fi

cat > "$CONFIG_DIR/install.env" <<EOF
# local-speech installation metadata
LOCAL_SPEECH_ROOT=$ROOT_DIR
LOCAL_SPEECH_LAUNCH_MODE=$LAUNCH_MODE
LOCAL_SPEECH_INSTALL_STT=$INSTALL_STT
LOCAL_SPEECH_INSTALL_TTS=$INSTALL_TTS
EOF

systemctl --user daemon-reload

if [ "$INSTALL_STT" -eq 1 ] && [ -t 0 ] && [ -t 1 ]; then
  printf 'Run interactive keyboard selection now? [Y/n] '
  read -r answer
  answer="${answer:-Y}"
  case "$answer" in
    [Yy]|[Yy][Ee][Ss])
      "$ROOT_DIR/scripts/select-device.sh" || true
      ;;
  esac
fi

printf 'Installed local-speech components:\n'
if [ "$INSTALL_STT" -eq 1 ]; then
  printf '  - STT/dictation units into %s\n' "$UNIT_DIR"
  printf '  - Seeded %s/dictation.env if it did not already exist\n' "$CONFIG_DIR"
fi
if [ "$INSTALL_TTS" -eq 1 ]; then
  printf '  - TTS unit into %s\n' "$UNIT_DIR"
  printf '  - Installed ~/bin/say4\n'
fi

printf 'Wrote %s/install.env with repo path metadata.\n' "$CONFIG_DIR"
printf '\nNext steps:\n'
if [ "$INSTALL_STT" -eq 1 ]; then
  printf '  ./scripts/select-device.sh   # if you skipped selection above\n'
  printf '  systemctl --user enable --now speech.target\n'
  printf '  systemctl --user status speech.target whisper ydotoold dictation\n'
fi
if [ "$INSTALL_TTS" -eq 1 ]; then
  printf '  systemctl --user start kokoro-tts\n'
fi
