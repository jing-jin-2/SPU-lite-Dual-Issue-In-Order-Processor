// SPU-lite self-checking simulation testbench.
// Run from the repository root: ./build.sh [all|demo|matmul|lanes]
// Required: +PROG=<hex file> +CHECK=demo|matmul|lanes|none
// +CHECK=none is an explicit diagnostic run and emits no regression PASS.
// Optional: +DUMP writes spu_lite.vcd in the simulator working directory.
// Legacy check tasks below are retained as reference only; their programs
// are not shipped, and the runner does not dispatch those tasks.
`timescale 1ns/1ps

module spu_tb;
  import spu_pkg::*;

  logic        clk, rst;
  logic        done;
  logic [10:0] pc_out;
  logic [63:0] cycle_count;

  spu_core dut (
    .clk(clk), .rst(rst),
    .done(done), .pc_out(pc_out),
    .cycle_count(cycle_count)
  );

  // Clock: 10ns period
  initial clk = 0;
  always #5 clk = ~clk;

  // ----------------------------------------------------
  //  Per-test pass/fail counters
  // ----------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;

  task automatic check(input int reg_idx,
                       input logic [31:0] expected,
                       input string name);
    logic [31:0] actual;
    actual = dut.u_rf.regs[reg_idx][127:96];
    if (actual === expected) begin
      $display("  [PASS] r%0d = 0x%08h   %s", reg_idx, actual, name);
      pass_count++;
    end else begin
      $display("  [FAIL] r%0d = 0x%08h (expected 0x%08h)   %s",
               reg_idx, actual, expected, name);
      fail_count++;
    end
  endtask

  // ================================================================
  //  ARCHIVED: check_all() -- for historical test_all.s (not shipped).
  //  Wrapped in `ifdef so it compiles only if explicitly requested.
  //  Define ENABLE_ARCHIVED_CHECKS to bring it back.
  // ================================================================
  `ifdef ENABLE_ARCHIVED_CHECKS
  task automatic check_all();
    pass_count = 0;
    fail_count = 0;
    $display("--- Setup registers ---");
    check( 1, 32'h0000000A, "il   r1, 10");
    check( 2, 32'h00000014, "il   r2, 20");
    check( 3, 32'h00000007, "il   r3, 7");
    check( 4, 32'h000000FF, "il   r4, 255");
    check( 5, 32'hFFFFFFFF, "il   r5, -1");
    check( 6, 32'h00012345, "ila  r6, 0x12345");
    check( 7, 32'h12340000, "ilhu r7, 0x1234");
    check( 8, 32'h000F000F, "ilh  r8, 15");
    check( 9, 32'h00040004, "ilh  r9, 4");
    check(80, 32'h3F800000, "ilhu r80, 0x3F80    (= 1.0)");
    check(81, 32'h40000000, "ilhu r81, 0x4000    (= 2.0)");
    check(82, 32'h3F000000, "ilhu r82, 0x3F00    (= 0.5)");

    $display("--- FX1 word arithmetic ---");
    check(10, 32'h0000001E, "a    r10, r1, r2     (10 + 20)");
    check(11, 32'h0000000F, "ai   r11, r1, 5      (10 + 5)");
    check(12, 32'h0000000A, "sf   r12, r1, r2     (r2 - r1)");
    check(13, 32'h0000005A, "sfi  r13, r1, 100    (100 - 10)");

    $display("--- Logical ---");
    check(14, 32'h00000007, "and  r14, r3, r4     (7 & 0xFF)");
    check(15, 32'h000000FF, "or   r15, r3, r4     (7 | 0xFF)");
    check(16, 32'h000000F8, "xor  r16, r3, r4     (7 ^ 0xFF)");
    check(17, 32'hFFFFFFF8, "nor  r17, r3, r3     (~7)");
    check(18, 32'hFFFFFFF8, "nand r18, r3, r3     (~7)");
    check(19, 32'hFFFFFFFF, "eqv  r19, r3, r3     (~0)");
    check(20, 32'h00000007, "andi r20, r3, 0xF");
    check(21, 32'h000000F7, "ori  r21, r3, 0xF0");
    check(22, 32'h00000008, "xori r22, r3, 0xF");

    $display("--- Compare (word) ---");
    check(23, 32'hFFFFFFFF, "ceq   r23, r1, r1");
    check(24, 32'hFFFFFFFF, "ceqi  r24, r1, 10");
    check(25, 32'hFFFFFFFF, "cgt   r25, r2, r1");
    check(26, 32'hFFFFFFFF, "cgti  r26, r1, 5");
    check(27, 32'hFFFFFFFF, "clgt  r27, r4, r1");
    check(28, 32'hFFFFFFFF, "clgti r28, r1, 5");

    $display("--- Shift / rotate (word) ---");
    check(29, 32'h00000500, "shl   r29, r1, r3    (10 << 7)");
    check(30, 32'h000000A0, "shli  r30, r1, 4     (10 << 4)");
    check(31, 32'h00000500, "rot   r31, r1, r3    (rotL 10 by 7)");
    check(32, 32'h000000A0, "roti  r32, r1, 4");

    $display("--- Multiply ---");
    check(33, 32'h000000C8, "mpy   r33, r1, r2    (signed 10*20)");
    check(34, 32'h000000C8, "mpyu  r34, r1, r2    (unsigned 10*20)");
    check(35, 32'h00000032, "mpyi  r35, r1, 5     (10*5)");

    $display("--- Byte unit / select ---");
    check(36, 32'h0000001D, "clz   r36, r3        (29 leading zeros in 7)");
    check(37, 32'h00000008, "cntb  r37, r4        (byte3=0xFF -> 8)");
    check(38, 32'h00000014, "selb  r38, r1, r2, r4 (mask r4=0xFF)");

    $display("--- Halfword arithmetic ---");
    check(39, 32'h001E001E, "ah    r39, r8, r8    (halves: 15+15)");
    check(40, 32'h00100010, "ahi   r40, r8, 1     (halves: 15+1)");
    check(41, 32'h00000000, "sfh   r41, r8, r8    (halves: 15-15)");
    check(42, 32'h00550055, "sfhi  r42, r8, 100   (halves: 100-15)");

    $display("--- Halfword logic immediates ---");
    check(43, 32'h00070007, "andhi r43, r8, 0x7");
    check(44, 32'h00FF00FF, "orhi  r44, r8, 0xF0");
    check(45, 32'h00F000F0, "xorhi r45, r8, 0xFF");

    $display("--- Halfword shift / rotate ---");
    check(46, 32'h00F000F0, "shlh  r46, r8, r9    (halves: 0x0F << 4)");
    check(47, 32'h00F000F0, "shlhi r47, r8, 4");
    check(48, 32'h00F000F0, "roth  r48, r8, r9    (halves: rot 0x0F by 4)");
    check(49, 32'h00F000F0, "rothi r49, r8, 4");

    $display("--- Halfword compare ---");
    check(50, 32'hFFFFFFFF, "ceqh   r50, r8, r8");
    check(51, 32'hFFFFFFFF, "ceqhi  r51, r8, 15");
    check(52, 32'hFFFFFFFF, "cgthi  r52, r8, 5");
    check(53, 32'hFFFFFFFF, "clgth  r53, r8, r9   (15 > 4 unsigned)");
    check(54, 32'hFFFFFFFF, "clgthi r54, r8, 5    (15 > 5 unsigned)");

    $display("--- Byte compare ---");
    check(55, 32'hFFFFFFFF, "ceqb   r55, r4, r4");
    check(56, 32'hFFFFFF00, "cgtb   r56, r4, r5   (signed: 0>-1 except byte3)");
    check(57, 32'hFFFFFF00, "clgtb  r57, r5, r4   (unsigned: 0xFF>0 except byte3)");

    $display("--- Carry / borrow generate ---");
    check(58, 32'h00000001, "cg    r58, r4, r5    (0xFF + 0xFFFFFFFF carries)");
    check(59, 32'h00000001, "bg    r59, r1, r2    (20 >= 10 -> no borrow)");

    $display("--- Multiply-add (RRR) ---");
    check(60, 32'h000000CF, "mpya  r60, r1, r2, r3 (10*20+7 = 207)");

    $display("--- Byte arithmetic ---");
    check(61, 32'h0000000A, "absdb r61, r1, r2    (byte diffs)");
    check(62, 32'h0000000F, "avgb  r62, r1, r2    (rounded byte avg)");
    check(63, 32'h0000001E, "sumb  r63, r1, r2    (per user impl: pairwise sum)");

    $display("--- Form select mask byte ---");
    check(64, 32'h000000FF, "fsmb  r64, r4        (bytes!=0 -> 0xFF)");
    check(65, 32'hFFFF0000, "fsmbi r65, 0xC000    (bits 15,14 -> bytes 0,1)");

    $display("--- Gather bits ---");
    check(66, 32'h00001111, "gb    r66, r4        (MSB of each of 16 bytes)");

    $display("--- FP arithmetic (single-precision) ---");
    check(67, 32'h40400000, "fa    r67, r80, r81  (1.0 + 2.0 = 3.0)");
    check(68, 32'h3F800000, "fs    r68, r81, r80  (2.0 - 1.0 = 1.0)");
    check(69, 32'h40800000, "fm    r69, r81, r81  (2.0 * 2.0 = 4.0)");
    check(70, 32'h40A00000, "fma   r70, r81, r81, r80  (2*2+1 = 5.0)");
    check(71, 32'h40400000, "fms   r71, r81, r81, r80  (2*2-1 = 3.0)");
    check(72, 32'hC0A00000, "fnms  r72, r81, r81, r80  (per user RTL: -5.0)");

    $display("--- FP compare ---");
    check(73, 32'hFFFFFFFF, "fceq  r73, r80, r80");
    check(74, 32'hFFFFFFFF, "fcgt  r74, r81, r80");
    check(75, 32'hFFFFFFFF, "fcmeq r75, r80, r80");
    check(76, 32'hFFFFFFFF, "fcmgt r76, r81, r80");

    $display("");
    $display("================================================");
    $display("  Tests passed: %0d / %0d",
             pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  OVERALL: PASS");
    else
      $display("  OVERALL: FAIL  (%0d failure%s)",
               fail_count, (fail_count == 1) ? "" : "s");
    $display("================================================");
  endtask
  `endif // ENABLE_ARCHIVED_CHECKS  (closes archived check_all)

  // ----------------------------------------------------
  //  Helper: check one 32-bit word of a local-store quadword.
  //  Used by check_matmul() to verify matrix elements stored in LS.
  // ----------------------------------------------------
  task automatic check_ls_word(input int ls_idx,
                                input int word_idx,
                                input logic [31:0] expected,
                                input string name);
    logic [31:0] actual;
    case (word_idx)
      0: actual = dut.lstore[ls_idx][127:96];
      1: actual = dut.lstore[ls_idx][95:64];
      2: actual = dut.lstore[ls_idx][63:32];
      3: actual = dut.lstore[ls_idx][31:0];
      default: actual = 32'h0;
    endcase
    if (actual === expected) begin
      $display("  [PASS] LS[%0d].w%0d = %0d   %s",
               ls_idx, word_idx, actual, name);
      pass_count++;
    end else begin
      $display("  [FAIL] LS[%0d].w%0d = %0d (expected %0d)   %s",
               ls_idx, word_idx, actual, expected, name);
      fail_count++;
    end
  endtask

  // ----------------------------------------------------
  //  test_matmul.s -- 4x4 SP FP matrix multiply C = A * B
  //  A, B pre-loaded by load_matmul_data() into LS at byte 0
  //  before reset deasserts.  Output C in lstore[8..11].
  //  Each lane is an IEEE-754 single-precision float; we display
  //  the 32-bit hex word and also the integer value of the float
  //  (since the test data is whole numbers, ftoi is exact).
  // ----------------------------------------------------
  function automatic int unsigned float_bits_to_int(input logic [31:0] f);
    // For positive whole-number floats with exponent in range, decode
    // the IEEE-754 bit pattern back to its integer value for display.
    automatic int unsigned mant;
    automatic int e;
    if (f == 32'h00000000) return 0;
    e    = f[30:23] - 127;
    mant = (1 << 23) | f[22:0];
    if (e >= 23) return mant << (e - 23);
    else         return mant >> (23 - e);
  endfunction

  task automatic check_matmul();
    pass_count = 0;
    fail_count = 0;

    $display("");
    $display("================================================");
    $display("  4x4 SP FLOATING-POINT MATRIX MULTIPLY  C = A * B");
    $display("  A, B pre-loaded into LS (no SPU init code)");
    $display("================================================");

    $display("");
    $display("  Input A (lstore[0..3], FP):");
    for (int i = 0; i < 4; i++) begin
      $display("    A[%0d] = [%0d, %0d, %0d, %0d]  (hex %h)", i,
               float_bits_to_int(dut.lstore[i][127:96]),
               float_bits_to_int(dut.lstore[i][95:64]),
               float_bits_to_int(dut.lstore[i][63:32]),
               float_bits_to_int(dut.lstore[i][31:0]),
               dut.lstore[i]);
    end

    $display("");
    $display("  Input B (lstore[4..7], FP, row-major, NO transpose):");
    for (int i = 0; i < 4; i++) begin
      $display("    B[%0d] = [%0d, %0d, %0d, %0d]  (hex %h)", i,
               float_bits_to_int(dut.lstore[4+i][127:96]),
               float_bits_to_int(dut.lstore[4+i][95:64]),
               float_bits_to_int(dut.lstore[4+i][63:32]),
               float_bits_to_int(dut.lstore[4+i][31:0]),
               dut.lstore[4+i]);
    end

    $display("");
    $display("  Output C (lstore[8..11], FP):");
    for (int i = 0; i < 4; i++) begin
      $display("    C[%0d] = [%0d, %0d, %0d, %0d]  (hex %h)", i,
               float_bits_to_int(dut.lstore[8+i][127:96]),
               float_bits_to_int(dut.lstore[8+i][95:64]),
               float_bits_to_int(dut.lstore[8+i][63:32]),
               float_bits_to_int(dut.lstore[8+i][31:0]),
               dut.lstore[8+i]);
    end

    $display("");
    $display("--- Verification (FP bit-pattern of expected results) ---");
    // C[0] = [152, 158, 164, 170]
    check_ls_word(8,  0, 32'h43180000, "C[0][0] = 152.0");
    check_ls_word(8,  1, 32'h431E0000, "C[0][1] = 158.0");
    check_ls_word(8,  2, 32'h43240000, "C[0][2] = 164.0");
    check_ls_word(8,  3, 32'h432A0000, "C[0][3] = 170.0");
    // C[1] = [504, 526, 548, 570]
    check_ls_word(9,  0, 32'h43FC0000, "C[1][0] = 504.0");
    check_ls_word(9,  1, 32'h44038000, "C[1][1] = 526.0");
    check_ls_word(9,  2, 32'h44090000, "C[1][2] = 548.0");
    check_ls_word(9,  3, 32'h440E8000, "C[1][3] = 570.0");
    // C[2] = [856, 894, 932, 970]
    check_ls_word(10, 0, 32'h44560000, "C[2][0] = 856.0");
    check_ls_word(10, 1, 32'h445F8000, "C[2][1] = 894.0");
    check_ls_word(10, 2, 32'h44690000, "C[2][2] = 932.0");
    check_ls_word(10, 3, 32'h44728000, "C[2][3] = 970.0");
    // C[3] = [1208, 1262, 1316, 1370]
    check_ls_word(11, 0, 32'h44970000, "C[3][0] = 1208.0");
    check_ls_word(11, 1, 32'h449DC000, "C[3][1] = 1262.0");
    check_ls_word(11, 2, 32'h44A48000, "C[3][2] = 1316.0");
    check_ls_word(11, 3, 32'h44AB4000, "C[3][3] = 1370.0");

    $display("");
    $display("================================================");
    $display("  MATMUL  Tests passed: %0d / %0d",
             pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  OVERALL: PASS");
    else
      $display("  OVERALL: FAIL  (%0d failure%s)",
               fail_count, (fail_count == 1) ? "" : "s");
    $display("================================================");
  endtask

  // ----------------------------------------------------
  //  Pre-load A and B into LS at byte address 0 BEFORE reset deasserts.
  //  Per professor spec: "no Cell SPU instructions" used to initialise.
  //  Each quadword packs four IEEE-754 single-precision floats, big-endian
  //  (word 0 = bits 127:96).  Whole-number values: bits = 0x00000000 for
  //  0.0; otherwise sign(0) | exp(127+log2(n)) | mantissa.
  // ----------------------------------------------------
  task automatic load_matmul_data();
    // A matrix at lstore[0..3] (byte addresses 0x000..0x030)
    dut.lstore[0] = 128'h00000000_3F800000_40000000_40400000;  // [ 0.0,  1.0,  2.0,  3.0]
    dut.lstore[1] = 128'h40800000_40A00000_40C00000_40E00000;  // [ 4.0,  5.0,  6.0,  7.0]
    dut.lstore[2] = 128'h41000000_41100000_41200000_41300000;  // [ 8.0,  9.0, 10.0, 11.0]
    dut.lstore[3] = 128'h41400000_41500000_41600000_41700000;  // [12.0, 13.0, 14.0, 15.0]
    // B matrix at lstore[4..7] (byte addresses 0x040..0x070), row-major
    dut.lstore[4] = 128'h41800000_41880000_41900000_41980000;  // [16.0, 17.0, 18.0, 19.0]
    dut.lstore[5] = 128'h41A00000_41A80000_41B00000_41B80000;  // [20.0, 21.0, 22.0, 23.0]
    dut.lstore[6] = 128'h41C00000_41C80000_41D00000_41D80000;  // [24.0, 25.0, 26.0, 27.0]
    dut.lstore[7] = 128'h41E00000_41E80000_41F00000_41F80000;  // [28.0, 29.0, 30.0, 31.0]
    $display("[tb] pre-loaded A and B (FP) into LS at byte 0");
  endtask

  // ----------------------------------------------------
  //  test_demo.s -- single-program live-demo walkthrough.
  //  Sections in the order the prof checks at demo time:
  //    1. hazard-free first two   2. structural hazard
  //    3. RAW fwd same-pipe       4. RAW fwd cross-pipe
  //    5. RAW requires stall      6. branch not-taken
  //    7. branch taken            8. loop (predictor warming)
  // ----------------------------------------------------
  task automatic check_demo();
    pass_count = 0;
    fail_count = 0;

    $display("");
    $display("================================================");
    $display("  SECTION 1 - first two hazard-free instructions");
    $display("                (pipeline depth check)");
    $display("================================================");
    check(10, 32'h00000064, "il      r10, 100   (even FX1, slot 0)");
    check(11, 32'h00000000, "rotqbyi r11, r0, 0 (odd PERM, slot 1)");

    $display("");
    $display("--- SETUP ---");
    check( 1, 32'h00000000, "il   r1, 0       (zero condition)");
    check( 2, 32'h00000005, "il   r2, 5       (nonzero condition)");
    check(80, 32'h3F800000, "ilhu r80, 0x3F80 (= 1.0)");
    check(81, 32'h40000000, "ilhu r81, 0x4000 (= 2.0)");

    $display("");
    $display("================================================");
    $display("  SECTION 2 - structural hazard (both -> FX1)");
    $display("                slot 1 replays next cycle");
    $display("================================================");
    check(12, 32'h00000032, "il r12, 50  (slot 0 - issues)");
    check(13, 32'h0000003C, "il r13, 60  (slot 1 - replays)");

    $display("");
    $display("================================================");
    $display("  SECTION 3 - RAW forward, SAME pipe");
    $display("                FX1 -> FX1, no stall");
    $display("================================================");
    check(14, 32'h00000007, "il r14, 7         (producer)");
    check(15, 32'h0000000A, "ai r15, r14, 3    (forwards from FX1 pipe[1])");

    $display("");
    $display("================================================");
    $display("  SECTION 4 - RAW forward, CROSS pipe");
    $display("                FX1 -> PERM, no stall");
    $display("================================================");
    check(16, 32'h00000001, "il      r16, 1        (even producer)");
    check(17, 32'h00000001, "rotqbyi r17, r16, 0   (odd consumer, cross-pipe fwd)");

    $display("");
    $display("================================================");
    $display("  SECTION 5 - RAW that REQUIRES stall");
    $display("                FP lat 7 -> FX1, ~5 stall cycles");
    $display("================================================");
    check(18, 32'h40400000, "fa r18, r80, r81  (1.0 + 2.0 = 3.0)");
    check(19, 32'h40400000, "ai r19, r18, 0    (stalls 5 cyc, then fwd)");

    $display("");
    $display("================================================");
    $display("  SECTION 6 - branch NOT taken (correct pred)");
    $display("================================================");
    check(20, 32'h00000001, "brz r2 NOT taken (r2 nonzero) - post-AI ran -> r20 = 1");

    $display("");
    $display("================================================");
    $display("  SECTION 7 - branch TAKEN (mispred -> flush)");
    $display("================================================");
    check(21, 32'h00000000, "br taken - post-IL squashed -> r21 stays 0");

    $display("");
    $display("================================================");
    $display("  SECTION 8 - 3-iteration loop (predictor)");
    $display("================================================");
    check(22, 32'h00000000, "loop counter ends at 0");
    check(23, 32'h00000003, "loop accumulator = 3 iterations");

    $display("");
    $display("================================================");
    $display("  DEMO TEST  Tests passed: %0d / %0d",
             pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  OVERALL: PASS");
    else
      $display("  OVERALL: FAIL  (%0d failure%s)",
               fail_count, (fail_count == 1) ? "" : "s");
    $display("================================================");
  endtask

  // ================================================================
  //  ARCHIVED check tasks (block) -- for the older test programs in
  //  historical programs (test_basic, test_branch, test_hazard, test_ls,
  //  test_perm, test_min, test_min2, test_combined).  Wrapped in an
  //  `ifdef so they compile only when ENABLE_ARCHIVED_CHECKS is set.
  // ================================================================
  `ifdef ENABLE_ARCHIVED_CHECKS
  // ----------------------------------------------------
  //  test_basic.s expected values (kept for backward compat)
  // ----------------------------------------------------
  task automatic check_basic();
    pass_count = 0;
    fail_count = 0;
    check(1, 32'd10, "il   r1, 10");
    check(2, 32'd20, "il   r2, 20");
    check(3, 32'd30, "a    r3, r1, r2");
    check(4, 32'd35, "ai   r4, r3, 5");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL");
  endtask

  // ----------------------------------------------------
  //  test_branch.s expected values
  // ----------------------------------------------------
  task automatic check_branch();
    pass_count = 0;
    fail_count = 0;
    $display("--- Branch tests ---");
    check(10, 32'h00000000, "br    -- taken, skipped both increments");
    check(11, 32'h00000000, "brnz  -- taken (r2 nonzero)");
    check(12, 32'h00000000, "brz   -- taken (r1 zero)");
    check(13, 32'h00000000, "bra   -- taken");
    check(14, 32'h0000CAFE, "brsl  -- target reached, marker set");
    check(15, 32'h00000000, "brsl  -- pre-target writes squashed");
    check(16, 32'h00000000, "bi    -- taken via indirect target");
    check(18, 32'h00000005, "loop  -- accumulator after 5 iterations");
    check(17, 32'h00000000, "loop  -- counter at 0 (loop exited)");
    // -- New coverage --
    check(21, 32'h00000002, "brnz  -- NOT taken (r1 zero), both AIs ran");
    check(22, 32'h00000002, "brz   -- NOT taken (r2 nonzero), both AIs ran");
    check(23, 32'h00000000, "brhz  -- taken (low half of r1 = 0)");
    check(24, 32'h00000000, "brhnz -- taken (low half of r2 nonzero)");
    check(25, 32'h00000000, "brasl -- pre-target writes squashed");
    check(26, 32'h0000BEEF, "brasl -- target reached, marker set");
    check(29, 32'h00000000, "biz   -- taken (cond r1 == 0)");
    check(31, 32'h00000000, "binz  -- taken (cond r2 nonzero)");
    check(32, 32'h00000002, "biz   -- NOT taken (cond r2 nonzero), both AIs ran");
    check(34, 32'h00000001, "brsl link  -- bi r35 returned to post-brsl AI");
    check(37, 32'h00000001, "bi at slot 0 -- slot-1 AI dual-executed");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_hazard.s expected values
  //  Each producer-consumer pair forces a stall+forward.
  // ----------------------------------------------------
  task automatic check_hazard();
    pass_count = 0;
    fail_count = 0;
    $display("--- Stall / Hazard / Forwarding tests ---");
    // Test 1: basic back-to-back FX1
    check(10, 32'h00000005, "T1  r10 = 5");
    check(11, 32'h00000008, "T1  r11 = r10+3 = 8         (back-to-back FX1 forward)");
    // Test 2: 3-deep chain
    check(12, 32'h00000064, "T2  r12 = 100");
    check(13, 32'h00000065, "T2  r13 = r12+1 = 101");
    check(14, 32'h00000066, "T2  r14 = r13+1 = 102");
    check(15, 32'h00000067, "T2  r15 = r14+1 = 103       (3-deep chain)");
    // Test 3: same-bundle struct hazard + RAW
    check(16, 32'h00000007, "T3  r16 = 7");
    check(17, 32'h0000000F, "T3  r17 = r16+8 = 15        (struct haz + RAW)");
    // Test 4: even producer -> odd consumer
    check(18, 32'h00000001, "T4  r18 = 1");
    check(19, 32'h00000010, "T4  r19 = r18<<4 = 16       (even->odd cross-pipe)");
    // Test 5: odd producer -> even consumer
    check(20, 32'h00000028, "T5  r20 = r1<<2 = 40");
    check(21, 32'h00000029, "T5  r21 = r20+1 = 41        (odd->even cross-pipe)");
    // Test 6: FP latency
    check(22, 32'h40400000, "T6  r22 = 3.0");
    check(23, 32'h40800000, "T6  r23 = r22+1.0 = 4.0     (FP latency forward)");
    // Test 7: MPY latency
    check(24, 32'h000000C8, "T7  r24 = 10*20 = 200");
    check(25, 32'h000000CD, "T7  r25 = r24+5 = 205       (MPY latency forward)");
    // Test 8: LS load-use
    check(26, 32'h0000000A, "T8  r26 = 10                (LQD result)");
    check(27, 32'h0000000B, "T8  r27 = r26+1 = 11        (LS load-use forward)");
    // Test 9: store data RAW
    check(29, 32'hFFFFFFFF, "T9  r29 = -1                (store data forwarded)");
    // Test 10: ADDX use_rc
    check(30, 32'h0000001E, "T10 r30 = 30                (ADDX use_rc forward)");
    // Test 11: SELB use_rc
    check(32, 32'h00000014, "T11 r32 = 20                (SELB use_rc forward)");
    // Test 12: branch condition
    check(34, 32'h0000002A, "T12 r34 = 42                (BRZ condition forward)");
    // Test 13: slot-swap dispatch (slot 0 odd, slot 1 even)
    check(35, 32'h00000014, "T13 r35 = r1<<1 = 20        (odd at slot 0 -- swap routing)");
    check(36, 32'h0000002A, "T13 r36 = 42                (even at slot 1)");
    // Test 14: dual-issue producers + cross-pipe consumers
    check(37, 32'h00000064, "T14 r37 = 100               (dual-issue even producer)");
    check(38, 32'h00000050, "T14 r38 = r1<<3 = 80        (dual-issue odd producer)");
    check(40, 32'h00000051, "T14 r40 = r38+1 = 81        (even consumer <- odd forward)");
    check(39, 32'h000000C8, "T14 r39 = r37<<1 = 200      (odd consumer <- even forward)");
    // Test 15: both-odd struct hazard + RAW
    check(41, 32'h00000014, "T15 r41 = r1<<1 = 20");
    check(42, 32'h00000050, "T15 r42 = r41<<2 = 80       (odd struct haz + RAW)");
    // Test 16: dual-issue WAW -- slot 0 even, slot 1 odd, both write r50
    check(50, 32'h000000A0, "T16 r50 = 160               (slot 1 odd wins WAW: PC priority)");
    // Test 17: dual-issue WAW -- slot 0 odd, slot 1 even, both write r51
    check(51, 32'h00000064, "T17 r51 = 100               (slot 1 even wins WAW: PC priority)");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_ls.s expected values
  // ----------------------------------------------------
  task automatic check_ls();
    pass_count = 0;
    fail_count = 0;
    $display("--- Load/Store tests ---");
    check(30, 32'hFFFFDEAD, "stqd->lqd at base #1, offset 0");
    check(31, 32'h00001234, "stqd->lqd at base #2, offset 0");
    check(32, 32'h00005A5A, "stqd->lqd at base #1, offset 16");
    check(33, 32'hFFFFDEAD, "stqa->lqa at absolute 0x300");
    check(34, 32'h00001234, "lqd re-read at base #2 (no clobber)");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_perm.s expected values
  //    r1 each word = 0x000ABCDE; r2 = 1; r3 = 4
  // ----------------------------------------------------
  task automatic check_perm();
    pass_count = 0;
    fail_count = 0;
    $display("--- Permute (quadword) tests ---");
    check(30, 32'h012ABC00, "shlqby  r1, r2=1   (left 1 byte)");
    check(31, 32'h012ABC00, "shlqbyi r1, 1");
    check(32, 32'h012ABC00, "rotqby  r1, r2=1");
    check(33, 32'h012ABC00, "rotqbyi r1, 1");
    check(34, 32'h0012ABC0, "shlqbi  r1, r3=4   (left 4 bits)");
    check(35, 32'h0012ABC0, "shlqbii r1, 4");
    check(36, 32'h0012ABC0, "rotqbi  r1, r3=4");
    check(37, 32'h0012ABC0, "rotqbii r1, 4");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_min.s -- bisection: 29-register setup + ONE FX1 op
  //  If r10 = 30, setup->straight-line boundary is fine
  //  If r10 = 0,  the boundary itself is broken
  // ----------------------------------------------------
  task automatic check_min();
    pass_count = 0;
    fail_count = 0;
    $display("--- Setup (full 29 registers) ---");
    check( 1, 32'h0000000A, "il r1");
    check(99, 32'h00000000, "il r99 (last setup write)");
    $display("--- Single straight-line test ---");
    check(10, 32'h0000001E, "a r10, r1, r2  (10+20=30)");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_min2.s -- bisection: 29-register setup + full straight-line
  //  (incl. perm interleave) but NO branches and NO load/store
  // ----------------------------------------------------
  task automatic check_min2();
    pass_count = 0;
    fail_count = 0;
    $display("--- Setup spot-checks ---");
    check( 1, 32'h0000000A, "il r1");
    check(83, 32'h00012ABC, "ila r83 (perm input)");
    check(99, 32'h00000000, "il r99 (last setup)");
    $display("--- Straight-line (mixed with perm) ---");
    check(10, 32'h0000001E, "a    r10, r1, r2");
    check(11, 32'h0000000F, "ai   r11, r1, 5");
    check(12, 32'h0000000A, "sf   r12, r1, r2");
    check(67, 32'h40400000, "fa   r67  (1+2)");
    check(33, 32'h000000C8, "mpy  r33  (10*20)");
    check(70, 32'h40A00000, "fma  r70");
    check(38, 32'h00000014, "selb r38");
    check(76, 32'hFFFFFFFF, "fcmgt r76 (last straight-line FP)");
    check(66, 32'h00001111, "gb   r66");
    $display("--- Permute (interleaved with straight-line) ---");
    check(110, 32'h012ABC00, "shlqby  r110");
    check(111, 32'h012ABC00, "shlqbyi r111");
    check(112, 32'h012ABC00, "rotqby  r112");
    check(113, 32'h012ABC00, "rotqbyi r113");
    check(114, 32'h0012ABC0, "shlqbi  r114");
    check(115, 32'h0012ABC0, "shlqbii r115");
    check(116, 32'h0012ABC0, "rotqbi  r116");
    check(117, 32'h0012ABC0, "rotqbii r117");
    $display("");
    $display("Tests passed: %0d / %0d", pass_count, pass_count+fail_count);
    if (fail_count == 0) $display("OVERALL: PASS"); else $display("OVERALL: FAIL  (%0d)", fail_count);
  endtask

  // ----------------------------------------------------
  //  test_combined.s expected values
  //   Big interleaved test: setup + straight-line (~70 mixed
  //   tests) + branches + load/store, all in one program.
  // ----------------------------------------------------
  task automatic check_combined();
    pass_count = 0;
    fail_count = 0;

    $display("--- Setup registers ---");
    check( 1, 32'h0000000A, "il   r1, 10");
    check( 2, 32'h00000014, "il   r2, 20");
    check( 3, 32'h00000007, "il   r3, 7");
    check( 4, 32'h000000FF, "il   r4, 255");
    check( 5, 32'hFFFFFFFF, "il   r5, -1");
    check( 6, 32'h00012345, "ila  r6, 0x12345");
    check( 7, 32'h12340000, "ilhu r7, 0x1234");
    check( 8, 32'h000F000F, "ilh  r8, 15");
    check( 9, 32'h00040004, "ilh  r9, 4");
    check(80, 32'h3F800000, "ilhu r80           (= 1.0)");
    check(81, 32'h40000000, "ilhu r81           (= 2.0)");
    check(82, 32'h3F000000, "ilhu r82           (= 0.5)");
    check(83, 32'h00012ABC, "ila  r83           (perm input)");
    check(84, 32'h00000001, "il   r84, 1");
    check(85, 32'h00000004, "il   r85, 4");
    check(86, 32'hFFFFDEAD, "il   r86, 0xDEAD");
    check(87, 32'h00001234, "il   r87, 0x1234");
    check(88, 32'h00005A5A, "il   r88, 0x5A5A");
    check(89, 32'h00000100, "ila  r89, 0x100");
    check(90, 32'h00000200, "ila  r90, 0x200");

    $display("--- FX1 word arithmetic ---");
    check(10, 32'h0000001E, "a    r10, r1, r2     (10 + 20)");
    check(11, 32'h0000000F, "ai   r11, r1, 5      (10 + 5)");
    check(12, 32'h0000000A, "sf   r12, r1, r2     (r2 - r1)");
    check(13, 32'h0000005A, "sfi  r13, r1, 100    (100 - 10)");

    $display("--- Logical ---");
    check(15, 32'h000000FF, "or   r15, r3, r4     (7 | 0xFF)");
    check(16, 32'h000000F8, "xor  r16, r3, r4     (7 ^ 0xFF)");
    check(17, 32'hFFFFFFF8, "nor  r17, r3, r3     (~7)");
    check(18, 32'hFFFFFFF8, "nand r18, r3, r3     (~7)");
    check(19, 32'hFFFFFFFF, "eqv  r19, r3, r3     (~0)");
    check(20, 32'h00000007, "andi r20, r3, 0xF");
    check(21, 32'h000000F7, "ori  r21, r3, 0xF0");
    check(22, 32'h00000008, "xori r22, r3, 0xF");

    $display("--- Compare (word) ---");
    check(23, 32'hFFFFFFFF, "ceq   r23, r1, r1");
    check(24, 32'hFFFFFFFF, "ceqi  r24, r1, 10");
    check(25, 32'hFFFFFFFF, "cgt   r25, r2, r1");
    check(26, 32'hFFFFFFFF, "cgti  r26, r1, 5");
    check(27, 32'hFFFFFFFF, "clgt  r27, r4, r1");
    check(28, 32'hFFFFFFFF, "clgti r28, r1, 5");

    $display("--- Shift / rotate (word) ---");
    check(29, 32'h00000500, "shl   r29, r1, r3    (10 << 7)");
    check(30, 32'h000000A0, "shli  r30, r1, 4     (10 << 4)");
    check(31, 32'h00000500, "rot   r31, r1, r3    (rotL 10 by 7)");
    check(32, 32'h000000A0, "roti  r32, r1, 4");

    $display("--- Multiply ---");
    check(33, 32'h000000C8, "mpy   r33, r1, r2    (10*20)");
    check(34, 32'h000000C8, "mpyu  r34, r1, r2    (10*20)");
    check(35, 32'h00000032, "mpyi  r35, r1, 5     (10*5)");

    $display("--- Byte unit / select ---");
    check(36, 32'h0000001D, "clz   r36, r3        (29 leading zeros)");
    check(37, 32'h00000008, "cntb  r37, r4        (byte3=0xFF -> 8)");
    check(38, 32'h00000014, "selb  r38, r1, r2, r4");

    $display("--- Halfword arithmetic ---");
    check(39, 32'h001E001E, "ah    r39, r8, r8    (15+15)");
    check(40, 32'h00100010, "ahi   r40, r8, 1     (15+1)");
    check(41, 32'h00000000, "sfh   r41, r8, r8    (15-15)");
    check(42, 32'h00550055, "sfhi  r42, r8, 100   (100-15)");

    $display("--- Halfword logic immediates ---");
    check(43, 32'h00070007, "andhi r43, r8, 0x7");
    check(44, 32'h00FF00FF, "orhi  r44, r8, 0xF0");
    check(45, 32'h00F000F0, "xorhi r45, r8, 0xFF");

    $display("--- Halfword shift / rotate ---");
    check(46, 32'h00F000F0, "shlh  r46, r8, r9    (0x0F << 4)");
    check(47, 32'h00F000F0, "shlhi r47, r8, 4");
    check(48, 32'h00F000F0, "roth  r48, r8, r9");
    check(49, 32'h00F000F0, "rothi r49, r8, 4");

    $display("--- Halfword compare ---");
    check(50, 32'hFFFFFFFF, "ceqh   r50, r8, r8");
    check(51, 32'hFFFFFFFF, "ceqhi  r51, r8, 15");
    check(52, 32'hFFFFFFFF, "cgthi  r52, r8, 5");
    check(53, 32'hFFFFFFFF, "clgth  r53, r8, r9");
    check(54, 32'hFFFFFFFF, "clgthi r54, r8, 5");

    $display("--- Byte compare ---");
    check(55, 32'hFFFFFFFF, "ceqb   r55, r4, r4");
    check(56, 32'hFFFFFF00, "cgtb   r56, r4, r5");
    check(57, 32'hFFFFFF00, "clgtb  r57, r5, r4");

    $display("--- Carry / borrow generate ---");
    check(58, 32'h00000001, "cg    r58, r4, r5");
    check(59, 32'h00000001, "bg    r59, r1, r2");

    $display("--- Multiply-add (RRR) ---");
    check(60, 32'h000000CF, "mpya  r60, r1, r2, r3 (10*20+7)");

    $display("--- Byte arithmetic ---");
    check(61, 32'h0000000A, "absdb r61, r1, r2");
    check(62, 32'h0000000F, "avgb  r62, r1, r2");
    check(63, 32'h0000001E, "sumb  r63, r1, r2");

    $display("--- Form select mask ---");
    check(64, 32'h000000FF, "fsmb  r64, r4");
    check(65, 32'hFFFF0000, "fsmbi r65, 0xC000");

    $display("--- Gather bits ---");
    check(66, 32'h00001111, "gb    r66, r4");

    $display("--- FP arithmetic ---");
    check(67, 32'h40400000, "fa    r67          (1+2 = 3.0)");
    check(68, 32'h3F800000, "fs    r68          (2-1 = 1.0)");
    check(69, 32'h40800000, "fm    r69          (2*2 = 4.0)");
    check(70, 32'h40A00000, "fma   r70          (2*2+1 = 5.0)");
    check(71, 32'h40400000, "fms   r71          (2*2-1 = 3.0)");
    check(72, 32'hC0A00000, "fnms  r72          (per RTL: -5.0)");

    $display("--- FP compare ---");
    check(73, 32'hFFFFFFFF, "fceq  r73");
    check(74, 32'hFFFFFFFF, "fcgt  r74");
    check(75, 32'hFFFFFFFF, "fcmeq r75");
    check(76, 32'hFFFFFFFF, "fcmgt r76");

    $display("--- Branch markers (all should be 0 if branches taken) ---");
    check(91, 32'h00000000, "bra   -- not taken into skipped ai");
    check(92, 32'h00000000, "br    -- not taken into skipped ai");
    check(93, 32'h00000000, "brnz  -- taken (r2=20)");
    check(94, 32'h00000000, "brz   -- taken (r92=0)");
    check(95, 32'h0000CAFE, "brsl  -- target reached");
    check(96, 32'h00000000, "brsl  -- pre-target writes squashed");
    check(97, 32'h00000000, "bi    -- taken via indirect target");
    check(98, 32'h00000000, "loop  -- counter at 0 after 5 iters");
    check(99, 32'h00000005, "loop  -- accumulator after 5 iters");

    $display("--- Permute (quadword) ---");
    check(110, 32'h012ABC00, "shlqby  r110, r83, r84(=1)");
    check(111, 32'h012ABC00, "shlqbyi r111, r83, 1");
    check(112, 32'h012ABC00, "rotqby  r112, r83, r84");
    check(113, 32'h012ABC00, "rotqbyi r113, r83, 1");
    check(114, 32'h0012ABC0, "shlqbi  r114, r83, r85(=4)");
    check(115, 32'h0012ABC0, "shlqbii r115, r83, 4");
    check(116, 32'h0012ABC0, "rotqbi  r116, r83, r85");
    check(117, 32'h0012ABC0, "rotqbii r117, r83, 4");

    $display("--- Load/store round-trips ---");
    check(120, 32'hFFFFDEAD, "lqd  r120, 0(r89)   (round-trip r86)");
    check(121, 32'h00001234, "lqd  r121, 0(r90)   (round-trip r87)");
    check(122, 32'h00005A5A, "lqd  r122, 16(r89)  (round-trip r88)");
    check(123, 32'hFFFFDEAD, "lqa  r123, 0x300    (stqa absolute)");
    check(124, 32'h00001234, "lqd  r124, 0(r90)   (no clobber)");

    $display("");
    $display("================================================");
    $display("  COMBINED TEST  Tests passed: %0d / %0d",
             pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  OVERALL: PASS");
    else
      $display("  OVERALL: FAIL  (%0d failure%s)",
               fail_count, (fail_count == 1) ? "" : "s");
    $display("================================================");
  endtask
  `endif // ENABLE_ARCHIVED_CHECKS  (closes archived check_basic..check_combined block)

  // ----------------------------------------------------
  //  Plain register dump (no checking)
  // ----------------------------------------------------
  task automatic dump_regs(input int unsigned n);
    int unsigned i;
    for (i = 0; i < n; i++) begin
      $display("  r%0d = 0x%08h",
               i, dut.u_rf.regs[i][127:96]);
    end
  endtask

  // ----------------------------------------------------
  //  IMEM load + run
  // ----------------------------------------------------
  string prog_file;
  string check_mode;
  integer prog_fd;

  initial begin
    if (!$value$plusargs("PROG=%s", prog_file))
      $fatal(1, "Missing +PROG=<hex file>");

    if (!$value$plusargs("CHECK=%s", check_mode)) begin
      $fatal(1, "Missing +CHECK=demo|matmul|lanes|none");
    end
    if (!(check_mode == "demo" || check_mode == "matmul" ||
          check_mode == "lanes" || check_mode == "none"))
      $fatal(1, "Unknown check mode: %s", check_mode);
    prog_fd = $fopen(prog_file, "r");
    if (prog_fd == 0) $fatal(1, "Cannot open program: %s", prog_file);
    $fclose(prog_fd);

    $display("[tb] loading %s into IMEM (check mode: %s)",
             prog_file, check_mode);
    $readmemh(prog_file, dut.imem);

    // For matmul: pre-load A and B into LS BEFORE reset deasserts.
    // Per prof spec: no SPU instructions used for matrix init.
    if (check_mode == "matmul") begin
      load_matmul_data();
    end

    rst = 1;
    repeat(3) @(posedge clk);
    @(negedge clk);
    if (check_mode == "lanes") begin
      dut.lstore[0] = {32'd1, 32'd2, 32'd3, 32'd4};
      dut.lstore[1] = {32'd10, 32'd20, 32'd30, 32'd40};
    end
    rst = 0;

    // Run until done or timeout
    fork
      begin
        @(posedge done);
        $display("[tb] STOP detected at cycle %0d, draining pipeline",
                 cycle_count);
        repeat(20) @(posedge clk);
        $display("");
        $display("=== SPU-lite Run Complete ===");
        $display("Cycles  : %0d", cycle_count);
        $display("Final PC: 0x%0h", pc_out);
        $display("");

        case (check_mode)
          "demo":     check_demo();
          "matmul":   check_matmul();
          "lanes": begin
            for (int lane = 0; lane < 4; lane++) begin
              check_ls_word(2, lane, 11 * (lane + 1), "SIMD add/store");
              check_ls_word(3, lane, 11 * (lane + 1) + 1, "load-use/add/store");
            end
          end
          // Archived check tasks (check_all, check_basic, check_branch,
          // check_hazard, check_ls, check_perm, check_combined, check_min,
          // check_min2) remain in this file but are no longer dispatched
          // here. Their corresponding programs are not shipped.
          default: begin
            $display("--- Register dump (r0..r39) ---");
            dump_regs(40);
          end
        endcase
        if (check_mode != "none") begin
          if (fail_count != 0 || pass_count == 0)
            $fatal(1, "Verification failed: %0d passed, %0d failed", pass_count, fail_count);
          $display("REGRESSION PASS: %s (%0d checks)", check_mode, pass_count);
        end
        $finish;
      end
      begin
        #50000;
        $display("[tb] TIMEOUT at %0t", $time);
        $display("Cycles  : %0d", cycle_count);
        $display("Final PC: 0x%0h", pc_out);
        $display("--- Register dump (r0..r15) ---");
        dump_regs(16);
        $fatal(1, "Simulation timeout");
      end
    join_any
  end

  // ----------------------------------------------------
  //  Optional waveform dump
  // ----------------------------------------------------
  initial begin
    if ($test$plusargs("DUMP")) begin
      $dumpfile("spu_lite.vcd");
      $dumpvars(0, spu_tb);
    end
  end

endmodule
