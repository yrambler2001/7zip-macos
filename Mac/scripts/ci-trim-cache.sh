#!/usr/bin/env bash
# ci-trim-cache.sh -- keep a CI compilation cache from growing without bound (pub4).
#
# CI restores the newest Xcode compilation cache (COMPILATION_CACHE_ENABLE_CACHING) by key prefix
# and saves it again under the new key, so entries from old commits accumulate. Xcode does not
# prune a cache directory it was handed this way, so this script deletes it once it is larger than
# the limit; the next run starts a fresh cache from the current sources. Deleting is always safe:
# the cache is an optimisation, never an input.
#
# Usage: Mac/scripts/ci-trim-cache.sh <cache dir> [limit in MB, default 2048]
set -euo pipefail
DIR="${1:?usage: ci-trim-cache.sh <cache dir> [limit MB]}"
LIMIT="${2:-2048}"
[ -d "$DIR" ] || { echo "ci-trim-cache: no $DIR, nothing to trim"; exit 0; }
MB="$(du -sm "$DIR" | cut -f1)"
if [ "$MB" -gt "$LIMIT" ]; then
  echo "ci-trim-cache: $DIR is $MB MB (> $LIMIT MB); deleting it so the next run starts afresh"
  rm -rf "$DIR"
else
  echo "ci-trim-cache: $DIR is $MB MB (limit $LIMIT MB); kept"
fi
