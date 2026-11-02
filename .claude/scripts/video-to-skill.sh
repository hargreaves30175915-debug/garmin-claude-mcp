#!/usr/bin/env bash
# Download a video, extract frames + audio, and transcribe it.
# Usage: video-to-skill.sh <url> <out_dir> [frame_interval_seconds] [whisper_model]
# Produces in <out_dir>:
#   video.*            downloaded video
#   audio.wav          16 kHz mono audio
#   frames/            frame_0001.jpg ... (one every N seconds, plus scene changes)
#   frames/index.txt   frame filename -> timestamp (seconds)
#   transcript.txt     timestamped transcript
#   meta.json          title / uploader / duration / description from yt-dlp
set -euo pipefail

URL="${1:?usage: video-to-skill.sh <url> <out_dir> [interval] [model]}"
OUT="${2:?missing out_dir}"
INTERVAL="${3:-10}"
MODEL="${4:-base}"

VENV="${VIDEO_TO_SKILL_VENV:-$HOME/.cache/video-to-skill/venv}"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (apt install ffmpeg / brew install ffmpeg)" >&2; exit 1; }

# Isolated venv so we never touch system Python packages.
if [ ! -x "$VENV/bin/python" ]; then
  echo ">> creating venv at $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
fi
"$VENV/bin/python" -c "import yt_dlp, faster_whisper" 2>/dev/null || \
  "$VENV/bin/pip" install -q --upgrade yt-dlp faster-whisper

mkdir -p "$OUT/frames"
OUT="$(cd "$OUT" && pwd)"

echo ">> downloading $URL" >&2
"$VENV/bin/python" -m yt_dlp --no-playlist --no-progress \
  -f "bv*[height<=720]+ba/b[height<=720]/b" --merge-output-format mp4 \
  --write-info-json -o "$OUT/video.%(ext)s" "$URL" >&2

VIDEO="$(ls "$OUT"/video.* | grep -v '\.info\.json$' | head -1)"
"$VENV/bin/python" - "$OUT/video.info.json" "$OUT/meta.json" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
keep = {k: d.get(k) for k in ("title","uploader","duration","upload_date","webpage_url","description","chapters")}
json.dump(keep, open(sys.argv[2], "w"), indent=2)
PY
rm -f "$OUT/video.info.json"

echo ">> extracting frames (every ${INTERVAL}s + scene changes)" >&2
# One frame per INTERVAL seconds OR on a big scene change, whichever comes first.
ffmpeg -loglevel error -y -i "$VIDEO" \
  -vf "select='isnan(prev_selected_t)+gte(t-prev_selected_t\,${INTERVAL})+gt(scene\,0.4)*gte(t-prev_selected_t\,2)',scale='min(1280,iw)':-2,showinfo" \
  -fps_mode vfr -q:v 3 "$OUT/frames/frame_%04d.jpg" 2> "$OUT/frames/.showinfo.log" || true
grep -o 'pts_time:[0-9.]*' "$OUT/frames/.showinfo.log" | cut -d: -f2 | \
  awk '{ printf "frame_%04d.jpg\t%.1f\n", NR, $1 }' > "$OUT/frames/index.txt"
rm -f "$OUT/frames/.showinfo.log"

echo ">> extracting audio" >&2
if ffmpeg -loglevel error -y -i "$VIDEO" -vn -ac 1 -ar 16000 "$OUT/audio.wav"; then
  echo ">> transcribing with faster-whisper ($MODEL)" >&2
  "$VENV/bin/python" - "$OUT/audio.wav" "$OUT/transcript.txt" "$MODEL" <<'PY'
import sys
from faster_whisper import WhisperModel
audio, out, model = sys.argv[1:4]
m = WhisperModel(model, device="auto", compute_type="int8")
segs, info = m.transcribe(audio, vad_filter=True)
with open(out, "w") as f:
    f.write(f"# language: {info.language} ({info.language_probability:.2f})\n")
    for s in segs:
        mm, ss = divmod(int(s.start), 60)
        f.write(f"[{mm:02d}:{ss:02d}] {s.text.strip()}\n")
PY
else
  echo "(no audio track)" > "$OUT/transcript.txt"
fi

echo ">> done: $(wc -l < "$OUT/frames/index.txt") frames, $(wc -l < "$OUT/transcript.txt") transcript lines" >&2
echo "$OUT"
