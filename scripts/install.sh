#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/local-speech"
. "$ROOT_DIR/scripts/common.sh"

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

local_speech_detect_launchers

DICTATION_EXEC="$LOCAL_SPEECH_DICTATION_EXEC"
WHICH_DEVICE_EXEC="$LOCAL_SPEECH_WHICH_DEVICE_EXEC"
KOKORO_EXEC="$LOCAL_SPEECH_KOKORO_EXEC"
LAUNCH_MODE="$LOCAL_SPEECH_LAUNCH_MODE"

mkdir -p "$UNIT_DIR"
mkdir -p "$CONFIG_DIR"

missing=0
for required_path in \
  "$ROOT_DIR/whisper.cpp/build/bin/whisper-server" \
  "$ROOT_DIR/whisper.cpp/models/ggml-small.en.bin" \
  "$ROOT_DIR/Kokoro-FastAPI/start-gpu.sh"
do
  if [ ! -e "$required_path" ]; then
    printf 'Missing prerequisite: %s\n' "$required_path" >&2
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  printf 'Clone/build the upstream projects and download required model assets first, then rerun scripts/install.sh.\n' >&2
  exit 1
fi

render_template "$ROOT_DIR/systemd/templates/whisper.service.in" "$UNIT_DIR/whisper.service"
chmod 0644 "$UNIT_DIR/whisper.service"
install -m 0644 "$ROOT_DIR/systemd/user/ydotoold.service" "$UNIT_DIR/ydotoold.service"
render_template "$ROOT_DIR/systemd/templates/dictation.service.in" "$UNIT_DIR/dictation.service"
chmod 0644 "$UNIT_DIR/dictation.service"
install -m 0644 "$ROOT_DIR/systemd/user/stt.target" "$UNIT_DIR/stt.target"
render_template "$ROOT_DIR/systemd/templates/kokoro-tts.service.in" "$UNIT_DIR/kokoro-tts.service"
chmod 0644 "$UNIT_DIR/kokoro-tts.service"

mkdir -p "$HOME/bin"
install -m 0755 "$ROOT_DIR/bin/say4" "$HOME/bin/say4"

if [ ! -f "$CONFIG_DIR/dictation.env" ]; then
  install -m 0644 "$ROOT_DIR/config/dictation.env.example" "$CONFIG_DIR/dictation.env"
fi

cat > "$CONFIG_DIR/install.env" <<EOF
# local-speech installation metadata
LOCAL_SPEECH_ROOT=$ROOT_DIR
LOCAL_SPEECH_LAUNCH_MODE=$LAUNCH_MODE
EOF

systemctl --user daemon-reload

if [ -t 0 ] && [ -t 1 ]; then
  printf 'Run interactive keyboard selection now? [Y/n] '
  read -r answer
  answer="${answer:-Y}"
  case "$answer" in
    [Yy]|[Yy][Ee][Ss])
      "$ROOT_DIR/scripts/select-device.sh" || true
      ;;
  esac
fi

cat <<'EOF'
Installed rendered user units into ~/.config/systemd/user and copied say4 to ~/bin.
Seeded ~/.config/local-speech/dictation.env if it did not already exist.
Wrote ~/.config/local-speech/install.env with repo path metadata.

Next steps:
  ./scripts/select-device.sh   # if you skipped selection above
  systemctl --user enable --now stt.target
  systemctl --user status stt.target whisper ydotoold dictation

Optional:
  systemctl --user start kokoro-tts
EOF
