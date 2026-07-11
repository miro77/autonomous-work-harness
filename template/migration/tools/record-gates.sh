#!/usr/bin/env bash
# Record proof that gates passed for the exact current tree state.
# Called by gates.sh ONLY after all gates succeeded. The Stop hook compares
# against this. Never call manually to fake a pass — that defeats the harness.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p .harness/state
bash migration/tools/working-tree-hash.sh > .harness/state/gates-passed.diffsha
