#!/usr/bin/env bash
# Plan a route for imported maps, ride each with tools/stage_ride, keep only the ones that finish.
#
#   tools/route_verify.sh bhop_ocean [more ids]      # RIDE_SECONDS=240 REACH=280 SAFETY=0.85 to change
#
# One line per map to maps/routes/verify.log: `<id> <status> <detail>`; status is KEPT, RIDE_FAILED,
# NOROUTE (planner found none) or ERROR. A route that does not finish is deleted, never left on disk.
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
for id in "$@"; do
    out="maps/routes/$id.json"
    [ -f "$out" ] && { echo "$id HAVE already has a route" | tee -a maps/routes/verify.log; continue; }
    plan="$(python3 tools/route_plan.py "$id" --reach "${REACH:-280}" --safety "${SAFETY:-0.85}" --out "$out.try" 2>&1 | tail -1)"
    if [ ! -f "$out.try" ]; then
        echo "$id NOROUTE ${plan//$'\n'/ }" | tee -a maps/routes/verify.log; continue
    fi
    mv "$out.try" "$out"
    ride="$(timeout $((${RIDE_SECONDS:-240} + 120)) "$GODOT" --headless --fixed-fps 128 --path . tools/stage_ride.tscn -- "$id" 0 "${RIDE_SECONDS:-240}" 2>&1 | grep -E '^\[ride\] [a-z_0-9]+ after|ERROR|SCRIPT' | tail -3)"
    if grep -q 'FINISHED' <<< "$ride"; then
        echo "$id KEPT $plan | $ride" | tee -a maps/routes/verify.log
    else
        rm -f "$out"
        echo "$id RIDE_FAILED $plan | ${ride//$'\n'/ }" | tee -a maps/routes/verify.log
    fi
done
