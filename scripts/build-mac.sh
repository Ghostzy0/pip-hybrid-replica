#!/bin/sh
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [baseline]" >&2
  exit 2
fi
TASK_EDITION=${1:-baseline}
if [ "$TASK_EDITION" != baseline ]; then
  echo "This repository publishes only the neutral baseline. Use 'baseline'." >&2
  exit 2
fi
exec "$TASK_ROOT/scripts/build-mac-shared.sh" baseline
