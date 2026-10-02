# Verification

## Running checks

Run `./build.sh assembler` for Python checks or `./build.sh` for the complete
regression. The full regression requires a licensed Questa/ModelSim environment.
The runner always executes the Python tests before hardware simulation.
GitHub Actions runs only the Python suite and shell syntax checks; it makes no
claim that processor simulation passed.

## Test inventory

| Test | Checks | Boundaries |
|---|---|---|
| Original assembler encodings | Demo and matrix output match frozen original 512-word images | Protects existing encodings; does not independently establish ISA correctness |
| Invalid assembly | Register/immediate overflow, unknown opcode, duplicate/missing labels rejected | Representative invalid cases, not exhaustive parser fuzzing |
| Relative branches | Label-based backward branch matches a numeric byte displacement | Guards the signed-shift regression |
| Assembler CLI | Output padding and program capacity failure | No external dependencies |
| Lane program assembly | New program fits instruction memory | Assembly success does not establish processor correctness |
| Demo simulation | Expected top-word register values after issue conflicts, dependencies, branches and loop | Does not assert cycle-by-cycle pipeline behavior |
| Matrix simulation | All 16 output floating-point bit patterns | One fixed matrix pair; no NaN/denormal/rounding coverage |
| Lane simulation | Eight local-store words from four-lane addition and dependent load/add/store | Integer lane order and memory results; no exhaustive address coverage |

The matrix test preloads A[i][k] = 4i+k and B[k][j] = 16+4k+j.
Expected C is:

```text
 152   158   164   170
 504   526   548   570
 856   894   932   970
1208  1262  1316  1370
```

The lane test preloads `[1,2,3,4]` and `[10,20,30,40]`. It checks the stored
sum `[11,22,33,44]`, then reloads it and checks `[12,23,34,45]`. Input data is
installed before reset release; explicit idle bundles separate store and reload.

## Failure handling

The testbench requires `+PROG` and an explicit valid `+CHECK` mode. Unreadable
programs, mismatches, zero-check runs in checked modes, and timeouts use `$fatal`.
Reset is released on a falling clock edge to avoid a race with clocked logic.
The runner propagates compilation/simulation failures and also requires an explicit
regression PASS marker. `+CHECK=none` is a diagnostic mode only and emits no marker.
Old check tasks are preserved as reference but are not regression targets.

## Validation performed during preparation

- Five Python unittest methods passed using the available Python 3.6 interpreter.
- Demo and matrix assembly output matched the original frozen hex files exactly.
- The new lane program assembled within the 512-word instruction memory limit.
- Bash syntax checks passed for both runner scripts.
- Processor RTL was compared byte-for-byte with the original source.
- The original PDF was moved without modification.
- Runner plumbing was checked with mock tools: PASS exits 0, a missing PASS
  marker exits 1, and a simulator error exit status is propagated. These are
  shell-runner checks, not HDL simulation.
- Questa/ModelSim was unavailable; updated HDL and simulator exit handling have
  not been compiled or exercised with the real simulator in this environment.

The historical matrix transcript records 16/16 checks and STOP at cycle 440.
It predates the testbench and runner changes; retain that distinction when citing it.

## Next verification work

1. Run all three simulations on the original licensed Questa installation and
   record tool version, commands, summaries, and waveform observations.
2. Confirm the runner rejects a deliberately incorrect expected result and a
   nonterminating program on that same installation.
3. Add cycle-level assertions for stalls, replay, and wrong-path side effects.
4. Add randomized reference-model comparisons and further SIMD permutation cases.
5. Measure branch prediction and issue utilization only after adding validated counters.

No code/functional coverage percentage, timing result, or synthesis resource
estimate has been measured. Do not infer those metrics from the number of checks.
