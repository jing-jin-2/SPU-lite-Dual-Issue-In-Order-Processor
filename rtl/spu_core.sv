// ========================================================================
//  SPU-lite Dual-Pipe Processing Core
//  11-stage pipeline:  Fetch -> Decode -> RF/FWD -> [8 exec/fwd/wb stages]
//  Even pipe: Simple Fixed 1 & 2, SP FP, Int Mul, Byte
//  Odd pipe:  Permute, Load/Store, Branch
// ========================================================================
module spu_core
  import spu_pkg::*;
(
  input  logic         clk,
  input  logic         rst,
  output logic         done,
  output logic [10:0]  pc_out,
  output logic [63:0]  cycle_count
);

  // ========================================
  //  Memories
  // ========================================
  logic [31:0]  imem  [0:IMEM_DEPTH-1];   // 2 KB instruction memory
  logic [127:0] lstore [0:LS_DEPTH-1];    // 32 KB local store (quadwords)

  // ========================================
  //  Program Counter
  // ========================================
  logic [10:0] pc, pc_next;
  assign pc_out = pc;

  // ========================================
  //  Pipeline registers
  // ========================================

  // -- Stage 1 -> 2  (IF/ID latch) --
  logic [31:0]  if_raw_even, if_raw_odd;
  logic [10:0]  if_pc;
  logic         if_valid;

  // -- Stage 2 -> 3  (ID/EX latch) --
  decoded_instr_t id_even, id_odd;
  logic [10:0]    id_pc;        // bundle PC (used for fall-through / BTB)
  logic [10:0]    id_pc_odd;    // actual instr PC of the odd-pipe instr

  // -- Stage 3 outputs (operands after RF read + forwarding) --
  decoded_instr_t ex_even, ex_odd;
  logic [127:0]   ex_opA_even, ex_opB_even, ex_opC_even;
  logic [127:0]   ex_opA_odd,  ex_opB_odd,  ex_opC_odd;
  logic [10:0]    ex_pc;        // bundle PC
  logic [10:0]    ex_pc_odd;    // actual instr PC of the odd-pipe instr

  // -- Dual-issue dispatch state --
  // pending_slot1 = 1 when slot0 was dispatched alone last cycle (structural
  //                 hazard) and slot1 still needs to issue this cycle.
  logic           pending_slot1;

  // ========================================
  //  Pipe shift registers  (stages 4-11, index 0 = stage 4)
  // ========================================
  result_pkt_t even_pipe [0:PIPE_STAGES-1];
  result_pkt_t odd_pipe  [0:PIPE_STAGES-1];

  // ========================================
  //  Control signals
  // ========================================
  logic stall;             // hold stages 1-2, inject bubbles into stage 3
  logic flush;             // squash stages 1-2 on misprediction
  logic branch_taken;
  logic [10:0] branch_target;
  logic        mispredicted;       // branch prediction was wrong
  logic [10:0] correct_target;     // actual PC after branch resolves
  logic        stopped;

  // ========================================
  //  Dynamic Branch Predictor
  //  16-entry direct-mapped BTB + 16-entry 2-bit BHT
  //  Index = pc[6:3]  (pairs are 8-byte aligned, so pc[2:0]=0)
  //  Tag   = pc[10:7] (covers full 2 KB IMEM without aliasing)
  // ========================================
  parameter int BTB_ENTRIES = 16;

  logic [10:0] btb_target_mem [0:BTB_ENTRIES-1]; // stored jump target
  logic [3:0]  btb_tag_mem    [0:BTB_ENTRIES-1]; // tag for valid check
  logic        btb_valid_mem  [0:BTB_ENTRIES-1]; // entry is populated

  // 2-bit saturating counter: 11=strongly-taken, 10=weakly-taken,
  //                           01=weakly-NT,      00=strongly-NT
  logic [1:0]  bht [0:BTB_ENTRIES-1];

  // Prediction outputs (combinational, based on current pc)
  logic        pred_taken;
  logic [10:0] pred_target;
  logic        btb_hit;

  // Prediction tracking -- flows through stages 1->2->3 with the instruction
  logic        if_pred_taken;  logic [10:0] if_pred_target;   // stage 1 latch
  logic        id_pred_taken;  logic [10:0] id_pred_target;   // stage 2 latch
  logic        ex_pred_taken;  logic [10:0] ex_pred_target;   // stage 3 latch

  // ========================================
  //  Register File instance
  // ========================================
  logic [6:0]   rf_rd_a0, rf_rd_b0, rf_rd_c0;
  logic [6:0]   rf_rd_a1, rf_rd_b1, rf_rd_c1;
  logic [127:0] rf_q_a0,  rf_q_b0,  rf_q_c0;
  logic [127:0] rf_q_a1,  rf_q_b1,  rf_q_c1;
  logic         rf_wr_en0, rf_wr_en1;
  logic [6:0]   rf_wr_addr0, rf_wr_addr1;
  logic [127:0] rf_wr_data0, rf_wr_data1;

  regfile u_rf (
    .clk(clk), .rst(rst),
    .rd_addr_a0(rf_rd_a0), .rd_addr_b0(rf_rd_b0), .rd_addr_c0(rf_rd_c0),
    .rd_data_a0(rf_q_a0),  .rd_data_b0(rf_q_b0),  .rd_data_c0(rf_q_c0),
    .rd_addr_a1(rf_rd_a1), .rd_addr_b1(rf_rd_b1), .rd_addr_c1(rf_rd_c1),
    .rd_data_a1(rf_q_a1),  .rd_data_b1(rf_q_b1),  .rd_data_c1(rf_q_c1),
    .wr_en0(rf_wr_en0), .wr_addr0(rf_wr_addr0), .wr_data0(rf_wr_data0),
    .wr_en1(rf_wr_en1), .wr_addr1(rf_wr_addr1), .wr_data1(rf_wr_data1),
    .load_en(1'b0), .load_addr(7'd0), .load_data(128'd0)
  );

  // ====================================================================
  //  STAGE 2: DECODE  (combinational: raw 32-bit word -> decoded_instr_t)
  //
  //  Decoder follows the Cell SPU ISA v1.2 encoding exactly.  Six formats:
  //    RR    op[31:21] | rb[20:14] | ra[13:7] | rt[6:0]
  //    RRR   op[31:28] | rt[27:21] | rb[20:14] | ra[13:7] | rc[6:0]
  //    RI7   op[31:21] | i7[20:14] | ra[13:7] | rt[6:0]
  //    RI8   op[31:22] | i8[21:14] | ra[13:7] | rt[6:0]
  //    RI10  op[31:24] | i10[23:14] | ra[13:7] | rt[6:0]
  //    RI16  op[31:23] | i16[22:7]  | rt[6:0]
  //    RI18  op[31:25] | i18[24:7]  | rt[6:0]
  //
  //  Strategy: a casez on raw[31:21] (11 bits) identifies opcode + format
  //  using don't-care patterns for shorter opcodes.  A second case extracts
  //  fields per format.  The classification case below sets unit/pipe/latency.
  //  The 18-bit imm field always holds the immediate value in its low bits;
  //  the execution stage handles sign extension as needed.
  // ====================================================================
  function automatic decoded_instr_t decode_instr(input logic [31:0] raw, input logic [10:0] instr_pc);
    decoded_instr_t d;
    opcode_t        op;
    logic [3:0]     fmt;  // 1=RR, 2=RRR, 3=RI7, 4=RI8, 5=RI10, 6=RI16, 7=RI18, 8=BR_R, 0=other

    d   = NULL_INSTR;
    op  = OP_HW_NOP;
    fmt = 4'd0;

    // -- Map raw[31:21] -> (op, fmt) using SPU ISA opcode patterns --
    casez (raw[31:21])
      // RRR format (4-bit opcode in [31:28])
      11'b1000???????: begin op = OP_SELB;    fmt = 4'd2; end
      11'b1100???????: begin op = OP_MPYA;    fmt = 4'd2; end
      11'b1101???????: begin op = OP_FNMS;    fmt = 4'd2; end
      11'b1110???????: begin op = OP_FMA;     fmt = 4'd2; end
      11'b1111???????: begin op = OP_FMS2;    fmt = 4'd2; end  // standard fms (RT=RA*RB-RC)
      // 11'b1011 = shufb (PERM unit) -- user enum has no entry, decode as HW_NOP

      // RI18 (7-bit opcode in [31:25])
      11'b0100001????: begin op = OP_ILA;     fmt = 4'd7; end

      // RI16 (9-bit opcode in [31:23])
      11'b001100001??: begin op = OP_LQA;     fmt = 4'd6; end
      11'b001000001??: begin op = OP_STQA;    fmt = 4'd6; end
      11'b010000011??: begin op = OP_ILH;     fmt = 4'd6; end
      11'b010000010??: begin op = OP_ILHU;    fmt = 4'd6; end
      11'b010000001??: begin op = OP_IL;      fmt = 4'd6; end
      11'b001100101??: begin op = OP_FSMBI;   fmt = 4'd6; end
      11'b001100100??: begin op = OP_BR;      fmt = 4'd6; end
      11'b001100000??: begin op = OP_BRA;     fmt = 4'd6; end
      11'b001100110??: begin op = OP_BRSL;    fmt = 4'd6; end
      11'b001100010??: begin op = OP_BRASL;   fmt = 4'd6; end
      11'b001000010??: begin op = OP_BRNZ;    fmt = 4'd6; end
      11'b001000000??: begin op = OP_BRZ;     fmt = 4'd6; end
      11'b001000110??: begin op = OP_BRHNZ;   fmt = 4'd6; end
      11'b001000100??: begin op = OP_BRHZ;    fmt = 4'd6; end

      // RI10 (8-bit opcode in [31:24])
      11'b00110100???: begin op = OP_LQD;     fmt = 4'd5; end
      11'b00100100???: begin op = OP_STQD;    fmt = 4'd5; end
      11'b00011101???: begin op = OP_AHI;     fmt = 4'd5; end
      11'b00011100???: begin op = OP_AI;      fmt = 4'd5; end
      11'b00001101???: begin op = OP_SFHI;    fmt = 4'd5; end
      11'b00001100???: begin op = OP_SFI;     fmt = 4'd5; end
      11'b00010101???: begin op = OP_ANDHI;   fmt = 4'd5; end
      11'b00010100???: begin op = OP_ANDI;    fmt = 4'd5; end
      11'b00000101???: begin op = OP_ORHI;    fmt = 4'd5; end
      11'b00000100???: begin op = OP_ORI;     fmt = 4'd5; end
      11'b01000101???: begin op = OP_XORHI;   fmt = 4'd5; end
      11'b01000100???: begin op = OP_XORI;    fmt = 4'd5; end
      11'b01111101???: begin op = OP_CEQHI;   fmt = 4'd5; end
      11'b01111100???: begin op = OP_CEQI;    fmt = 4'd5; end
      11'b01001101???: begin op = OP_CGTHI;   fmt = 4'd5; end
      11'b01001100???: begin op = OP_CGTI;    fmt = 4'd5; end
      11'b01011101???: begin op = OP_DGTHI;   fmt = 4'd5; end
      11'b01011100???: begin op = OP_DGTI;    fmt = 4'd5; end
      11'b01110100???: begin op = OP_MPYI;    fmt = 4'd5; end

      // RR (3-register, 11-bit opcode)
      11'b00011000000: begin op = OP_A;       fmt = 4'd1; end
      11'b00011001000: begin op = OP_AH;      fmt = 4'd1; end
      11'b00001000000: begin op = OP_SF;      fmt = 4'd1; end
      11'b00001001000: begin op = OP_SFH;     fmt = 4'd1; end
      11'b01101000000: begin op = OP_ADDX;    fmt = 4'd1; end
      11'b01101000001: begin op = OP_SFX;     fmt = 4'd1; end
      11'b00011000010: begin op = OP_CG;      fmt = 4'd1; end
      11'b00001000010: begin op = OP_BG;      fmt = 4'd1; end
      11'b00011000001: begin op = OP_AND;     fmt = 4'd1; end
      11'b00001000001: begin op = OP_OR;      fmt = 4'd1; end
      11'b01001000001: begin op = OP_XOR;     fmt = 4'd1; end
      11'b00001001001: begin op = OP_NOR;     fmt = 4'd1; end
      11'b00011001001: begin op = OP_NAND;    fmt = 4'd1; end
      11'b01001001001: begin op = OP_EQV;     fmt = 4'd1; end
      11'b01111000000: begin op = OP_CEQ;     fmt = 4'd1; end
      11'b01001000000: begin op = OP_CGT;     fmt = 4'd1; end
      11'b01011000000: begin op = OP_DGT;     fmt = 4'd1; end
      11'b01111001000: begin op = OP_CEQH;    fmt = 4'd1; end
      11'b01011001000: begin op = OP_DGTH;    fmt = 4'd1; end
      11'b01010100101: begin op = OP_CLZ;     fmt = 4'd1; end
      11'b01111010000: begin op = OP_CEQB;    fmt = 4'd1; end
      11'b01001010000: begin op = OP_CGTB;    fmt = 4'd1; end
      11'b01011010000: begin op = OP_DGTB;    fmt = 4'd1; end
      11'b01111000010: begin op = OP_FCEQ;    fmt = 4'd1; end
      11'b01011000010: begin op = OP_FCGT;    fmt = 4'd1; end
      11'b01111001010: begin op = OP_FCMEQ;   fmt = 4'd1; end
      11'b01011001010: begin op = OP_FCMGT;   fmt = 4'd1; end
      11'b01011000100: begin op = OP_FA;      fmt = 4'd1; end
      11'b01011000101: begin op = OP_FS;      fmt = 4'd1; end
      11'b01011000110: begin op = OP_FM;      fmt = 4'd1; end
      11'b01111000100: begin op = OP_MPY;     fmt = 4'd1; end
      11'b01111001100: begin op = OP_MPYU;    fmt = 4'd1; end
      11'b01010110100: begin op = OP_CNTB;    fmt = 4'd1; end
      11'b00110110110: begin op = OP_FSMB;    fmt = 4'd1; end
      11'b00110110000: begin op = OP_GB;      fmt = 4'd1; end
      11'b00011010011: begin op = OP_AVGB;    fmt = 4'd1; end
      11'b00001010011: begin op = OP_ABSDB;   fmt = 4'd1; end
      11'b01001010011: begin op = OP_SUMB;    fmt = 4'd1; end

      // FX2 shift/rotate (RR form)
      11'b00001011011: begin op = OP_SHL;     fmt = 4'd1; end
      11'b00001011111: begin op = OP_SHLH;    fmt = 4'd1; end
      11'b00001011010: begin op = OP_SHRA;    fmt = 4'd1; end // rotma alias
      11'b00001011000: begin op = OP_ROT;     fmt = 4'd1; end
      11'b00001011100: begin op = OP_ROTH;    fmt = 4'd1; end

      // FX2 shift/rotate (RI7 form)
      11'b00001111011: begin op = OP_SHLI;    fmt = 4'd3; end
      11'b00001111111: begin op = OP_SHLHI;   fmt = 4'd3; end
      11'b00001111010: begin op = OP_SHRAI;   fmt = 4'd3; end // rotmai alias
      11'b00001111000: begin op = OP_ROTI;    fmt = 4'd3; end
      11'b00001111100: begin op = OP_ROTHI;   fmt = 4'd3; end

      // PERM quadword shift/rotate (RR)
      11'b00111011011: begin op = OP_SHLQBI;  fmt = 4'd1; end
      11'b00111011111: begin op = OP_SHLQBY;  fmt = 4'd1; end
      11'b00111011100: begin op = OP_ROTQBY;  fmt = 4'd1; end
      11'b00111011000: begin op = OP_ROTQBI;  fmt = 4'd1; end

      // PERM quadword shift/rotate (RI7)
      11'b00111111011: begin op = OP_SHLQBII; fmt = 4'd3; end
      11'b00111111111: begin op = OP_SHLQBYI; fmt = 4'd3; end
      11'b00111111100: begin op = OP_ROTQBYI; fmt = 4'd3; end
      11'b00111111000: begin op = OP_ROTQBII; fmt = 4'd3; end

      // Branch indirect (BR_R: identical layout to RR but no RB)
      11'b00110101000: begin op = OP_BI;      fmt = 4'd8; end
      11'b00100101000: begin op = OP_BIZ;     fmt = 4'd8; end
      11'b00100101001: begin op = OP_BINZ;    fmt = 4'd8; end

      // Control / NOP / STOP
      11'b00000000000: begin op = OP_STOP;    fmt = 4'd0; end
      11'b00000000001: begin op = OP_LNOP;    fmt = 4'd0; end
      11'b01000000001: begin op = OP_NOP;     fmt = 4'd0; end

      default:         begin op = OP_HW_NOP;  fmt = 4'd0; end
    endcase

    // -- Extract operand fields per format --
    d.opcode = op;
    case (fmt)
      4'd1: begin // RR
        d.rt  = raw[6:0];
        d.ra  = raw[13:7];
        d.rb  = raw[20:14];
      end
      4'd2: begin // RRR
        d.rc  = raw[6:0];
        d.ra  = raw[13:7];
        d.rb  = raw[20:14];
        d.rt  = raw[27:21];
      end
      4'd3: begin // RI7
        d.rt  = raw[6:0];
        d.ra  = raw[13:7];
        d.imm = {11'd0, raw[20:14]};
      end
      4'd4: begin // RI8
        d.rt  = raw[6:0];
        d.ra  = raw[13:7];
        d.imm = {10'd0, raw[21:14]};
      end
      4'd5: begin // RI10
        d.rt  = raw[6:0];
        d.ra  = raw[13:7];
        d.imm = {8'd0, raw[23:14]};
      end
      4'd6: begin // RI16
        d.rt  = raw[6:0];
        d.imm = {2'd0, raw[22:7]};
      end
      4'd7: begin // RI18
        d.rt  = raw[6:0];
        d.imm = raw[24:7];
      end
      4'd8: begin // BR_R (same field positions as RR for RT/RA)
        d.rt  = raw[6:0];
        d.ra  = raw[13:7];
      end
      default: ; // STOP/NOP/invalid: leave operand fields at NULL_INSTR defaults
    endcase

    // Default control flags (set by classification below)
    d.valid     = 1'b0;
    d.use_ra    = 1'b0;
    d.use_rb    = 1'b0;
    d.use_rc    = 1'b0;
    d.reg_wr    = 1'b0;
    d.is_store  = 1'b0;
    d.is_branch = 1'b0;

    // Classify by opcode -> unit, pipe, latency, operand usage
    case (op)
      // -- Unit 1: Simple Fixed 1 (even, lat 3) --
      OP_A, OP_SF,
      OP_AH, OP_SFH,
      OP_CG, OP_BG,
      OP_AND, OP_OR, OP_XOR, OP_NOR, OP_NAND, OP_EQV,
      OP_CEQ, OP_CGT, OP_DGT,
      OP_CEQH, OP_DGTH: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- ADDX / SFX: extended-precision add/sub -- carry/borrow lives in RT --
      // RC is set to RT so the forwarding network resolves the carry value.
      OP_ADDX, OP_SFX: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.use_rc    = 1'b1;
        d.rc        = d.rt;    // carry/borrow input comes from current value of RT
        d.reg_wr    = 1'b1;
      end

      OP_CLZ: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_AI, OP_SFI, OP_AHI, OP_SFHI,
      OP_ANDI, OP_ORI, OP_XORI,
      OP_ANDHI, OP_ORHI, OP_XORHI,
      OP_CEQI, OP_CGTI, OP_DGTI,
      OP_CEQHI, OP_CGTHI, OP_DGTHI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_SELB: begin // RRR: rt = (ra & ~rc) | (rb & rc)
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.use_rc    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_IL: begin  // Immediate Load Word
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.reg_wr    = 1'b1;
      end

      OP_ILA: begin // Immediate Load Address (18-bit)
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.reg_wr    = 1'b1;
      end

      OP_ILH: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.reg_wr    = 1'b1;
      end

      OP_ILHU: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX1;
        d.pipe_even = 1'b1;
        d.latency   = 4'd3;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 2: Simple Fixed 2 (even, lat 4) --
      OP_SHL, OP_SHLH, OP_SHRA, OP_ROT, OP_ROTH: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX2;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_SHLI, OP_SHLHI, OP_SHRAI, OP_ROTI, OP_ROTHI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FX2;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 3: SP FP (even, lat 7) --
      OP_FA, OP_FS, OP_FM,
      OP_FCEQ, OP_FCGT, OP_FCMEQ, OP_FCMGT: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FP;
        d.pipe_even = 1'b1;
        d.latency   = 4'd7;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_FMA, OP_FMS, OP_FMS2, OP_FNMS: begin // RRR format
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FP;
        d.pipe_even = 1'b1;
        d.latency   = 4'd7;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.use_rc    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 3: Integer Multiply (even, lat 8) --
      OP_MPY, OP_MPYU: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FP;
        d.pipe_even = 1'b1;
        d.latency   = 4'd8;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_MPYA: begin // RRR
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FP;
        d.pipe_even = 1'b1;
        d.latency   = 4'd8;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.use_rc    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_MPYI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_FP;
        d.pipe_even = 1'b1;
        d.latency   = 4'd8;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 4: Byte (even, lat 4) --
      OP_ABSDB, OP_AVGB, OP_CEQB, OP_CGTB, OP_DGTB: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BYTE;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_SUMB: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BYTE;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_CNTB, OP_FSMB: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BYTE;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_FSMBI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BYTE;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.reg_wr    = 1'b1;
      end

      OP_GB: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BYTE;
        d.pipe_even = 1'b1;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 5: Permute (odd, lat 4) --
      OP_SHLQBI, OP_ROTQBY, OP_ROTQBI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_PERM;
        d.pipe_even = 1'b0;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_SHLQBII, OP_SHLQBYI, OP_ROTQBYI, OP_ROTQBII: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_PERM;
        d.pipe_even = 1'b0;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_SHLQBY: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_PERM;
        d.pipe_even = 1'b0;
        d.latency   = 4'd4;
        d.use_ra    = 1'b1;
        d.use_rb    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      // -- Unit 6: Load/Store (odd, lat 7) --
      OP_LQD: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_LS;
        d.pipe_even = 1'b0;
        d.latency   = 4'd7;
        d.use_ra    = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_LQA: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_LS;
        d.pipe_even = 1'b0;
        d.latency   = 4'd7;
        d.reg_wr    = 1'b1;
      end

      OP_STQD: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_LS;
        d.pipe_even = 1'b0;
        d.latency   = 4'd7;
        d.use_ra    = 1'b1;
        d.is_store  = 1'b1;
        // RT is read as data source.  Route it through the RB read port so
        // the forward + ex_opB_odd latching path delivers the data.
        d.rb        = d.rt;
        d.use_rb    = 1'b1;
      end

      OP_STQA: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_LS;
        d.pipe_even = 1'b0;
        d.latency   = 4'd7;
        d.is_store  = 1'b1;
        // RT data routed via RB (see OP_STQD).
        d.rb        = d.rt;
        d.use_rb    = 1'b1;
      end

      // -- Unit 7: Branch (odd, lat 2) --
      OP_BR: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
      end

      OP_BRA: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
      end

      OP_BRSL: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
        d.reg_wr    = 1'b1;  // sets link register
      end

      OP_BRASL: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
        d.reg_wr    = 1'b1;
      end

      OP_BRZ, OP_BRNZ, OP_BRHZ, OP_BRHNZ: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
        d.use_ra    = 1'b1;
        // SPU encodes the condition register in the RT field of RI16 for
        // these conditional branches.  The RI16 decoder only sets d.rt,
        // so copy it to d.ra so the RF read mux reads the right register.
        d.ra        = d.rt;
      end

      OP_BI: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
        d.use_ra    = 1'b1;  // target address in RA
      end

      OP_BIZ, OP_BINZ: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_BR;
        d.pipe_even = 1'b0;
        d.latency   = 4'd2;
        d.is_branch = 1'b1;
        // SPU `biz ra, rb` syntax (this codebase): ra (1st operand) is the
        // TARGET, rb (2nd operand) is the CONDITION.  asm.py encodes the
        // 1st operand into the RT field and the 2nd into the RA field, so:
        //   d.ra = condition (read directly via the RA port)
        //   d.rt = target    (route through the RB port to get opB)
        d.use_ra    = 1'b1;       // condition in d.ra
        d.rb        = d.rt;
        d.use_rb    = 1'b1;       // target via d.rb (= d.rt)
      end

      // -- Control --
      OP_STOP: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_NOP;
        d.pipe_even = 1'b1;
      end

      OP_NOP: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_NOP;
        d.pipe_even = 1'b1;
      end

      OP_LNOP: begin
        d.valid     = 1'b1;
        d.unit_id   = UNIT_NOP;
        d.pipe_even = 1'b0;
      end

      default: begin
        d.valid = 1'b0;
      end
    endcase

    return d;
  endfunction


  // ====================================================================
  //  FORWARDING -- scan both pipes, return newest ready value
  //  pipe[0] is youngest (stage 4), pipe[7] is oldest (stage 11)
  // ====================================================================
  function automatic logic [127:0] forward(
    input logic [6:0]   reg_addr,
    input logic [127:0] rf_val,           // baseline from register file
    input result_pkt_t  ep [0:PIPE_STAGES-1],  // even pipe
    input result_pkt_t  op_arr [0:PIPE_STAGES-1]   // odd pipe
  );
    // Scan from youngest (index 0) to oldest (index 7)
    // Return the first (youngest) ready match
    for (int i = 0; i < PIPE_STAGES; i++) begin
      if (ep[i].valid && ep[i].reg_wr &&
          ep[i].reg_dest == reg_addr && ep[i].cycles_to_ready == 0)
        return ep[i].result;
      if (op_arr[i].valid && op_arr[i].reg_wr &&
          op_arr[i].reg_dest == reg_addr && op_arr[i].cycles_to_ready == 0)
        return op_arr[i].result;
    end
    return rf_val;
  endfunction


  // ====================================================================
  //  HAZARD DETECTION -- check if decoded instruction has RAW hazard
  //  Returns 1 if we must stall.
  //  Stall when the youngest writer to a needed source is NOT yet ready
  //  (won't be ready next cycle when the instruction reaches stage 3).
  // ====================================================================
  function automatic logic check_hazard_src(
    input logic        use_src,
    input logic [6:0]  src_addr,
    input result_pkt_t ep [0:PIPE_STAGES-1],
    input result_pkt_t op_arr [0:PIPE_STAGES-1],
    input decoded_instr_t stg3_even,  // instruction currently at stage 3
    input decoded_instr_t stg3_odd
  );
    // Check stage-3 instructions first (they are youngest -- about to enter pipe[0]).
    // Always stall when stg3 holds a writer to this source: forward() does not
    // see stage 3, so the dependent would latch rf_val before the producer
    // reaches pipe[0].  After one stall cycle the producer is at pipe[0] and
    // the pipe-slot loop below takes over.
    if (stg3_even.valid && stg3_even.reg_wr && stg3_even.rt == src_addr)
      return 1'b1;
    if (stg3_odd.valid && stg3_odd.reg_wr && stg3_odd.rt == src_addr)
      return 1'b1;

    // Check pipe slots -- youngest first.
    // Stall while cycles_to_ready > 0: the forward mux only forwards when
    // c2r == 0, so we must hold the dependent instruction at id until the
    // producer has reached the forwardable stage.
    for (int i = 0; i < PIPE_STAGES; i++) begin
      if (ep[i].valid && ep[i].reg_wr && ep[i].reg_dest == src_addr) begin
        if (ep[i].cycles_to_ready > 4'd0) return 1'b1;
        else                              return 1'b0;  // ready (forwardable)
      end
      if (op_arr[i].valid && op_arr[i].reg_wr && op_arr[i].reg_dest == src_addr) begin
        if (op_arr[i].cycles_to_ready > 4'd0) return 1'b1;
        else                                  return 1'b0;
      end
    end

    return 1'b0;  // no match -- no hazard
  endfunction

  function automatic logic detect_stall(
    input decoded_instr_t d_even,
    input decoded_instr_t d_odd,
    input result_pkt_t    ep [0:PIPE_STAGES-1],
    input result_pkt_t    op_arr [0:PIPE_STAGES-1],
    input decoded_instr_t stg3_even,
    input decoded_instr_t stg3_odd
  );
    logic haz;
    haz = 1'b0;

    // Check even instruction sources
    if (d_even.valid) begin
      if (d_even.use_ra) haz |= check_hazard_src(1'b1, d_even.ra, ep, op_arr, stg3_even, stg3_odd);
      if (d_even.use_rb) haz |= check_hazard_src(1'b1, d_even.rb, ep, op_arr, stg3_even, stg3_odd);
      if (d_even.use_rc) haz |= check_hazard_src(1'b1, d_even.rc, ep, op_arr, stg3_even, stg3_odd);
      // Store reads RT as data
      if (d_even.is_store) haz |= check_hazard_src(1'b1, d_even.rt, ep, op_arr, stg3_even, stg3_odd);
    end

    // Check odd instruction sources
    if (d_odd.valid) begin
      if (d_odd.use_ra) haz |= check_hazard_src(1'b1, d_odd.ra, ep, op_arr, stg3_even, stg3_odd);
      if (d_odd.use_rb) haz |= check_hazard_src(1'b1, d_odd.rb, ep, op_arr, stg3_even, stg3_odd);
      if (d_odd.use_rc) haz |= check_hazard_src(1'b1, d_odd.rc, ep, op_arr, stg3_even, stg3_odd);
      if (d_odd.is_store) haz |= check_hazard_src(1'b1, d_odd.rt, ep, op_arr, stg3_even, stg3_odd);
    end

    return haz;
  endfunction


  // ====================================================================
  //  EXECUTION -- compute 128-bit result from decoded instruction + operands
  //  This runs at stage 3->4 boundary (combinational, result placed in pipe[0])
  // ====================================================================

  // -- Even Pipe Execution --
  function automatic logic [127:0] execute_even(
    input decoded_instr_t instr,
    input logic [127:0]   opA, opB, opC
  );
    logic [127:0] res;
    logic [31:0]  wA, wB, wR;
    logic [15:0]  hA, hB, hR;
    logic [7:0]   bA, bB, bR;
    logic signed [31:0] sA, sB;
    res = 128'd0;

    case (instr.opcode)
      // -- Simple Fixed 1: word arithmetic --
      OP_A: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          wB = get_word(opB, i);
          res = set_word(res, i, wA + wB);
        end
      end

      OP_AI: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          res = set_word(res, i, wA + {{22{instr.imm[9]}}, instr.imm[9:0]});
        end
      end

      OP_SF: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          wB = get_word(opB, i);
          res = set_word(res, i, wB - wA);  // RT = RB - RA (subtract from)
        end
      end

      OP_SFI: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          res = set_word(res, i, {{22{instr.imm[9]}}, instr.imm[9:0]} - wA);
        end
      end

      OP_AH: begin
        for (int i = 0; i < 8; i++) begin
          hA = get_half(opA, i);
          hB = get_half(opB, i);
          res = set_half(res, i, hA + hB);
        end
      end

      OP_AHI: begin
        for (int i = 0; i < 8; i++) begin
          hA = get_half(opA, i);
          res = set_half(res, i, hA + {{6{instr.imm[9]}}, instr.imm[9:0]});
        end
      end

      OP_SFH: begin
        for (int i = 0; i < 8; i++) begin
          hA = get_half(opA, i);
          hB = get_half(opB, i);
          res = set_half(res, i, hB - hA);
        end
      end

      OP_SFHI: begin
        for (int i = 0; i < 8; i++) begin
          hA = get_half(opA, i);
          res = set_half(res, i, {{6{instr.imm[9]}}, instr.imm[9:0]} - hA);
        end
      end

      // -- Carry / Borrow --
      OP_CG: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          wB = get_word(opB, i);
          res = set_word(res, i, ({1'b0, wA} + {1'b0, wB} > 33'hFFFFFFFF) ? 32'd1 : 32'd0);
        end
      end

      OP_BG: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          wB = get_word(opB, i);
          res = set_word(res, i, (wA > wB) ? 32'd0 : 32'd1);  // borrow from RB-RA
        end
      end

      // -- Extended-precision arithmetic --
      // ADDX: RT = RA + RB + cin,  where cin  = bit[0] of current RT (from CG)
      //        carry-out written back into bit[0] for further chaining
      // ADDX: RT = RA + RB + cin
      //   cin  = bit 31 in SPU notation = LSB of each RT word = wR[0] in SV
      //   Result is the plain 32-bit sum; carry-out is silently discarded
      //   (spec: "The 32-bit result is placed in RT. Bits 0-30 of RT input reserved")
      OP_ADDX: begin
        for (int i = 0; i < 4; i++) begin
          logic [32:0] ext;
          wA  = get_word(opA, i);
          wB  = get_word(opB, i);
          wR  = get_word(opC, i);   // opC = current RT (carry from CG lives in bit[0])
          ext = {1'b0, wA} + {1'b0, wB} + {32'b0, wR[0]};
          res = set_word(res, i, ext[31:0]);  // full 32-bit sum; cout dropped
        end
      end

      // SFX: RT = RB - RA + bin
      //   bin  = bit 31 SPU = LSB of each RT word = wR[0] in SV (from BG: 1=no-borrow)
      //   Result is the plain 32-bit difference; borrow-out is silently discarded
      OP_SFX: begin
        for (int i = 0; i < 4; i++) begin
          logic [32:0] ext;
          wA  = get_word(opA, i);
          wB  = get_word(opB, i);
          wR  = get_word(opC, i);   // opC = current RT (borrow from BG in bit[0])
          ext = {1'b0, wB} + {1'b0, ~wA} + {32'b0, wR[0]};
          res = set_word(res, i, ext[31:0]);  // full 32-bit diff; bout dropped
        end
      end

      // -- Logical --
      OP_AND:  res = opA & opB;
      OP_OR:   res = opA | opB;
      OP_XOR:  res = opA ^ opB;
      OP_NOR:  res = ~(opA | opB);
      OP_NAND: res = ~(opA & opB);
      OP_EQV:  res = ~(opA ^ opB);

      OP_ANDI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, get_word(opA, i) & {{22{1'b0}}, instr.imm[9:0]});
      end
      OP_ORI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, get_word(opA, i) | {{22{1'b0}}, instr.imm[9:0]});
      end
      OP_XORI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, get_word(opA, i) ^ {{22{1'b0}}, instr.imm[9:0]});
      end

      OP_ANDHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i, get_half(opA, i) & {{6{1'b0}}, instr.imm[9:0]});
      end
      OP_ORHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i, get_half(opA, i) | {{6{1'b0}}, instr.imm[9:0]});
      end
      OP_XORHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i, get_half(opA, i) ^ {{6{1'b0}}, instr.imm[9:0]});
      end

      // -- Compare --
      OP_CEQ: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i,
            (get_word(opA, i) == get_word(opB, i)) ? 32'hFFFF_FFFF : 32'h0);
      end

      OP_CEQI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i,
            (get_word(opA, i) == {{22{instr.imm[9]}}, instr.imm[9:0]}) ? 32'hFFFF_FFFF : 32'h0);
      end

      OP_CGT: begin
        for (int i = 0; i < 4; i++) begin
          sA = $signed(get_word(opA, i));
          sB = $signed(get_word(opB, i));
          res = set_word(res, i, (sA > sB) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      OP_CGTI: begin
        for (int i = 0; i < 4; i++) begin
          sA = $signed(get_word(opA, i));
          res = set_word(res, i,
            (sA > $signed({{22{instr.imm[9]}}, instr.imm[9:0]})) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      OP_DGT: begin // unsigned compare
        for (int i = 0; i < 4; i++)
          res = set_word(res, i,
            (get_word(opA, i) > get_word(opB, i)) ? 32'hFFFF_FFFF : 32'h0);
      end

      OP_CLZ: begin
        for (int i = 0; i < 4; i++) begin
          wA = get_word(opA, i);
          wR = 32'd32;
          for (int b = 31; b >= 0; b--) begin
            if (wA[b]) begin
              wR = 32'd31 - b;
              break;
            end
          end
          res = set_word(res, i, wR);
        end
      end

      // -- Select Bits --
      OP_SELB: begin
        // RT = (RA & ~RC) | (RB & RC)
        res = (opA & ~opC) | (opB & opC);
      end

      // -- Immediate Loads --
      OP_IL: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, {{16{instr.imm[15]}}, instr.imm[15:0]});
      end

      OP_ILA: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, {14'd0, instr.imm});
      end

      OP_ILH: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i, instr.imm[15:0]);
      end

      OP_ILHU: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, {instr.imm[15:0], 16'd0});
      end

      // -- Simple Fixed 2: Shifts & Rotates --
      OP_SHL: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic [4:0] sa = get_word(opB, i)[4:0];
          res = set_word(res, i, get_word(opA, i) << sa);
        end
      end

      OP_SHLI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, get_word(opA, i) << instr.imm[4:0]);
      end

      OP_SHRA: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic [4:0] sa = get_word(opB, i)[4:0];
          res = set_word(res, i, $signed(get_word(opA, i)) >>> sa);
        end
      end

      OP_SHRAI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i, $signed(get_word(opA, i)) >>> instr.imm[4:0]);
      end

      OP_ROT: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic [4:0] sa = get_word(opB, i)[4:0];
          wA = get_word(opA, i);
          res = set_word(res, i, (wA << sa) | (wA >> (5'd32 - sa)));
        end
      end

      OP_ROTI: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic [4:0] sa = instr.imm[4:0];
          wA = get_word(opA, i);
          res = set_word(res, i, (wA << sa) | (wA >> (5'd32 - sa)));
        end
      end

      // -- FP (SP): basic ops --  (behavioral using shortreal)
      OP_FA: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          res = set_word(res, i, $shortrealtobits(a_f + b_f));
        end
      end

      OP_FS: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          res = set_word(res, i, $shortrealtobits(a_f - b_f));
        end
      end

      OP_FM: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          res = set_word(res, i, $shortrealtobits(a_f * b_f));
        end
      end

      OP_FMA: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          automatic shortreal c_f = $bitstoshortreal(get_word(opC, i));
          res = set_word(res, i, $shortrealtobits(a_f * b_f + c_f));
        end
      end

      OP_FMS, OP_FMS2: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          automatic shortreal c_f = $bitstoshortreal(get_word(opC, i));
          res = set_word(res, i, $shortrealtobits(a_f * b_f - c_f));
        end
      end

      OP_FNMS: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          automatic shortreal c_f = $bitstoshortreal(get_word(opC, i));
          res = set_word(res, i, $shortrealtobits(-(a_f * b_f) - c_f));
        end
      end

      // -- Integer Multiply --
      OP_MPY: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic signed [15:0] a16 = $signed(get_word(opA, i)[15:0]);
          automatic logic signed [15:0] b16 = $signed(get_word(opB, i)[15:0]);
          res = set_word(res, i, $signed(a16) * $signed(b16));
        end
      end

      OP_MPYU: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic [15:0] a16 = get_word(opA, i)[15:0];
          automatic logic [15:0] b16 = get_word(opB, i)[15:0];
          res = set_word(res, i, a16 * b16);
        end
      end

      OP_MPYI: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic signed [15:0] a16 = $signed(get_word(opA, i)[15:0]);
          automatic logic signed [15:0] imm16 = $signed(instr.imm[9:0]);
          res = set_word(res, i, $signed(a16) * $signed(imm16));
        end
      end

      // -- Byte unit --
      OP_ABSDB: begin
        for (int i = 0; i < 16; i++) begin
          bA = get_byte(opA, i);
          bB = get_byte(opB, i);
          res = set_byte(res, i, (bA > bB) ? (bA - bB) : (bB - bA));
        end
      end

      OP_AVGB: begin
        for (int i = 0; i < 16; i++) begin
          bA = get_byte(opA, i);
          bB = get_byte(opB, i);
          res = set_byte(res, i, ({1'b0, bA} + {1'b0, bB} + 9'd1) >> 1);
        end
      end

      OP_CNTB: begin
        for (int i = 0; i < 16; i++) begin
          bA = get_byte(opA, i);
          bR = 0;
          for (int b = 0; b < 8; b++)
            bR = bR + {7'd0, bA[b]};
          res = set_byte(res, i, bR);
        end
      end

      // -- Compare: missing word unsigned immediate --
      OP_DGTI: begin
        for (int i = 0; i < 4; i++)
          res = set_word(res, i,
            (get_word(opA, i) > {{22{1'b0}}, instr.imm[9:0]}) ? 32'hFFFF_FFFF : 32'h0);
      end

      // -- Compare: halfword --
      OP_CEQH: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i,
            (get_half(opA, i) == get_half(opB, i)) ? 16'hFFFF : 16'h0);
      end

      OP_CEQHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i,
            (get_half(opA, i) == {{6{instr.imm[9]}}, instr.imm[9:0]}) ? 16'hFFFF : 16'h0);
      end

      OP_CGTHI: begin
        for (int i = 0; i < 8; i++) begin
          automatic logic signed [15:0] sH = $signed(get_half(opA, i));
          res = set_half(res, i,
            (sH > $signed({{6{instr.imm[9]}}, instr.imm[9:0]})) ? 16'hFFFF : 16'h0);
        end
      end

      OP_DGTH: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i,
            (get_half(opA, i) > get_half(opB, i)) ? 16'hFFFF : 16'h0);
      end

      OP_DGTHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i,
            (get_half(opA, i) > {{6{1'b0}}, instr.imm[9:0]}) ? 16'hFFFF : 16'h0);
      end

      // -- Shifts/rotates: halfword --
      OP_SHLH: begin
        for (int i = 0; i < 8; i++) begin
          automatic logic [4:0] sa = {1'b0, get_half(opB, i)[3:0]};
          res = set_half(res, i, get_half(opA, i) << sa);
        end
      end

      OP_SHLHI: begin
        for (int i = 0; i < 8; i++)
          res = set_half(res, i, get_half(opA, i) << instr.imm[3:0]);
      end

      OP_ROTH: begin
        for (int i = 0; i < 8; i++) begin
          automatic logic [4:0] sa = {1'b0, get_half(opB, i)[3:0]};
          automatic logic [15:0] x  = get_half(opA, i);
          res = set_half(res, i, (x << sa) | (x >> (5'd16 - sa)));
        end
      end

      OP_ROTHI: begin
        for (int i = 0; i < 8; i++) begin
          automatic logic [4:0] sa = {1'b0, instr.imm[3:0]};
          automatic logic [15:0] x  = get_half(opA, i);
          res = set_half(res, i, (x << sa) | (x >> (5'd16 - sa)));
        end
      end

      // -- FP compares --
      OP_FCEQ: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          res = set_word(res, i, (a_f == b_f) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      OP_FCGT: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal(get_word(opA, i));
          automatic shortreal b_f = $bitstoshortreal(get_word(opB, i));
          res = set_word(res, i, (a_f > b_f) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      OP_FCMEQ: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal({1'b0, get_word(opA, i)[30:0]});
          automatic shortreal b_f = $bitstoshortreal({1'b0, get_word(opB, i)[30:0]});
          res = set_word(res, i, (a_f == b_f) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      OP_FCMGT: begin
        for (int i = 0; i < 4; i++) begin
          automatic shortreal a_f = $bitstoshortreal({1'b0, get_word(opA, i)[30:0]});
          automatic shortreal b_f = $bitstoshortreal({1'b0, get_word(opB, i)[30:0]});
          res = set_word(res, i, (a_f > b_f) ? 32'hFFFF_FFFF : 32'h0);
        end
      end

      // -- Integer Multiply: accumulate --
      OP_MPYA: begin
        for (int i = 0; i < 4; i++) begin
          automatic logic signed [15:0] a16 = $signed(get_word(opA, i)[15:0]);
          automatic logic signed [15:0] b16 = $signed(get_word(opB, i)[15:0]);
          automatic logic signed [31:0] prod = $signed(a16) * $signed(b16);
          res = set_word(res, i, prod + $signed(get_word(opC, i)));
        end
      end

      // -- Byte unit: missing ops --
      OP_SUMB: begin
        for (int i = 0; i < 8; i++) begin
          automatic logic [9:0] s =
            {2'd0, get_byte(opA, 2*i)} + {2'd0, get_byte(opA, 2*i+1)} +
            {2'd0, get_byte(opB, 2*i)} + {2'd0, get_byte(opB, 2*i+1)};
          res = set_half(res, i, {6'd0, s});
        end
      end

      OP_FSMB: begin
        for (int i = 0; i < 16; i++)
          res = set_byte(res, i, (get_byte(opA, i) != 8'h0) ? 8'hFF : 8'h00);
      end

      OP_FSMBI: begin
        for (int i = 0; i < 16; i++)
          res = set_byte(res, i, instr.imm[15-i] ? 8'hFF : 8'h00);
      end

      OP_CEQB: begin
        for (int i = 0; i < 16; i++)
          res = set_byte(res, i,
            (get_byte(opA, i) == get_byte(opB, i)) ? 8'hFF : 8'h00);
      end

      OP_CGTB: begin
        for (int i = 0; i < 16; i++) begin
          automatic logic signed [7:0] sba = $signed(get_byte(opA, i));
          automatic logic signed [7:0] sbb = $signed(get_byte(opB, i));
          res = set_byte(res, i, (sba > sbb) ? 8'hFF : 8'h00);
        end
      end

      OP_DGTB: begin
        for (int i = 0; i < 16; i++)
          res = set_byte(res, i,
            (get_byte(opA, i) > get_byte(opB, i)) ? 8'hFF : 8'h00);
      end

      OP_GB: begin
        begin
          logic [15:0] mask;
          for (int i = 0; i < 16; i++)
            mask[15-i] = get_byte(opA, i)[7];
          for (int i = 0; i < 4; i++)
            res = set_word(res, i, {16'd0, mask});
        end
      end

      default: res = 128'd0;
    endcase

    return res;
  endfunction

  // -- Odd Pipe Execution --
  function automatic logic [127:0] execute_odd(
    input decoded_instr_t instr,
    input logic [127:0]   opA, opB, opC,
    input logic [10:0]    instr_pc
  );
    logic [127:0] res;
    res = 128'd0;

    case (instr.opcode)
      // -- Permute: quadword shifts/rotates --
      OP_SHLQBY: begin
        automatic logic [4:0] sa = get_word(opB, 0)[4:0];
        res = opA << (8 * sa);
      end

      OP_SHLQBYI: begin
        automatic logic [4:0] sa = instr.imm[4:0];
        res = opA << (8 * sa);
      end

      OP_SHLQBI: begin
        automatic logic [2:0] sa = get_word(opB, 0)[2:0];
        res = opA << sa;
      end

      OP_SHLQBII: begin
        automatic logic [2:0] sa = instr.imm[2:0];
        res = opA << sa;
      end

      OP_ROTQBY: begin
        automatic logic [3:0] sa = get_word(opB, 0)[3:0];
        automatic int shift = sa * 8;
        res = (opA << shift) | (opA >> (128 - shift));
      end

      OP_ROTQBYI: begin
        automatic logic [3:0] sa = instr.imm[3:0];
        automatic int shift = sa * 8;
        res = (opA << shift) | (opA >> (128 - shift));
      end

      OP_ROTQBI: begin
        automatic logic [2:0] sa = get_word(opB, 0)[2:0];
        res = (opA << sa) | (opA >> (7'd128 - {4'd0, sa}));
      end

      OP_ROTQBII: begin
        automatic logic [2:0] sa = instr.imm[2:0];
        res = (opA << sa) | (opA >> (7'd128 - {4'd0, sa}));
      end

      // -- Branch -- result = link register value (PC+4) if reg_wr --
      OP_BRSL, OP_BRASL: begin
        res = 128'd0;
        res[127:96] = {21'd0, instr_pc + 11'd4};  // link addr in word 0
      end

      default: res = 128'd0;
    endcase

    return res;
  endfunction

  // -- Branch resolution (combinational) --
  // opA = value of d.ra:
  //   * BI: target register
  //   * BR*Z/NZ: condition (RT routed to RA via decode hack)
  //   * BIZ/BINZ: condition (RB per syntax -> encoding RA -> d.ra)
  // opB = value of d.rb (only set for BIZ/BINZ): target (RT routed to RB)
  function automatic branch_info_t resolve_branch(
    input decoded_instr_t instr,
    input logic [127:0]   opA,
    input logic [127:0]   opB,
    input logic [10:0]    instr_pc
  );
    branch_info_t bi;
    bi.valid  = 1'b0;
    bi.taken  = 1'b0;
    bi.target = 11'd0;

    if (!instr.valid || !instr.is_branch) return bi;
    bi.valid = 1'b1;

    case (instr.opcode)
      // PC-relative branches: target = pc + (SignExt(imm[15:0]) << 2),
      // truncated to 11 bits with natural wraparound for backwards
      // branches.  asm.py encodes imm = (target_byte - pc_byte) >> 2,
      // so imm[8:0] is the low 9 bits of the word offset; <<2 gives an
      // 11-bit byte offset that fits our PC width directly.
      OP_BR: begin
        bi.taken  = 1'b1;
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BRA: begin
        bi.taken  = 1'b1;
        bi.target = {instr.imm[8:0], 2'b00};
      end
      OP_BRSL: begin
        bi.taken  = 1'b1;
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BRASL: begin
        bi.taken  = 1'b1;
        bi.target = {instr.imm[8:0], 2'b00};
      end
      OP_BRZ: begin
        bi.taken  = (get_word(opA, 0) == 32'd0);
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BRNZ: begin
        bi.taken  = (get_word(opA, 0) != 32'd0);
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BRHZ: begin
        // SPU spec tests RT bits[16..31] (SPU bit numbering, MSB=0), which
        // is the rightmost (low) halfword of word 0 -- halfword index 1
        // in this codebase (bits [111:96] in SV notation).
        bi.taken  = (get_half(opA, 1) == 16'd0);
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BRHNZ: begin
        bi.taken  = (get_half(opA, 1) != 16'd0);
        bi.target = instr_pc + {instr.imm[8:0], 2'b00};
      end
      OP_BI: begin
        bi.taken  = 1'b1;
        bi.target = get_word(opA, 0)[10:0];
      end
      OP_BIZ: begin
        // Per this codebase's `biz ra, rb` syntax: condition is rb (encoded
        // in the RA field -> opA); target is ra (encoded in the RT field,
        // routed through RB -> opB).
        bi.taken  = (get_word(opA, 0) == 32'd0);   // condition
        bi.target = get_word(opB, 0)[10:0];         // target
      end
      OP_BINZ: begin
        bi.taken  = (get_word(opA, 0) != 32'd0);
        bi.target = get_word(opB, 0)[10:0];
      end
      default: bi.valid = 1'b0;
    endcase

    return bi;
  endfunction

  // Return 1 when instruction d reads src_addr as an input operand.
  // This is used for same-bundle RAW detection before dual issue.
  function automatic logic instr_reads_reg(
    input decoded_instr_t d,
    input logic [6:0]     src_addr
  );
    logic hit;
    hit = 1'b0;

    if (d.valid) begin
      if (d.use_ra && (d.ra == src_addr)) hit = 1'b1;
      if (d.use_rb && (d.rb == src_addr)) hit = 1'b1;
      if (d.use_rc && (d.rc == src_addr)) hit = 1'b1;

      // Defensive check: stores conceptually read RT as data.
      // In decode, stores already route RT through RB, but keeping this here
      // makes same-bundle RAW detection robust if decode changes later.
      if (d.is_store && (d.rt == src_addr)) hit = 1'b1;
    end

    return hit;
  endfunction



  // ====================================================================
  //  Combinational signals
  // ====================================================================
  decoded_instr_t dec_slot0, dec_slot1;       // raw decode of bundle slots
  decoded_instr_t dec_even,  dec_odd;         // routed decode (post-judgment)
  logic [10:0]    dec_pc_odd;                 // actual PC of the odd-pipe instr
  logic           struct_haz;                 // both slots target same pipe
  logic           bundle_raw_haz;             // slot0 writes a reg read by slot1
  logic           bundle_waw_haz;             // both same-bundle slots write same register
  logic           slot0_branch_haz;           // slot0 is a control-flow instruction
  logic           replay_slot1;               // hold/replay slot1 next cycle
  logic           haz_stall;                  // RAW hazard stall
  logic [127:0]   fw_opA_even, fw_opB_even, fw_opC_even;
  logic [127:0]   fw_opA_odd,  fw_opB_odd,  fw_opC_odd;
  result_pkt_t    new_pkt_even, new_pkt_odd;  // new packets entering pipes
  branch_info_t   br_info;
  logic [31:0]    ls_addr;

  // -- Decode + dispatch routing (stage 1->2) --
  // Slot 0 lives at if_pc (low byte addr); slot 1 at if_pc+4.  The bundle's
  // physical position does NOT decide pipe assignment -- the instruction's
  // own pipe_even flag does.  We may have to swap, or stall when both slots
  // want the same pipe.
  always_comb begin
    dec_slot0 = decode_instr(if_raw_even, if_pc);
    dec_slot1 = decode_instr(if_raw_odd,  if_pc + 11'd4);

    dec_even   = NULL_INSTR;
    dec_odd    = NULL_INSTR;
    dec_pc_odd = if_pc;
    struct_haz     = 1'b0;
    replay_slot1   = 1'b0;

    // Same-bundle ordering hazards.  Slot 0 is the older instruction and
    // slot 1 is the younger instruction.  These hazards must be handled in
    // the dispatch stage because normal RAW detection only sees instructions
    // after they have already been separated into pipeline stages.
    bundle_raw_haz = dec_slot0.valid && dec_slot1.valid &&
                     dec_slot0.reg_wr &&
                     instr_reads_reg(dec_slot1, dec_slot0.rt);

    // If both same-bundle instructions write the same architectural register,
    // slot 1 must be the final visible writer.  Serializing avoids ambiguous
    // same-cycle forwarding/writeback priority between the two pipes.
    bundle_waw_haz = dec_slot0.valid && dec_slot1.valid &&
                     dec_slot0.reg_wr && dec_slot1.reg_wr &&
                     (dec_slot0.rt == dec_slot1.rt);

    // If slot 0 is a branch, slot 1 is control-dependent on it.  Do not
    // execute slot 1 in the same cycle as the branch.  If the branch is
    // predicted not-taken, replay slot 1 next cycle; if predicted taken,
    // fetch follows the predicted target and slot 1 is skipped unless a later
    // misprediction redirects back to slot0_pc+4.
    slot0_branch_haz = dec_slot0.valid && dec_slot1.valid && dec_slot0.is_branch;

    if (pending_slot1) begin
      // Slot 0 was already dispatched in the previous cycle.  Issue slot 1
      // alone in its native pipe.  This instruction is slot 1 (higher PC).
      if (dec_slot1.pipe_even) begin
        dec_even            = dec_slot1;
        dec_even.from_slot1 = 1'b1;
      end else begin
        dec_odd             = dec_slot1;
        dec_odd.from_slot1  = 1'b1;
        dec_pc_odd          = if_pc + 11'd4;
      end
    end else if (bundle_raw_haz || bundle_waw_haz || slot0_branch_haz) begin
      // Same-bundle ordering/control hazard.  Issue slot 0 only.
      //
      // RAW/WAW: replay slot 1 next cycle so program order is preserved and
      // the normal detect_stall() logic can wait until slot 0 is forwardable.
      //
      // Branch in slot 0: slot 1 is on the fall-through path.  Replay it only
      // when the branch was predicted not-taken.  If predicted taken, do not
      // hold the fetch latch; fetch should follow the predicted target.
      if (dec_slot0.pipe_even) begin
        dec_even            = dec_slot0;
        dec_even.from_slot1 = 1'b0;
      end else begin
        dec_odd             = dec_slot0;
        dec_odd.from_slot1  = 1'b0;
        dec_pc_odd          = if_pc;
      end
      replay_slot1 = slot0_branch_haz ? !pred_taken : (bundle_raw_haz || bundle_waw_haz);
      struct_haz   = replay_slot1;
    end else if (dec_slot0.valid && dec_slot1.valid &&
                 (dec_slot0.pipe_even == dec_slot1.pipe_even)) begin
      // Both slots want the same pipe -> structural hazard.  Issue slot 0
      // this cycle (slot 0 = lower PC, from_slot1=0); slot 1 issues next
      // cycle when pending_slot1=1 (handled above with from_slot1=1).
      if (dec_slot0.pipe_even) begin
        dec_even            = dec_slot0;
        dec_even.from_slot1 = 1'b0;
      end else begin
        dec_odd             = dec_slot0;
        dec_odd.from_slot1  = 1'b0;
        dec_pc_odd          = if_pc;
      end
      replay_slot1 = 1'b1;
      struct_haz   = 1'b1;
    end else begin
      // Dual-issue: different pipes, both dispatch this cycle.  Set
      // from_slot1 according to which physical slot each came from.
      if (dec_slot0.pipe_even) begin
        dec_even            = dec_slot0;
        dec_even.from_slot1 = 1'b0;       // slot 0 -> even
        dec_odd             = dec_slot1;
        dec_odd.from_slot1  = 1'b1;       // slot 1 -> odd
        dec_pc_odd          = if_pc + 11'd4;
      end else begin
        dec_odd             = dec_slot0;
        dec_odd.from_slot1  = 1'b0;       // slot 0 -> odd
        dec_even            = dec_slot1;
        dec_even.from_slot1 = 1'b1;       // slot 1 -> even
        dec_pc_odd          = if_pc;
      end
    end
  end

  // -- BTB / BHT lookup (combinational, at fetch, based on current pc) --
  always_comb begin
    automatic logic [3:0] idx;
    idx         = pc[6:3];
    btb_hit     = btb_valid_mem[idx] && (btb_tag_mem[idx] == pc[10:7]);
    pred_taken  = btb_hit && bht[idx][1];  // bit[1]=1 means predict taken (10 or 11)
    pred_target = btb_hit ? btb_target_mem[idx] : 11'b0;
  end

  // -- Hazard detection (at stage 2) --
  // RAW hazard ("haz_stall") freezes id+ex+fetch.
  // Structural hazard ("struct_haz") only freezes fetch -- id still latches
  // slot 0 alone, and slot 1 is replayed next cycle from the held if_raw_*.
  always_comb begin
    haz_stall = detect_stall(id_even, id_odd, even_pipe, odd_pipe, ex_even, ex_odd);
    stall     = haz_stall && !flush;
  end

  // -- RF read addresses (from stage 2 decoded instructions) --
  always_comb begin
    rf_rd_a0 = id_even.ra;
    rf_rd_b0 = id_even.rb;
    rf_rd_c0 = id_even.rc;
    rf_rd_a1 = id_odd.ra;
    rf_rd_b1 = id_odd.rb;
    rf_rd_c1 = id_odd.rc;
  end

  // -- Forwarding muxes (stage 3: select RF value or forwarded value) --
  always_comb begin
    fw_opA_even = id_even.use_ra ? forward(id_even.ra, rf_q_a0, even_pipe, odd_pipe) : 128'd0;
    fw_opB_even = id_even.use_rb ? forward(id_even.rb, rf_q_b0, even_pipe, odd_pipe) : 128'd0;
    fw_opC_even = id_even.use_rc ? forward(id_even.rc, rf_q_c0, even_pipe, odd_pipe) : 128'd0;

    fw_opA_odd  = id_odd.use_ra ? forward(id_odd.ra, rf_q_a1, even_pipe, odd_pipe) : 128'd0;
    fw_opB_odd  = id_odd.use_rb ? forward(id_odd.rb, rf_q_b1, even_pipe, odd_pipe) : 128'd0;
    fw_opC_odd  = id_odd.use_rc ? forward(id_odd.rc, rf_q_c1, even_pipe, odd_pipe) : 128'd0;
  end

  // -- Execute even pipe (combinational result) --
  always_comb begin
    new_pkt_even = NULL_PKT;
    if (ex_even.valid && ex_even.pipe_even) begin
      new_pkt_even.valid           = 1'b1;
      new_pkt_even.unit_id         = ex_even.unit_id;
      new_pkt_even.result          = execute_even(ex_even, ex_opA_even, ex_opB_even, ex_opC_even);
      new_pkt_even.reg_dest        = ex_even.rt;
      new_pkt_even.reg_wr          = ex_even.reg_wr;
      new_pkt_even.cycles_to_ready = get_pipe_depth(ex_even.unit_id, ex_even.opcode) - 4'd1;
      new_pkt_even.from_slot1      = ex_even.from_slot1;
    end
  end

  // -- Execute odd pipe (combinational result) --
  always_comb begin
    new_pkt_odd = NULL_PKT;
    if (ex_odd.valid && !ex_odd.pipe_even) begin
      new_pkt_odd.valid           = 1'b1;
      new_pkt_odd.unit_id         = ex_odd.unit_id;
      // The odd-pipe instruction may live in either slot of the bundle,
      // so the dispatch stage tracks its actual PC in ex_pc_odd.  asm.py
      // encodes PC-relative offsets and brsl link addresses relative to
      // the *instruction* PC.
      new_pkt_odd.result          = execute_odd(ex_odd, ex_opA_odd, ex_opB_odd, ex_opC_odd, ex_pc_odd);
      new_pkt_odd.reg_dest        = ex_odd.rt;
      new_pkt_odd.reg_wr          = ex_odd.reg_wr;
      new_pkt_odd.cycles_to_ready = get_pipe_depth(ex_odd.unit_id, ex_odd.opcode) - 4'd1;
      new_pkt_odd.from_slot1      = ex_odd.from_slot1;

      // -- Load/Store: access local store --
      if (ex_odd.unit_id == UNIT_LS) begin
        if (ex_odd.opcode == OP_LQD) begin
          ls_addr = get_word(ex_opA_odd, 0) + {{22{ex_odd.imm[9]}}, ex_odd.imm[9:0], 4'b0000}; // (RA + SignExt(imm)<<4) & ~0xF
          new_pkt_odd.result = lstore[ls_addr[14:4]];
        end else if (ex_odd.opcode == OP_LQA) begin
          ls_addr = {{14{ex_odd.imm[15]}}, ex_odd.imm[15:0], 2'b00};
          new_pkt_odd.result = lstore[ls_addr[14:4]];
        end
      end
    end else begin
      ls_addr = 32'd0;
    end
  end

  // -- Branch resolution (from stage 3 odd instruction) --
  always_comb begin
    // Branches go to the odd pipe but may live in either bundle slot.
    // ex_pc_odd holds the actual instruction PC.  ex_opB_odd carries the
    // BIZ/BINZ condition (RT, routed through the RB port in decode).
    br_info       = resolve_branch(ex_odd, ex_opA_odd, ex_opB_odd, ex_pc_odd);
    branch_taken  = br_info.valid && br_info.taken;
    branch_target = br_info.target;

    // Misprediction: what we predicted at fetch != what actually happened
    //   Case 1: predicted taken  but branch is not taken  (or wrong target)
    //   Case 2: predicted not-taken but branch IS taken
    mispredicted  = ex_odd.valid && ex_odd.is_branch && br_info.valid &&
                    ((br_info.taken != ex_pred_taken) ||
                     (br_info.taken && (br_info.target != ex_pred_target)));

    // Where to redirect on a misprediction
    correct_target = br_info.taken ? br_info.target : (ex_pc_odd + 11'd4);

    // Only flush pipeline on a WRONG prediction -- correct predictions cost 0 cycles
    flush = mispredicted;
  end

  // -- Writeback from pipe[7] --
  // WAW priority: when both pipes simultaneously write the same register
  // (only possible for a dual-issued bundle whose slots both have reg_wr
  // to the same dest), the slot with the higher PC wins (slot 1).  We
  // suppress the loser's wr_en here so the regfile sees a single write.
  always_comb begin
    automatic logic raw_wr_en_e = even_pipe[PIPE_STAGES-1].valid && even_pipe[PIPE_STAGES-1].reg_wr;
    automatic logic raw_wr_en_o = odd_pipe[PIPE_STAGES-1].valid  && odd_pipe[PIPE_STAGES-1].reg_wr;
    automatic logic conflict    = raw_wr_en_e && raw_wr_en_o &&
                                  (even_pipe[PIPE_STAGES-1].reg_dest ==
                                   odd_pipe[PIPE_STAGES-1].reg_dest);
    // On conflict, the entry whose from_slot1=1 wins (= higher PC).
    automatic logic even_loses  = conflict && !even_pipe[PIPE_STAGES-1].from_slot1;
    automatic logic odd_loses   = conflict && !odd_pipe[PIPE_STAGES-1].from_slot1;

    rf_wr_en0   = raw_wr_en_e && !even_loses;
    rf_wr_addr0 = even_pipe[PIPE_STAGES-1].reg_dest;
    rf_wr_data0 = even_pipe[PIPE_STAGES-1].result;

    rf_wr_en1   = raw_wr_en_o && !odd_loses;
    rf_wr_addr1 = odd_pipe[PIPE_STAGES-1].reg_dest;
    rf_wr_data1 = odd_pipe[PIPE_STAGES-1].result;
  end

  // -- PC next --
  // Misprediction must take priority over struct_haz: a flush has to redirect
  // fetch even if the bundle currently in decode would have caused a
  // structural stall (its slots are about to be flushed anyway).
  always_comb begin
    if (stopped)
      pc_next = pc;
    else if (mispredicted)
      pc_next = correct_target;      // redirect to actual outcome (overrides hazards)
    else if (stall || struct_haz)    // RAW or structural hazard -> hold PC
      pc_next = pc;
    else if (pred_taken)
      pc_next = pred_target;         // BTB predicted taken -- follow it
    else
      pc_next = pc + 11'd8;          // sequential (predicted not-taken or no BTB entry)
  end


  // ====================================================================
  //  Sequential logic -- clock edge
  //  Uses plain `always @(posedge clk)` (not `always_ff`) so the testbench
  //  may also write `dut.lstore[]` from its own initial block to pre-load
  //  matrices for the matmul test.  Questa's vopt-7061 forbids multiple
  //  drivers on `always_ff` variables; plain `always` does not.
  // ====================================================================
  always @(posedge clk) begin
    if (rst) begin
      // Reset all pipeline state
      pc           <= 11'd0;
      // Pre-load the first bundle (imem[0..1]) into the IF latch so cycle 0
      // post-reset already has the program's first instruction in flight.
      // Without this, the fetch logic uses pc_next=8 on its first run and
      // skips imem[0..1].  $readmemh in the TB initialises imem before reset
      // deasserts, so this read returns the real program bytes.
      if_raw_even  <= imem[0];
      if_raw_odd   <= imem[1];
      if_pc        <= 11'd0;
      if_valid     <= 1'b0;
      id_even       <= NULL_INSTR;
      id_odd        <= NULL_INSTR;
      id_pc         <= 11'd0;
      id_pc_odd     <= 11'd0;
      ex_even       <= NULL_INSTR;
      ex_odd        <= NULL_INSTR;
      ex_opA_even   <= 128'd0;
      ex_opB_even   <= 128'd0;
      ex_opC_even   <= 128'd0;
      ex_opA_odd    <= 128'd0;
      ex_opB_odd    <= 128'd0;
      ex_opC_odd    <= 128'd0;
      ex_pc         <= 11'd0;
      ex_pc_odd     <= 11'd0;
      pending_slot1 <= 1'b0;
      stopped       <= 1'b0;
      done         <= 1'b0;
      cycle_count  <= 64'd0;

      for (int i = 0; i < PIPE_STAGES; i++) begin
        even_pipe[i] <= NULL_PKT;
        odd_pipe[i]  <= NULL_PKT;
      end

      // Note: lstore is NOT cleared on reset.  Real local store is
      // persistent memory, not flip-flops.  The testbench may pre-load
      // lstore via $readmemh / hierarchical writes before reset deasserts,
      // and we want those values to survive.  lstore is zero-initialised
      // at simulation start by the initial block at the bottom of this file.

      // Reset branch predictor tables
      for (int i = 0; i < BTB_ENTRIES; i++) begin
        btb_valid_mem[i]  <= 1'b0;
        btb_tag_mem[i]    <= 4'b0;
        btb_target_mem[i] <= 11'b0;
        bht[i]            <= 2'b01;  // start weakly not-taken
      end

      // Reset prediction pipeline registers
      if_pred_taken  <= 1'b0;  if_pred_target <= 11'b0;
      id_pred_taken  <= 1'b0;  id_pred_target <= 11'b0;
      ex_pred_taken  <= 1'b0;  ex_pred_target <= 11'b0;

    end else begin
      // -----------------------------------------
      //  Pipe shift: stages 4->5->...->11 (writeback)
      //  Always runs (even after STOP) so in-flight packets drain
      //  to the regfile.  When stopped, new_pkt_* injection at pipe[0]
      //  is gated (see below) so no new work enters the pipe.
      // -----------------------------------------
      // Build the next-state struct explicitly to avoid two-NBA-to-same-target
      // races (struct assign + field assign) that some simulators handle in
      // an order-dependent way.
      for (int i = PIPE_STAGES-1; i >= 1; i--) begin
        automatic result_pkt_t shifted_e, shifted_o;
        shifted_e                 = even_pipe[i-1];
        shifted_e.cycles_to_ready = (even_pipe[i-1].cycles_to_ready > 0) ?
                                     even_pipe[i-1].cycles_to_ready - 4'd1 : 4'd0;
        shifted_o                 = odd_pipe[i-1];
        shifted_o.cycles_to_ready = (odd_pipe[i-1].cycles_to_ready > 0) ?
                                     odd_pipe[i-1].cycles_to_ready - 4'd1 : 4'd0;
        even_pipe[i] <= shifted_e;
        odd_pipe[i]  <= shifted_o;
      end

      // -----------------------------------------
      //  Insert new packets at pipe[0]  (stage 4)
      //  After STOP: inject NULL_PKT so the drain doesn't re-execute the
      //  frozen ex_even/ex_odd state.
      // -----------------------------------------
      even_pipe[0] <= stopped ? NULL_PKT : new_pkt_even;
      odd_pipe[0]  <= stopped ? NULL_PKT : new_pkt_odd;

    if (!stopped) begin
      cycle_count <= cycle_count + 64'd1;

      // -----------------------------------------
      //  Store execution (writes local store)
      // -----------------------------------------
      if (ex_odd.valid && ex_odd.is_store) begin
        // Store data is the RT register, latched into ex_opB_odd at id->ex
        // (RT is routed through the RB read port for stores in decode).
        if (ex_odd.opcode == OP_STQD) begin
          automatic logic [31:0] sa;
          sa = get_word(ex_opA_odd, 0) + {{22{ex_odd.imm[9]}}, ex_odd.imm[9:0], 4'b0000};
          lstore[sa[14:4]] <= ex_opB_odd;
        end else if (ex_odd.opcode == OP_STQA) begin
          automatic logic [31:0] sa;
          sa = {{14{ex_odd.imm[15]}}, ex_odd.imm[15:0], 2'b00};
          lstore[sa[14:4]] <= ex_opB_odd;
        end
      end

      // -----------------------------------------
      //  BTB / BHT update (when branch resolves at stage 3)
      //  Runs every cycle a branch exits execute -- correct or mispredicted
      // -----------------------------------------
      if (ex_odd.valid && ex_odd.is_branch && br_info.valid) begin
        automatic logic [3:0] upd_idx;
        upd_idx = ex_pc_odd[6:3];

        // BHT: shift 2-bit saturating counter toward actual outcome
        if (br_info.taken) begin
          if (bht[upd_idx] != 2'b11) bht[upd_idx] <= bht[upd_idx] + 2'd1;
        end else begin
          if (bht[upd_idx] != 2'b00) bht[upd_idx] <= bht[upd_idx] - 2'd1;
        end

        // BTB: install/refresh entry on taken branches
        if (br_info.taken) begin
          btb_valid_mem[upd_idx]  <= 1'b1;
          btb_tag_mem[upd_idx]    <= ex_pc_odd[10:7];
          btb_target_mem[upd_idx] <= br_info.target;
        end
      end

      // -----------------------------------------
      //  Stage 2 -> 3:  latch operands (RF + forwarded)
      //  On stall: inject bubbles (NULL_INSTR)
      //  On flush: inject bubbles
      // -----------------------------------------
      if (stall) begin
        ex_even        <= NULL_INSTR;
        ex_odd         <= NULL_INSTR;
        ex_opA_even    <= 128'd0;
        ex_opB_even    <= 128'd0;
        ex_opC_even    <= 128'd0;
        ex_opA_odd     <= 128'd0;
        ex_opB_odd     <= 128'd0;
        ex_opC_odd     <= 128'd0;
        ex_pred_taken  <= 1'b0;
        ex_pred_target <= 11'b0;
      end else if (flush) begin
        ex_even        <= NULL_INSTR;
        ex_odd         <= NULL_INSTR;
        ex_opA_even    <= 128'd0;
        ex_opB_even    <= 128'd0;
        ex_opC_even    <= 128'd0;
        ex_opA_odd     <= 128'd0;
        ex_opB_odd     <= 128'd0;
        ex_opC_odd     <= 128'd0;
        ex_pred_taken  <= 1'b0;
        ex_pred_target <= 11'b0;
      end else begin
        ex_even        <= id_even;
        ex_odd         <= id_odd;
        ex_opA_even    <= fw_opA_even;
        ex_opB_even    <= fw_opB_even;
        ex_opC_even    <= fw_opC_even;
        ex_opA_odd     <= fw_opA_odd;
        ex_opB_odd     <= fw_opB_odd;
        ex_opC_odd     <= fw_opC_odd;
        ex_pc          <= id_pc;
        ex_pc_odd      <= id_pc_odd;
        ex_pred_taken  <= id_pred_taken;
        ex_pred_target <= id_pred_target;
      end

      // -----------------------------------------
      //  Stage 1 -> 2:  latch decoded instructions
      //  On stall: hold (don't advance)
      //  On flush: inject bubbles
      // -----------------------------------------
      if (stall) begin
        // RAW hazard -- hold id_*, id_pc*, id_pred_*, pending_slot1 unchanged.
      end else if (flush) begin
        id_even        <= NULL_INSTR;
        id_odd         <= NULL_INSTR;
        id_pred_taken  <= 1'b0;
        id_pred_target <= 11'b0;
        pending_slot1  <= 1'b0;
      end else begin
        // Latch the routed dispatch.  When struct_haz=1, dec_* contains
        // slot 0 only (other pipe NULL); when pending_slot1=1, dec_*
        // contains slot 1 only.  Otherwise both slots dispatch.
        id_even        <= dec_even;
        id_odd         <= dec_odd;
        id_pc          <= if_pc;
        id_pc_odd      <= dec_pc_odd;
        // The prediction for the bundle being latched into id is the
        // *combinational* pred_taken at this cycle -- pred_taken depends on
        // pc, and pc at this cycle points to the bundle currently in
        // if_raw_* (= the bundle moving to id).  The previously-latched
        // if_pred_* is the prediction for the PREVIOUS bundle (one cycle
        // older than what's being decoded), so using it here would
        // mis-associate the prediction with the wrong instruction.
        id_pred_taken  <= pred_taken;
        id_pred_target <= pred_target;

        if (replay_slot1)   pending_slot1 <= 1'b1;  // slot 0 issued; slot 1 next cycle
        else                pending_slot1 <= 1'b0;  // both issued, slot 1 consumed, or predicted-taken branch
      end

      // -----------------------------------------
      //  Fetch -> Stage 1
      //  On stall: hold PC and fetch regs
      //  On flush: fetch from branch target
      // -----------------------------------------
      // Hold fetch on RAW hazard (stall) or structural hazard.  In the
      // struct_haz cycle, slot 0 just dispatched; we keep if_raw_*
      // unchanged so slot 1 is still available next cycle.  A flush
      // (misprediction) overrides struct_haz and forces fetch redirect.
      if (!stall && (flush || !struct_haz)) begin
        pc             <= pc_next;
        if_pc          <= pc_next;
        if_raw_even    <= imem[pc_next[10:2]];       // bundle slot 0 (low addr)
        if_raw_odd     <= imem[pc_next[10:2] + 1];   // bundle slot 1 (high addr)
        if_pred_taken  <= pred_taken;                // capture predictor output
        if_pred_target <= pred_target;
      end

      // -----------------------------------------
      //  Stop detection
      // -----------------------------------------
      if (ex_even.valid && ex_even.opcode == OP_STOP) begin
        stopped <= 1'b1;
        done    <= 1'b1;
      end

    end // !stopped
    end // outer else (post-reset)
  end

  // ====================================================================
  //  IMEM / Local Store initialization  (testbench loads via $readmemh)
  // ====================================================================
  initial begin
    for (int i = 0; i < IMEM_DEPTH; i++)
      imem[i] = 32'd0;
    for (int i = 0; i < LS_DEPTH; i++)
      lstore[i] = 128'd0;
  end

endmodule
