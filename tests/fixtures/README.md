# Original assembly fixtures

These two hex files were copied from the original ESE 545 final-project directory.
The Python tests compare newly assembled demo/matrix programs against them,
including zero padding to 512 words. Keep these fixtures independent of current
assembler output: regenerating them automatically would hide encoding regressions.

The original matrix simulation transcript is in `docs/results/matmul-original.txt`.
An encoding match does not prove ISA correctness or simulator correctness.
