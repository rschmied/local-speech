#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() {
  printf '[ok] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1"
}

check_cmd() {
  local cmd="$1"
  local label="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$label: $(command -v "$cmd")"
  else
    warn "$label missing: $cmd"
  fi
}

printf 'Checking local-speech environment in %s\n' "$ROOT_DIR"

check_cmd git "git"
check_cmd curl "curl"
check_cmd jq "jq"
check_cmd ffmpeg "ffmpeg"
check_cmd systemctl "systemctl"
check_cmd ydotool "ydotool"
check_cmd ydotoold "ydotoold"
check_cmd notify-send "notify-send"
check_cmd nvidia-smi "nvidia-smi"
check_cmd nvcc "nvcc"
check_cmd mise "mise"
check_cmd uv "uv"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user --version >/dev/null 2>&1; then
    pass "systemd user instance available"
  else
    warn "systemd user instance not available"
  fi
fi

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  pass "XDG_RUNTIME_DIR set to ${XDG_RUNTIME_DIR}"
else
  warn "XDG_RUNTIME_DIR not set"
fi

if [ -e /dev/uinput ]; then
  pass "/dev/uinput exists"
else
  warn "/dev/uinput missing"
fi

if id -nG "$USER" | grep -qw input; then
  pass "user is in input group"
else
  warn "user is not in input group"
fi

for rel in \
  dictation.py \
  which-device.py \
  config/dictation.env.example \
  bin/say4 \
  systemd/user/whisper.service \
  systemd/user/ydotoold.service \
  systemd/user/dictation.service \
  systemd/user/stt.target \
  docs/local-voice-setup.md
do
  if [ -e "$ROOT_DIR/$rel" ]; then
    pass "repo file present: $rel"
  else
    warn "repo file missing: $rel"
  fi
done

if [ -f "$HOME/.config/local-speech/dictation.env" ]; then
  pass "runtime config present: ~/.config/local-speech/dictation.env"
else
  warn "runtime config missing: ~/.config/local-speech/dictation.env (run ./which-device.py)"
fi

printf 'Check complete.\n'
