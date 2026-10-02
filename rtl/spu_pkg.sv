`ifndef SPU_PKG_SV
`define SPU_PKG_SV

package spu_pkg;

  // ========================================
  //  Execution Unit IDs
  // ========================================
  typedef enum logic [2:0] {
    UNIT_NOP  = 3'd0,
    UNIT_FX1  = 3'd1,  // Simple Fixed 1  (even, depth 2, latency 3)
    UNIT_FX2  = 3'd2,  // Simple Fixed 2  (even, depth 3, latency 4)
    UNIT_FP   = 3'd3,  // SP FP + IntMul  (even, depth 6|7, latency 7|8)
    UNIT_BYTE = 3'd4,  // Byte            (even, depth 3, latency 4)
    UNIT_PERM = 3'd5,  // Permute         (odd,  depth 3, latency 4)
    UNIT_LS   = 3'd6,  // Load/Store      (odd,  depth 6, latency 7)
    UNIT_BR   = 3'd7   // Branch          (odd,  depth 1, latency 2)
  } unit_id_t;

  // ========================================
  //  Opcodes -- matches ISA table IDs 0-102
  // ========================================
  typedef enum logic [7:0] {
    // -- NOP / Control --
    OP_HW_NOP  = 8'd0,

    // -- Unit 1: Simple Fixed 1  (even, lat 3) --
    OP_A       = 8'd1,    OP_AI      = 8'd2,    OP_ADDX    = 8'd3,
    OP_SF      = 8'd4,    OP_SFI     = 8'd5,    OP_SFX     = 8'd6,
    OP_AH      = 8'd7,    OP_AHI     = 8'd8,    OP_SFH     = 8'd9,
    OP_SFHI    = 8'd10,   OP_CG      = 8'd11,   OP_BG      = 8'd12,
    OP_AND     = 8'd13,   OP_OR      = 8'd14,   OP_XOR     = 8'd15,
    OP_NOR     = 8'd16,   OP_NAND    = 8'd17,   OP_EQV     = 8'd18,
    OP_ANDI    = 8'd19,   OP_ORI     = 8'd20,   OP_XORI    = 8'd21,
    OP_ANDHI   = 8'd22,   OP_ORHI    = 8'd23,   OP_XORHI   = 8'd24,
    OP_CEQ     = 8'd25,   OP_CEQI    = 8'd26,   OP_CGT     = 8'd27,
    OP_CGTI    = 8'd28,   OP_DGT     = 8'd29,   OP_DGTI    = 8'd30,
    OP_CEQH    = 8'd31,   OP_CEQHI   = 8'd32,   OP_CGTHI   = 8'd33,
    OP_CLZ     = 8'd34,   OP_DGTH    = 8'd35,   OP_DGTHI   = 8'd36,
    OP_SELB    = 8'd37,   OP_ILH     = 8'd38,   OP_ILHU    = 8'd39,
    OP_IL      = 8'd40,   OP_ILA     = 8'd41,

    // -- Unit 2: Simple Fixed 2  (even, lat 4) --
    OP_SHL     = 8'd42,   OP_SHLI    = 8'd43,   OP_SHLH    = 8'd44,
    OP_SHLHI   = 8'd45,   OP_SHRA    = 8'd46,   OP_SHRAI   = 8'd47,
    OP_ROT     = 8'd48,   OP_ROTI    = 8'd49,   OP_ROTH    = 8'd50,
    OP_ROTHI   = 8'd51,

    // -- Unit 3: SP Floating-Point  (even, lat 7) --
    OP_FA      = 8'd52,   OP_FS      = 8'd53,   OP_FM      = 8'd54,
    OP_FMA     = 8'd55,   OP_FMS     = 8'd56,   OP_FMS2    = 8'd57,
    OP_FNMS    = 8'd58,   OP_FCEQ    = 8'd59,   OP_FCGT    = 8'd60,
    OP_FCMEQ   = 8'd61,   OP_FCMGT   = 8'd62,

    // -- Unit 3: Integer Multiply  (even, lat 8) --
    OP_MPY     = 8'd63,   OP_MPYU    = 8'd64,   OP_MPYA    = 8'd65,
    OP_MPYI    = 8'd66,

    // -- Unit 4: Byte  (even, lat 4) --
    OP_ABSDB   = 8'd67,   OP_AVGB    = 8'd68,   OP_SUMB    = 8'd69,
    OP_CNTB    = 8'd70,   OP_FSMB    = 8'd71,   OP_FSMBI   = 8'd72,
    OP_CEQB    = 8'd73,   OP_CGTB    = 8'd74,   OP_DGTB    = 8'd75,
    OP_GB      = 8'd76,

    // -- Unit 5: Permute  (odd, lat 4) --
    OP_SHLQBI  = 8'd77,   OP_SHLQBII = 8'd78,   OP_SHLQBY  = 8'd79,
    OP_SHLQBYI = 8'd80,   OP_ROTQBY  = 8'd81,   OP_ROTQBYI = 8'd82,
    OP_ROTQBI  = 8'd83,   OP_ROTQBII = 8'd84,

    // -- Unit 6: Load/Store  (odd, lat 7) --
    OP_LQD     = 8'd85,   OP_LQA     = 8'd86,
    OP_STQD    = 8'd87,   OP_STQA    = 8'd88,

    // -- Unit 7: Branch  (odd, lat 2) --
    OP_BR      = 8'd89,   OP_BRA     = 8'd90,
    OP_BRSL    = 8'd91,   OP_BRASL   = 8'd92,
    OP_BRZ     = 8'd93,   OP_BRNZ    = 8'd94,
    OP_BRHZ    = 8'd95,   OP_BRHNZ   = 8'd96,
    OP_BI      = 8'd97,   OP_BIZ     = 8'd98,   OP_BINZ    = 8'd99,

    // -- Control --
    OP_STOP    = 8'd100,
    OP_LNOP    = 8'd101,  // odd-pipe NOP
    OP_NOP     = 8'd102   // even-pipe NOP
  } opcode_t;

  // ========================================
  //  Decoded Instruction
  // ========================================
  typedef struct packed {
    logic        valid;
    opcode_t     opcode;
    logic [6:0]  rt;          // destination
    logic [6:0]  ra;          // source A
    logic [6:0]  rb;          // source B
    logic [6:0]  rc;          // source C  (RRR format: selb, fma, ...)
    logic [17:0] imm;         // immediate (up to 18 bits)
    logic        use_ra;
    logic        use_rb;
    logic        use_rc;
    unit_id_t    unit_id;
    logic        pipe_even;   // 1 = even pipe, 0 = odd pipe
    logic [3:0]  latency;
    logic        reg_wr;      // writes RT
    logic        is_store;    // store -- reads RT as data source
    logic        is_branch;
    logic        from_slot1;  // 1 if this instr came from bundle slot 1
                              // (higher PC).  Carried into result_pkt at
                              // execute -> writeback for WAW tiebreak.
  } decoded_instr_t;

  // ========================================
  //  Result Packet (rides through pipe)
  // ========================================
  typedef struct packed {
    logic         valid;
    unit_id_t     unit_id;
    logic [127:0] result;
    logic [6:0]   reg_dest;
    logic         reg_wr;
    logic [3:0]   cycles_to_ready;  // 0 -> result forwardable
    logic         from_slot1;       // 1 if dispatched from bundle slot 1
                                    // (= higher PC).  Used as the WAW
                                    // tie-breaker at writeback when both
                                    // pipes target the same register.
  } result_pkt_t;

  // ========================================
  //  Branch Info (from odd pipe to fetch)
  // ========================================
  typedef struct packed {
    logic        valid;
    logic        taken;
    logic [10:0] target;      // byte address into IMEM
  } branch_info_t;

  // ========================================
  //  Constants
  // ========================================
  parameter int PIPE_STAGES = 8;       // execution + fwd + writeback (stages 4-11)
  parameter int NUM_REGS    = 128;
  parameter int REG_WIDTH   = 128;
  parameter int IMEM_DEPTH  = 512;     // 2 KB / 4 B = 512 words
  parameter int LS_DEPTH    = 2048;    // 32 KB / 16 B = 2048 quadwords

  // ========================================
  //  Null constants
  // ========================================
  parameter result_pkt_t NULL_PKT = '{
    valid:           1'b0,
    unit_id:         UNIT_NOP,
    result:          128'd0,
    reg_dest:        7'd0,
    reg_wr:          1'b0,
    cycles_to_ready: 4'd0,
    from_slot1:      1'b0
  };

  parameter decoded_instr_t NULL_INSTR = '{
    valid:     1'b0,
    opcode:    OP_HW_NOP,
    rt: 7'd0, ra: 7'd0, rb: 7'd0, rc: 7'd0,
    imm:       18'd0,
    use_ra:    1'b0,
    use_rb:    1'b0,
    use_rc:    1'b0,
    unit_id:   UNIT_NOP,
    pipe_even: 1'b1,
    latency:   4'd0,
    reg_wr:    1'b0,
    is_store:  1'b0,
    is_branch: 1'b0,
    from_slot1: 1'b0
  };

  // ========================================
  //  Helper functions
  // ========================================

  // Pipeline depth (number of execution stages) -- determines cycles_to_ready
  function automatic logic [3:0] get_pipe_depth(unit_id_t uid, opcode_t op);
    case (uid)
      UNIT_FX1:  return 4'd2;
      UNIT_FX2:  return 4'd3;
      UNIT_FP:   return (op inside {OP_MPY, OP_MPYU, OP_MPYA, OP_MPYI}) ? 4'd7 : 4'd6;
      UNIT_BYTE: return 4'd3;
      UNIT_PERM: return 4'd3;
      UNIT_LS:   return 4'd6;
      UNIT_BR:   return 4'd1;
      default:   return 4'd1;
    endcase
  endfunction

  function automatic logic is_even_pipe(unit_id_t uid);
    return (uid inside {UNIT_NOP, UNIT_FX1, UNIT_FX2, UNIT_FP, UNIT_BYTE});
  endfunction

  // ========================================
  //  Word / halfword / byte slice helpers
  //  SPU is big-endian:  word 0 = bits [127:96]
  // ========================================
  function automatic logic [31:0] get_word(logic [127:0] qw, int idx);
    return qw[127 - 32*idx -: 32];
  endfunction

  function automatic logic [127:0] set_word(logic [127:0] qw, int idx, logic [31:0] val);
    logic [127:0] out;
    out = qw;
    out[127 - 32*idx -: 32] = val;
    return out;
  endfunction

  function automatic logic [15:0] get_half(logic [127:0] qw, int idx);
    return qw[127 - 16*idx -: 16];
  endfunction

  function automatic logic [127:0] set_half(logic [127:0] qw, int idx, logic [15:0] val);
    logic [127:0] out;
    out = qw;
    out[127 - 16*idx -: 16] = val;
    return out;
  endfunction

  function automatic logic [7:0] get_byte(logic [127:0] qw, int idx);
    return qw[127 - 8*idx -: 8];
  endfunction

  function automatic logic [127:0] set_byte(logic [127:0] qw, int idx, logic [7:0] val);
    logic [127:0] out;
    out = qw;
    out[127 - 8*idx -: 8] = val;
    return out;
  endfunction

endpackage

`endif
