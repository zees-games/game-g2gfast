#!/bin/bash
# Publishes this game's pack (id game-airdrift; formerly game-g2gfast). worlds/, maps/imported and the model/pbr libraries link to g2gfast-maps.
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]   (lock: ./content.lock.json, override with --lock)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X=(); for d in screenshots worlds model-library pbr-library imported tools examples docs images .github; do X+=(--exclude-dir "$d"); done
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-airdrift --host-addons "$HERE/../dot-server-deploy/addons.lock" "${X[@]}" --lock "$HERE/content.lock.json" "$@"
