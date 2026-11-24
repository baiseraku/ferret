#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/tests"
/usr/bin/swiftc "$ROOT/src/TunnelTraffic.swift" "$ROOT/src/TrafficCurve.swift" "$ROOT/tests/TunnelTrafficTests.swift" -o "$ROOT/build/tests/TunnelTrafficTests"
"$ROOT/build/tests/TunnelTrafficTests" "$@"
