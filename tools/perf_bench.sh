#!/usr/bin/env bash
# The windowed benchmark on a GPU box: dot-game's tools/perf_bench.sh with this checkout (see tools/perf_bench.gd).
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_perf_bench.sh" "$@"
