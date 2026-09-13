#!/bin/sh
# Frame-accurate test harness for the DALI Video Sync extension.
#
#   tools/harness/run.sh            build the test video if needed, then run the
#                                   whole suite headlessly and exit non-zero on
#                                   any failure
#   tools/harness/run.sh --serve    just serve it, for driving by hand at
#                                   http://127.0.0.1:8777/index.html
#                                   ("RUN TEST SUITE" button)
#   tools/harness/run.sh --head     same as the default but with a visible window
#
# Query flags on the page: ?raf=1 (force the rAF capture fallback),
# ?real=1 (native rAF/rVFC — only useful in a tab that is really on screen).
#
# The suite drives the REAL content.js and beacon.js behind a chrome stub. Most
# assertions use a stubbed beacon so streaming, service-worker death and page
# visibility can be flipped deterministically; the last group talks to the
# genuine beacon on 127.0.0.1:3697 if the DALI app is running, and skips
# cleanly if it is not.
set -e
cd "$(dirname "$0")"
[ -f content.js ] || ln -s ../../content.js content.js
[ -f beacon.js ] || ln -s ../../beacon.js beacon.js
if [ ! -f test_a.mp4 ]; then
  node gen-testvideo.mjs | ffmpeg -y -loglevel error \
    -f rawvideo -pix_fmt rgb24 -s 640x360 -r 30 -i - \
    -f lavfi -i "sine=frequency=200:sample_rate=44100:duration=180" \
    -filter:a volume=0.02 \
    -c:v libx264 -crf 12 -pix_fmt yuv420p -g 30 -c:a aac -b:a 48k -shortest test_a.mp4
fi

PORT=8777
case "$1" in
  --serve)
    echo "http://127.0.0.1:$PORT/index.html  — click RUN TEST SUITE"
    exec python3 -m http.server "$PORT" --bind 127.0.0.1
    ;;
esac

python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT INT TERM
# Wait for it to accept connections.
i=0
while [ $i -lt 50 ]; do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/index.html"; then break; fi
  sleep 0.1
  i=$((i + 1))
done

exec node drive.mjs --url "http://127.0.0.1:$PORT/index.html" "$@"
