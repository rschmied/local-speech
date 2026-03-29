#!/usr/bin/env bash
set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"

systemctl --user disable --now stt.target >/dev/null 2>&1 || true
systemctl --user stop kokoro-tts >/dev/null 2>&1 || true

rm -f "$UNIT_DIR/whisper.service"
rm -f "$UNIT_DIR/ydotoold.service"
rm -f "$UNIT_DIR/dictation.service"
rm -f "$UNIT_DIR/stt.target"
rm -f "$UNIT_DIR/kokoro-tts.service"

rm -f "$HOME/bin/say4"

systemctl --user daemon-reload

cat <<'EOF'
Removed installed local-speech user units and ~/bin/say4.

Left in place:
  ~/.config/local-speech/dictation.env
  ~/.config/local-speech/install.env

Remove those manually if you want to clear keyboard selection and install metadata too.
EOF
