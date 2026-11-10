#!/bin/bash
# Pacing rig client: EventHandler.swift (unchanged) + DisplaySim + a stand-in decoder on the REAL alvr_client_core (libalvr_client_core.so).
#   build_rig.sh        -> build/rig_client
# CORE_DIR: where `cargo build --release -p alvr_client_core` put the library (default ~/openxr-rig-alvr/target/release).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SWIFTC="${SWIFTC:-$(command -v swiftc-linux || command -v swiftc)}"
CORE_DIR="${CORE_DIR:-$HOME/openxr-rig-alvr/target/release}"
OUT="$HERE/build"; MOD="$OUT/modules_rig"; mkdir -p "$MOD"
COMMON=(-swift-version 5 -Onone -I "$HERE/CAlvr" -I "$MOD")
"$SWIFTC" "${COMMON[@]}" -parse-as-library -emit-module -emit-module-path "$MOD/AppleShims.swiftmodule" -module-name AppleShims -emit-object -o "$MOD/AppleShims.o" "$HERE/Shims/AppleShims.swift"
OBJS=("$MOD/AppleShims.o")
for fw in Metal VideoToolbox Combine AVKit Network UIKit QuartzCore simd; do
    echo "@_exported import AppleShims" > "$MOD/$fw.swift"
    "$SWIFTC" "${COMMON[@]}" -parse-as-library -emit-module -emit-module-path "$MOD/$fw.swiftmodule" -module-name "$fw" -emit-object -o "$MOD/$fw.o" "$MOD/$fw.swift"
    OBJS+=("$MOD/$fw.o")
done
"$SWIFTC" "${COMMON[@]}" -g -module-name Harness "$REPO/ALVRClient/EventHandler.swift" "$HERE/Rig/RigStubs.swift" "$HERE/Rig/RigLog.swift" \
    "$HERE/Harness/DisplaySim.swift" "$HERE/Rig/main.swift" "${OBJS[@]}" \
    -L "$CORE_DIR" -lalvr_client_core -Xlinker -rpath -Xlinker "$CORE_DIR" -o "$OUT/rig_client"
echo "built $OUT/rig_client"
