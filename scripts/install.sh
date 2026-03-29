#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/local-speech"

mkdir -p "$UNIT_DIR"
mkdir -p "$CONFIG_DIR"

install -m 0644 "$ROOT_DIR/systemd/user/whisper.service" "$UNIT_DIR/whisper.service"
install -m 0644 "$ROOT_DIR/systemd/user/ydotoold.service" "$UNIT_DIR/ydotoold.service"
install -m 0644 "$ROOT_DIR/systemd/user/dictation.service" "$UNIT_DIR/dictation.service"
install -m 0644 "$ROOT_DIR/systemd/user/stt.target" "$UNIT_DIR/stt.target"
install -m 0644 "$ROOT_DIR/systemd/user/kokoro-tts.service" "$UNIT_DIR/kokoro-tts.service"

mkdir -p "$HOME/bin"
install -m 0755 "$ROOT_DIR/bin/say4" "$HOME/bin/say4"

if [ ! -f "$CONFIG_DIR/dictation.env" ]; then
  install -m 0644 "$ROOT_DIR/config/dictation.env.example" "$CONFIG_DIR/dictation.env"
fi

systemctl --user daemon-reload

if [ -t 0 ] && [ -t 1 ]; then
  printf 'Run interactive keyboard selection now? [Y/n] '
  read -r answer
  answer="${answer:-Y}"
  case "$answer" in
    [Yy]|[Yy][Ee][Ss])
      "$ROOT_DIR/which-device.py" || true
      ;;
  esac
fi

cat <<'EOF'
Installed user units into ~/.config/systemd/user and copied say4 to ~/bin.
Seeded ~/.config/local-speech/dictation.env if it did not already exist.

Next steps:
  ./which-device.py            # if you skipped selection above
  systemctl --user enable --now stt.target
  systemctl --user status stt.target whisper ydotoold dictation

Optional:
  systemctl --user start kokoro-tts
EOF
