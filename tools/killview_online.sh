#!/usr/bin/env bash
# A real online kill view: a dedicated server and two client processes over ENet (xvfb for the victim).
#   heavy -- tools/killview_online.sh [camera 0|1]; frames and logs in screenshots/killview_online<camera>/.
set -u
cd "$(dirname "$0")/.."
CAM="${1:-1}"
OUT="$PWD/screenshots/killview_online$CAM"
rm -rf "$OUT"; mkdir -p "$OUT"
PORT=$((27300 + RANDOM % 500))
SCENE=res://tools/killview_online.tscn
timeout 150 godot --headless --path . "$SCENE" -- --role server --port "$PORT" --data "$OUT" --camera "$CAM" > "$OUT/server.log" 2>&1 &
SPID=$!
sleep 15
timeout 120 godot --headless --path . "$SCENE" -- --role killer --port "$PORT" --data "$OUT" > "$OUT/killer.log" 2>&1 &
KPID=$!
sleep 3
timeout 120 xvfb-run -a godot --path . --resolution 1280x720 "$SCENE" -- --role victim --port "$PORT" --data "$OUT" > "$OUT/victim.log" 2>&1
V=$?
touch "$OUT/stop"
wait "$KPID" "$SPID" 2>/dev/null
echo "victim exit $V; frames: $(ls "$OUT"/victim_*.png 2>/dev/null | wc -l)"
