#!/usr/bin/env bash
# Renders the real offline client's Escape menu, help screen and flashlight to screenshots/.
#
#   tools/screenshot_menus.sh [map] [yaw] [pitch]
#
# See tools/screenshot_menus.gd for the frames. xvfb-run because this needs a rendering
# context; `--headless` gives a null renderer and every frame it saves is empty.
set -euo pipefail
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play and scrub it.
export DOT_SHOT_FRAMES=${DOT_SHOT_FRAMES:-8} DOT_SHOT_SECS=${DOT_SHOT_SECS:-1}
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1600x900 --script tools/screenshot_menus.gd -- "$@"
