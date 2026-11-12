#!/bin/bash
# Applies patches/*.patch to the ALVR submodule (client_core changes we carry without a fork of ALVR).
# A patch that is already in is skipped; one that does not apply fails the build. Run from the repository root,
# before client_core is built (build_and_repack.sh and the two workflows do).
set -euo pipefail
cd "$(dirname "$0")/.."
for p in patches/*.patch; do
    if git -C ALVR apply --reverse --check "../$p" 2>/dev/null; then
        echo "already applied: $p"
    else
        git -C ALVR apply "../$p"
        echo "applied: $p"
    fi
done
