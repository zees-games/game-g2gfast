#!/usr/bin/env bash
# Frames of a solo deathmatch's end: the final killcam, the winner reveal, the board.
# tools/render_killcam.sh [--reduce-motion]; frames in screenshots/killcam/.
set -euo pipefail
cd "$(dirname "$0")/.."
export G2G_DEATHMATCH=1 G2G_INITIAL_MAP="${G2G_INITIAL_MAP:-bhop_g2g_intro}"
exec timeout 300 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_killcam.gd -- "$@"
