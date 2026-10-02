# Architecture notes

The design separates shared instruction/result types (`rtl/spu_pkg.sv`), the
register file (`rtl/regfile.sv`), and processor behavior (`rtl/spu_core.sv`).
The assembler in `tools/asm.py` emits 32-bit hex words for `$readmemh`.

## Execution flow

Instruction fetch supplies a pair of instructions. Decode assigns work to the
even and odd execution pipes. Issue conflicts and dependencies can require a
stall or replay of the second slot. Register operands are read and replaced by
forwarded results when an eligible older instruction has produced them.
Execution results progress through pipeline packets toward register writeback.
The odd pipe also handles local-store access and branch resolution.

The processor has a 16-entry branch target buffer with tags and valid bits,
and a table of two-bit prediction counters. Branch resolution can redirect fetch
and flush younger work. The source models eight execution/forwarding/writeback
stages after fetch, decode, and register read/forwarding.

Word lane 0 is bits `[127:96]`; lane 3 is bits `[31:0]`. Local-store entries
are 16-byte quadwords. The assembler accepts byte offsets for `lqd`/`stqd` and
encodes the scaled instruction immediate. Numeric branch displacements are also
expressed in bytes; for example, `br -8` branches backward two instruction words.
Labels are preferable for readable programs.

## Waveform walkthrough

Generate a trace with `DUMP=1 ./build.sh demo` and open the resulting `demo.vcd`
in a waveform viewer. Inspect these DUT signals alongside `clk` and `rst`:

| Signals | What to examine |
|---|---|
| `pc_out`, `cycle_count`, `done` | Fetch progression and STOP |
| `pending_slot1`, `struct_haz`, `replay_slot1` | Serialization and replay of an issue pair |
| `stall`, `haz_stall` | Dependency stalls |
| `fw_opA_even`, `fw_opA_odd` | Forwarded operand values |
| `rf_wr_en0`, `rf_wr_en1`, `rf_wr_addr0`, `rf_wr_addr1` | Register writes |
| `pred_taken`, `branch_taken`, `mispredicted`, `flush` | Branch prediction and recovery |

Use the assembly section comments to locate the corresponding instruction sequence.
An annotated screenshot should identify the producer/consumer instructions, signal
names, and relevant clock edges. No waveform screenshot has been generated for the
reorganized version yet.

## Scope

This design contains behavioral floating-point operations implemented using
`shortreal`. It is not evidence of a synthesized floating-point datapath or fully
compliant fused arithmetic. Memory arrays are behavioral models. Simulator clocks
and stage counts do not establish achievable hardware frequency.
