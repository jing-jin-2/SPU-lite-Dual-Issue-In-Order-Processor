#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PYTHON=${PYTHON:-python3}
MODE=${1:-all}
if [[ $# -gt 1 ]]; then echo "Usage: $0 [all|demo|matmul|lanes|assembler]" >&2; exit 2; fi
case "$MODE" in
  all) TESTS=(demo matmul lanes) ;;
  demo|matmul|lanes) TESTS=("$MODE") ;;
  assembler) TESTS=() ;;
  *) echo "Usage: $0 [all|demo|matmul|lanes|assembler]" >&2; exit 2 ;;
esac
command -v "$PYTHON" >/dev/null || { echo "Missing Python; set PYTHON to a Python 3 executable." >&2; exit 127; }
"$PYTHON" -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
[[ "$MODE" == assembler ]] && exit 0
for tool in vlib vlog vsim; do
  command -v "$tool" >/dev/null || { echo "Missing $tool: load your licensed Questa/ModelSim environment." >&2; exit 127; }
done
mkdir -p "$ROOT/build"
# A separate directory prevents simultaneous runs from sharing a simulator library.
RUN=$(mktemp -d "$ROOT/build/run.XXXXXX")
echo "Results: $RUN"
cd "$RUN"
vlib work
vlog -64 +acc "$ROOT/rtl/spu_pkg.sv" "$ROOT/rtl/regfile.sv" \
  "$ROOT/rtl/spu_core.sv" "$ROOT/tb/spu_tb.sv" 2>&1 | tee compile.log
for name in "${TESTS[@]}"; do
  "$PYTHON" "$ROOT/tools/asm.py" "$ROOT/tests/programs/test_$name.s" -o "test_$name.hex"
  EXTRA=()
  [[ ${DUMP:-0} == 1 ]] && EXTRA+=(+DUMP)
  vsim -c -64 -onfinish exit spu_tb "+PROG=test_$name.hex" "+CHECK=$name" "${EXTRA[@]}" \
    -do 'onerror {quit -code 1 -force}; onbreak {quit -code 1 -force}; run -all; quit -code 1 -force' \
    2>&1 | tee "$name.log"
  # Require the marker even when a simulator exits successfully after an error.
  grep -Fq "REGRESSION PASS: $name (" "$name.log" || {
    echo "No verified PASS marker for $name; see $RUN/$name.log" >&2; exit 1;
  }
  if [[ -f spu_lite.vcd ]]; then mv spu_lite.vcd "$name.vcd"; fi
done
