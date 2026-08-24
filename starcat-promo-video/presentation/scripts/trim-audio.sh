#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────
# trim-audio.sh — 裁掉 public/audio 下所有 mp3 的首尾静音。
#
# 为什么存在：TTS 引擎（MiniMax / edge-tts 都一样）每条输出自带
# ~0.2s 头部静音和 ~1s 拖尾静音。头部静音让画面动画永远跑在人声前面
# （声画不同步的主因之一）；拖尾 × 每步累加会在整片里堆出几十秒死气。
#
# 保留少量自然气口：头 80ms / 尾 120ms，句中停顿不动。
# 幂等：已裁过的文件再跑一次基本无变化，不会越裁越短。
# 用法：bash scripts/trim-audio.sh   （在 presentation/ 目录下执行）
# ────────────────────────────────────────────────────────────────────
set -u
cd "$(dirname "$0")/.."

command -v ffmpeg >/dev/null || { echo "✗ ffmpeg not found" >&2; exit 1; }

fail=0
count=0
for f in public/audio/*/*.mp3; do
  [[ -e "$f" ]] || { echo "no audio yet"; exit 0; }
  tmp="$f.tmp.mp3"
  if ffmpeg -y -loglevel error -i "$f" \
    -af "silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.08,areverse,silenceremove=start_periods=1:start_threshold=-40dB:start_silence=0.12,areverse" \
    -c:a libmp3lame -q:a 2 "$tmp" </dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$f"
    count=$((count + 1))
  else
    rm -f "$tmp"
    echo "FAIL: $f" >&2
    fail=1
  fi
done

echo "trimmed $count files (exit=$fail)"
exit "$fail"
