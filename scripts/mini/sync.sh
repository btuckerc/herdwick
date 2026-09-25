#!/bin/bash
# Mirror the working tree to the Mini (~/src/herdwick). Linux is the source of truth;
# Mini-only artefacts (build outputs, node_modules, TailscaleKit) are excluded so they survive.
set -euo pipefail
HOST=${MINI:-mini}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
rsync -a --delete \
  --exclude '.git/' --exclude '.build*/' --exclude '.swiftpm/' --exclude 'Frameworks/' \
  --exclude '*.xcodeproj/' --exclude 'build/' --exclude 'DerivedData/' --exclude 'node_modules/' \
  "$ROOT/" "$HOST:src/herdwick/"
