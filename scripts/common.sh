#!/usr/bin/env bash

local_speech_detect_launchers() {
  if [ -x /usr/bin/mise ] && /usr/bin/mise exec uv -- uv --version >/dev/null 2>&1; then
    LOCAL_SPEECH_DICTATION_EXEC='/usr/bin/mise exec uv -- uv run'
    LOCAL_SPEECH_WHICH_DEVICE_EXEC='/usr/bin/mise exec uv -- uv run'
    LOCAL_SPEECH_KOKORO_EXEC='/usr/bin/mise exec uv --'
    LOCAL_SPEECH_LAUNCH_MODE='mise+uv'
    return
  fi

  if command -v uv >/dev/null 2>&1; then
    LOCAL_SPEECH_DICTATION_EXEC='/usr/bin/env uv run'
    LOCAL_SPEECH_WHICH_DEVICE_EXEC='/usr/bin/env uv run'
    LOCAL_SPEECH_KOKORO_EXEC='/usr/bin/env bash'
    LOCAL_SPEECH_LAUNCH_MODE='uv'
    return
  fi

  printf 'Error: need /usr/bin/mise with uv available, or uv on PATH.\n' >&2
  return 1
}
