#!/usr/bin/env bash
# Renders this game's HUD to screenshots/ so a person can look at it.
#
#   tools/screenshot_hud.sh
#   tools/screenshot_hud.sh --action emote dance   # another runner playing an avatar action
#   tools/screenshot_hud.sh --touch                # a phone: touch buttons, no key hints, 844x390, files hud_*_touch.png
#   tools/screenshot_hud.sh --touch --resolution=932x430
#
# The map half is tools/bsp_preview.sh. This is the other half, and until now this was
# the only game in the family with no way to look at its own interface at all.
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and a 64 x 64
# viewport, and every frame it saves is empty — which is worse than no screenshot
# because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
# The xvfb screen is sized explicitly: its default 1280x1024x8 is not what --resolution asks for, and
# the window manager-less window then comes out at whatever the root allows (693 x 390 was seen).
res=1600x900
args=()
touch=0
for arg in "$@"; do
  case "$arg" in
    --resolution=*) res="${arg#--resolution=}" ;;
    --touch) touch=1; args+=("$arg") ;;
    *) args+=("$arg") ;;
  esac
done
if [ "$touch" = 1 ] && [[ ! " $* " == *" --resolution="* ]]; then res=844x390; fi
exec xvfb-run -a -s "-screen 0 ${res}x24" godot --path . --resolution "$res" --rendering-driver opengl3 --script tools/screenshot_hud.gd -- "${args[@]}"
