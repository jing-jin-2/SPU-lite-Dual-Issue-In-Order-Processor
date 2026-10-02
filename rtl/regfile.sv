// ====================================================================
//  SPU-lite Register File  --  128 x 128-bit
//  6 read ports (3 per instruction x 2 dual-issue slots)
//  2 write ports (even-pipe writeback + odd-pipe writeback)
//  Synchronous write, combinational read with write-through bypass
// ====================================================================
module regfile
  import spu_pkg::*;
(
  input  logic         clk,
  input  logic         rst,

  // Read ports -- even instruction (slot 0)
  input  logic [6:0]   rd_addr_a0, rd_addr_b0, rd_addr_c0,
  output logic [127:0] rd_data_a0, rd_data_b0, rd_data_c0,

  // Read ports -- odd instruction (slot 1)
  input  logic [6:0]   rd_addr_a1, rd_addr_b1, rd_addr_c1,
  output logic [127:0] rd_data_a1, rd_data_b1, rd_data_c1,

  // Write port 0 -- even pipe writeback
  input  logic         wr_en0,
  input  logic [6:0]   wr_addr0,
  input  logic [127:0] wr_data0,

  // Write port 1 -- odd pipe writeback
  input  logic         wr_en1,
  input  logic [6:0]   wr_addr1,
  input  logic [127:0] wr_data1,

  // Direct load interface (for testbench init via file)
  input  logic         load_en,
  input  logic [6:0]   load_addr,
  input  logic [127:0] load_data
);

  logic [127:0] regs [0:NUM_REGS-1];

  // -- Write-through read: if writing this cycle, bypass the new value --
  function automatic logic [127:0] read_bypass(
    input logic [6:0] addr
  );
    // Even writeback has priority over odd if both write same register
    if (wr_en0 && wr_addr0 == addr)
      return wr_data0;
    else if (wr_en1 && wr_addr1 == addr)
      return wr_data1;
    else
      return regs[addr];
  endfunction

  // Combinational reads
  always_comb begin
    rd_data_a0 = read_bypass(rd_addr_a0);
    rd_data_b0 = read_bypass(rd_addr_b0);
    rd_data_c0 = read_bypass(rd_addr_c0);
    rd_data_a1 = read_bypass(rd_addr_a1);
    rd_data_b1 = read_bypass(rd_addr_b1);
    rd_data_c1 = read_bypass(rd_addr_c1);
  end

  // Sequential writes
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NUM_REGS; i++)
        regs[i] <= 128'd0;
    end else if (load_en) begin
      regs[load_addr] <= load_data;
    end else begin
      // Even writeback
      if (wr_en0) regs[wr_addr0] <= wr_data0;
      // Odd writeback  (if same addr as even, even wins -- written first)
      if (wr_en1 && !(wr_en0 && wr_addr0 == wr_addr1))
        regs[wr_addr1] <= wr_data1;
    end
  end

endmodule
