# ────────────────────────────────────────────────────────────────────
# edge-tts provider — Microsoft Edge online neural voices, no API key.
#
# Why this file exists: MiniMax (mmx-cli) is currently unavailable, and
# the built-in openai.sh needs OPENAI_API_KEY. For Chinese voiceover,
# Edge neural voices (Yunxi / Xiaoxiao) are the closest free substitute.
#
# Docs:    https://github.com/rany2/edge-tts
# Install: python3 -m pip install edge-tts
# Voices:  edge-tts --list-voices
#          zh-CN-YunxiNeural     (male, default)
#          zh-CN-XiaoxiaoNeural  (female)
#
# Constraint: this backend talks to Microsoft's TTS endpoint. Needs
# network. Output is written as mp3 because the runner always uses a
# .mp3 destination path.
# ────────────────────────────────────────────────────────────────────

tts_check() {
  if command -v edge-tts >/dev/null; then
    return 0
  fi
  if python3 -c "import edge_tts" >/dev/null 2>&1; then
    return 0
  fi
  if command -v uvx >/dev/null; then
    return 0
  fi
  echo "✗ edge-tts not found (CLI / python module / uvx)." >&2
  return 1
}

tts_install_help() {
  cat <<'EOF' >&2
Install edge-tts (free, uses Microsoft Edge TTS, no API key):
  python3 -m pip install edge-tts

List voices:
  edge-tts --list-voices

Then:
  PRESENTATION_TTS=edge-tts npm run synthesize-audio
EOF
}

# Prefer the CLI binary; then python module; then `uvx edge-tts`
# (ephemeral install, no pip pollution — how this project actually runs it).
_tts_edge_bin() {
  if command -v edge-tts >/dev/null; then
    edge-tts "$@"
  elif python3 -c "import edge_tts" >/dev/null 2>&1; then
    python3 -m edge_tts "$@"
  else
    uvx edge-tts "$@"
  fi
}

tts_synthesize() {
  local text="$1"
  local out="$2"
  local voice="${3:-zh-CN-YunxiNeural}"
  [[ -z "$voice" ]] && voice="zh-CN-YunxiNeural"

  # Microsoft Edge TTS occasionally 429s under serial bursts. Retry with
  # backoff instead of leaving a hole in public/audio — the runner will
  # otherwise mark FAILED and continue, and Auto mode would fall back to
  # duration-by-character-count for that step.
  local attempt=1
  local max=4
  local delay=1
  while (( attempt <= max )); do
    if _tts_edge_bin --text "$text" --voice "$voice" --write-media "$out" >/dev/null 2>&1 \
      && [[ -s "$out" ]]; then
      return 0
    fi
    rm -f "$out"
    (( attempt == max )) && return 1
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}
