#!/usr/bin/env bash
# Run the GL test locally the same way TT's tt-gds-action's `gl_test`
# step does in CI (gds.yaml).
#
# Steps it mimics:
#   1. Librelane synth with USE_POWER_PINS defined (config.yaml ->
#      VERILOG_DEFINES: [USE_POWER_PINS]). Produces a netlist whose
#      top has VPWR/VGND inout ports and whose FILLER/decap cells
#      carry power pin connections.
#   2. Copy runs/RUN_*/final/nl/tt_um_tpu.nl.v -> test/gate_level_netlist.v.
#   3. cd test && PDK_ROOT=... GATES=yes make. Test Makefile passes
#      -DUSE_POWER_PINS so the loaded sky130 cell models declare
#      VPWR/VGND/VNB/VPB and elaboration matches the netlist.
#
# Pass --skip-synth to reuse the most recent runs/RUN_*/ instead of
# re-running librelane (useful when iterating on test/test.py).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDK="${PDK_ROOT:-$HOME/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71}"

if [[ ! -d "$PDK/sky130A/libs.ref/sky130_fd_sc_hd" ]]; then
  echo "PDK not found at $PDK"
  echo "Set PDK_ROOT or install the sky130 PDK via ciel."
  exit 1
fi

skip_synth=false
for arg in "$@"; do
  case "$arg" in
    --skip-synth) skip_synth=true ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# //'
      exit 0
      ;;
  esac
done

if ! $skip_synth; then
  echo "=== [1/3] librelane @ config.yaml ==="
  if ! command -v librelane >/dev/null; then
    echo "librelane not on PATH. From the librelane checkout:"
    echo "    cd /mnt/.../VLSI_DESIGN/librelane && nix-shell"
    echo "Then re-run this script from inside that shell."
    exit 1
  fi
  ( cd "$REPO" && librelane @config.yaml )
fi

echo "=== [2/3] stage netlist ==="
LATEST_RUN=$(ls -td "$REPO/runs/RUN_"* | head -1)
# Use the POWERED netlist (pnl/), not the plain netlist (nl/), so the
# FILLER/decap cells carry their .VPWR/.VGND/.VNB/.VPB connections.
# Without those, iverilog elaboration fails the moment the cell models
# (loaded with -DUSE_POWER_PINS) declare the matching ports.
NL="$LATEST_RUN/final/pnl/tt_um_tpu.pnl.v"
if [[ ! -f "$NL" ]]; then
  echo "No powered netlist at $NL. Did the full flow complete?"
  exit 1
fi
cp "$NL" "$REPO/test/gate_level_netlist.v"
echo "  staged powered netlist from $LATEST_RUN"

echo "=== [3/3] GATES=yes make (mimics CI gl_test) ==="
cd "$REPO/test"
rm -rf sim_build results.xml
PDK_ROOT="$PDK" GATES=yes make
