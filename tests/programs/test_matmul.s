# ====================================================================
# test_matmul.s -- 4x4 SP FP matrix multiply  C = A * B
# Per professor's spec:
#   * single-precision FLOATING POINT (not integer)
#   * use multiply-add instructions (fma)
#   * A and B are pre-loaded into LS at address 0 BEFORE simulation
#     by the testbench -- this program contains NO SPU instructions
#     that initialise LS (no il/stqd setup)
#   * B is stored row-major (no pre-transpose)
# ====================================================================
#
# LS layout (pre-loaded by testbench):
#   A   in lstore[0..3]    (byte 0x000..0x030)   row-major, SP FP
#   B   in lstore[4..7]    (byte 0x040..0x070)   row-major, SP FP
#   C   in lstore[8..11]   (byte 0x080..0x0B0)   output rows
#
# Test data (from prof):
#   A[i][k] = 4*i + k      ->  A[0]=[0,1,2,3], A[1]=[4,5,6,7], ...
#   B[k][j] = 16 + 4*k + j ->  B[0]=[16,17,18,19], B[1]=[20,21,22,23], ...
# Expected C[i][j] = sum_k A[i][k]*B[k][j]:
#   C[0] = [ 152, 158, 164, 170]
#   C[1] = [ 504, 526, 548, 570]
#   C[2] = [ 856, 894, 932, 970]
#   C[3] = [1208,1262,1316,1370]
#
# Algorithm -- outer product accumulation (one fma per inner step):
#   for i = 0..3:
#       C_row = 0
#       for k = 0..3 (UNROLLED):
#           bc <- broadcast(A[i][k])              // 5-step PERM sequence
#           C_row <- fma(bc, B[k], C_row)         // single fma instruction
#       store C[i]
# ====================================================================


# -------- Base pointers and broadcast mask --------
    ila     r1, 0x000         # A current-row pointer (byte addr)
    lnop
    ila     r2, 0x040         # B base
    lnop
    ila     r3, 0x080         # C current-row pointer
    lnop
    fsmbi   r40, 0xF000       # mask = [0xFFFFFFFF, 0, 0, 0]
    lnop
    nop
    lnop
    nop
    lnop


# -------- Pre-load all 4 B rows into registers (used 4 times each) --------
# Note: lqd/stqd immediate is in BYTES (asm.py >>4 to encode as quadword
# offset).  So 16 = 1 quadword forward, 32 = 2 quadwords, etc.
    nop
    lqd     r30,  0(r2)        # B[0]  (lstore[4])
    nop
    lqd     r31, 16(r2)        # B[1]  (lstore[5])
    nop
    lqd     r32, 32(r2)        # B[2]  (lstore[6])
    nop
    lqd     r33, 48(r2)        # B[3]  (lstore[7])


# -------- Zero register for accumulator init --------
    il      r90, 0            # r90 = 0 (FP +0.0 also encodes as 0x00000000)
    lnop
    nop
    lnop


# -------- Initialize loop counter --------
    il      r80, 4            # i counter (decrements to 0)
    lnop
    nop
    lnop


# ====================================================================
#  Outer loop: for each row i, compute C[i] and store
# ====================================================================
matmul_loop:

    # Load A[i] (the whole row)
    nop
    lqd     r20, 0(r1)         # r20 = A[i] = [a0, a1, a2, a3]

    # Initialize C_row accumulator to FP zero
    or      r60, r90, r90      # r60 = 0 (use OR-with-zero as "move")
    lnop

    # ================================================================
    # k = 0  : broadcast A[i][0]  (already at word 0 of A_row)
    # ================================================================
    and     r70, r20, r40       # [a0, 0, 0, 0]
    lnop
    nop
    rotqbyi r71, r70, 4         # [0, 0, 0, a0]
    or      r72, r70, r71       # [a0, 0, 0, a0]
    lnop
    nop
    rotqbyi r73, r72, 8         # [0, a0, a0, 0]
    or      r74, r72, r73       # [a0, a0, a0, a0]   <- broadcast complete
    lnop
    fma     r60, r74, r30, r60  # C_row = bc(a0) * B[0] + C_row    (FP fused multiply-add)
    lnop

    # ================================================================
    # k = 1  : broadcast A[i][1]  (at word 1 of A_row)
    # ================================================================
    nop
    rotqbyi r68, r20, 4         # bring word 1 to word 0: [a1, a2, a3, a0]
    and     r70, r68, r40       # [a1, 0, 0, 0]
    lnop
    nop
    rotqbyi r71, r70, 4
    or      r72, r70, r71
    lnop
    nop
    rotqbyi r73, r72, 8
    or      r74, r72, r73       # [a1, a1, a1, a1]
    lnop
    fma     r60, r74, r31, r60  # C_row += bc(a1) * B[1]
    lnop

    # ================================================================
    # k = 2  : broadcast A[i][2]
    # ================================================================
    nop
    rotqbyi r68, r20, 8
    and     r70, r68, r40
    lnop
    nop
    rotqbyi r71, r70, 4
    or      r72, r70, r71
    lnop
    nop
    rotqbyi r73, r72, 8
    or      r74, r72, r73       # [a2, a2, a2, a2]
    lnop
    fma     r60, r74, r32, r60  # C_row += bc(a2) * B[2]
    lnop

    # ================================================================
    # k = 3  : broadcast A[i][3]
    # ================================================================
    nop
    rotqbyi r68, r20, 12
    and     r70, r68, r40
    lnop
    nop
    rotqbyi r71, r70, 4
    or      r72, r70, r71
    lnop
    nop
    rotqbyi r73, r72, 8
    or      r74, r72, r73       # [a3, a3, a3, a3]
    lnop
    fma     r60, r74, r33, r60  # C_row += bc(a3) * B[3]
    lnop

    # Store C[i] (no packing needed -- fma already produced the SIMD row)
    nop
    stqd    r60, 0(r3)

    # Advance pointers, decrement counter
    ai      r1, r1, 16          # A_curr += 16 bytes (next row)
    lnop
    ai      r3, r3, 16          # C_curr += 16 bytes
    lnop
    ai      r80, r80, -1        # counter--
    lnop
    nop
    brnz    r80, matmul_loop    # taken iters 1..3; not taken on iter 4


# Drain post-loop
    nop
    lnop
    nop
    lnop
    nop
    lnop


# -------- End --------
    stop
    lnop

