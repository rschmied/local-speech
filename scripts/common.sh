#!/usr/bin/env bash

local_speech_detect_launchers() {
  local mise_bin
  mise_bin=$(command -v mise 2>/dev/null)

  if [ -n "$mise_bin" ] && "$mise_bin" exec uv -- uv --version >/dev/null 2>&1; then
    # Resolve shims dir: mise data-dir + /shims, falling back to dirname of mise's uv
    local data_dir shims_dir
    data_dir=$("$mise_bin" data-dir 2>/dev/null)
    if [ -n "$data_dir" ] && [ -d "$data_dir/shims" ]; then
      shims_dir="$data_dir/shims"
    else
      shims_dir=$(dirname "$("$mise_bin" which uv 2>/dev/null)")
    fi

    LOCAL_SPEECH_MISE_BIN="$mise_bin"
    LOCAL_SPEECH_MISE_SHIMS="$shims_dir"
    LOCAL_SPEECH_DICTATION_EXEC="$mise_bin exec uv -- uv run"
    LOCAL_SPEECH_WHICH_DEVICE_EXEC="$mise_bin exec uv -- uv run"
    LOCAL_SPEECH_KOKORO_EXEC="$mise_bin exec uv --"
    LOCAL_SPEECH_LAUNCH_MODE='mise+uv'
    return
  fi

  if command -v uv >/dev/null 2>&1; then
    LOCAL_SPEECH_MISE_BIN=''
    LOCAL_SPEECH_MISE_SHIMS=''
    LOCAL_SPEECH_DICTATION_EXEC='/usr/bin/env uv run'
    LOCAL_SPEECH_WHICH_DEVICE_EXEC='/usr/bin/env uv run'
    LOCAL_SPEECH_KOKORO_EXEC='/usr/bin/env bash'
    LOCAL_SPEECH_LAUNCH_MODE='uv'
    return
  fi

  printf 'Error: need mise (with uv) or uv on PATH.\n' >&2
  return 1
}
