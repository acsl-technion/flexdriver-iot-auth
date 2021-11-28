//======================================================================
//
// sha256_core_pipelined.v
// -------------
// Verilog 2001 implementation of the SHA-256 hash function.
// This is the internal core with wide interfaces.
//
//
// Author: Joachim Strombergson
// Copyright (c) 2013, Secworks Sweden AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================
//
// Modified t1 & t2 additions to use carry save adders, in order to fit the 216Mhz target frequency
// Gabi Malka, Technion
// June-2018
// 
// Pipelined sha256_core option:
// Added digext_in[255:0] input, aimed to transfer intermmediate digest between sha256_core pipeline stages.
// Asserting input 'first' signal forces the sha256_core to initialize its initial digest (H) to the received digest_in.
// Gabi Malka, Technion
// June-2021

module sha256_core_pipelined(
                   input wire 		 clk,
                   input wire 		 reset_n,

                   input wire 		 init,
                   input wire 		 next,
                   input wire 		 mode,

                   input wire 		 first,
                   input wire [255 : 0]  digest_in,
                   input wire [511 : 0]  block,
		   
                   output wire 		 ready,
                   output wire [255 : 0] digest,
                   output wire 		 digest_valid
                  );


  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  parameter SHA224_H0_0 = 32'hc1059ed8;
  parameter SHA224_H0_1 = 32'h367cd507;
  parameter SHA224_H0_2 = 32'h3070dd17;
  parameter SHA224_H0_3 = 32'hf70e5939;
  parameter SHA224_H0_4 = 32'hffc00b31;
  parameter SHA224_H0_5 = 32'h68581511;
  parameter SHA224_H0_6 = 32'h64f98fa7;
  parameter SHA224_H0_7 = 32'hbefa4fa4;

  parameter SHA256_H0_0 = 32'h6a09e667;
  parameter SHA256_H0_1 = 32'hbb67ae85;
  parameter SHA256_H0_2 = 32'h3c6ef372;
  parameter SHA256_H0_3 = 32'ha54ff53a;
  parameter SHA256_H0_4 = 32'h510e527f;
  parameter SHA256_H0_5 = 32'h9b05688c;
  parameter SHA256_H0_6 = 32'h1f83d9ab;
  parameter SHA256_H0_7 = 32'h5be0cd19;

  parameter SHA256_ROUNDS = 63;

  parameter CTRL_IDLE   = 0;
  parameter CTRL_ROUNDS = 1;
  parameter CTRL_DONE   = 2;


  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  reg [31 : 0] a_reg;
  reg [31 : 0] a_new;
  reg [31 : 0] b_reg;
  reg [31 : 0] b_new;
  reg [31 : 0] c_reg;
  reg [31 : 0] c_new;
  reg [31 : 0] d_reg;
  reg [31 : 0] d_new;
  reg [31 : 0] e_reg;
  reg [31 : 0] e_new;
  reg [31 : 0] f_reg;
  reg [31 : 0] f_new;
  reg [31 : 0] g_reg;
  reg [31 : 0] g_new;
  reg [31 : 0] h_reg;
  reg [31 : 0] h_new;
  reg          a_h_we;

  reg [31 : 0] H0_reg;
  reg [31 : 0] H0_new;
  reg [31 : 0] H1_reg;
  reg [31 : 0] H1_new;
  reg [31 : 0] H2_reg;
  reg [31 : 0] H2_new;
  reg [31 : 0] H3_reg;
  reg [31 : 0] H3_new;
  reg [31 : 0] H4_reg;
  reg [31 : 0] H4_new;
  reg [31 : 0] H5_reg;
  reg [31 : 0] H5_new;
  reg [31 : 0] H6_reg;
  reg [31 : 0] H6_new;
  reg [31 : 0] H7_reg;
  reg [31 : 0] H7_new;
  reg          H_we;

  reg [5 : 0] t_ctr_reg;
  reg [5 : 0] t_ctr_new;
  reg         t_ctr_we;
  reg         t_ctr_inc;
  reg         t_ctr_rst;

  reg digest_valid_reg;
  reg digest_valid_new;
  reg digest_valid_we;

  reg [1 : 0] sha256_ctrl_reg;
  reg [1 : 0] sha256_ctrl_new;
  reg         sha256_ctrl_we;


  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg digest_init;
  reg digest_update;

  reg state_init;
  reg state_update;

  reg first_block;

  reg ready_flag;

  reg [31 : 0] t1;
  reg [31 : 0] t2;

  wire [31 : 0] k_data;

  reg           w_init;
  reg           w_next;
  wire [31 : 0] w_data;
  wire [31:0] 	w_data_sum;
  wire [31:0] 	w_data_carry;
  

  //----------------------------------------------------------------
  // Module instantiantions.
  //----------------------------------------------------------------
  sha256_k_constants k_constants_inst(
                                      .addr(t_ctr_reg),
                                      .K(k_data)
                                     );
  
  sha256_w_mem w_mem_inst(
                          .clk(clk),
                          .reset_n(reset_n),

                          .block(block),

                          .init(w_init),
                          .next(w_next),
                          .w_sum(w_data_sum),
                          .w_carry(w_data_carry)
                         );


  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign ready = ready_flag;

  assign digest = {H0_reg, H1_reg, H2_reg, H3_reg,
                   H4_reg, H5_reg, H6_reg, H7_reg};

  assign digest_valid = digest_valid_reg;


  //----------------------------------------------------------------
  // reg_update
  // Update functionality for all registers in the core.
  // All registers are positive edge triggered with asynchronous
  // active low reset. All registers have write enable.
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin : reg_update
      if (!reset_n)
        begin
          a_reg            <= 32'h0;
          b_reg            <= 32'h0;
          c_reg            <= 32'h0;
          d_reg            <= 32'h0;
          e_reg            <= 32'h0;
          f_reg            <= 32'h0;
          g_reg            <= 32'h0;
          h_reg            <= 32'h0;
          H0_reg           <= 32'h0;
          H1_reg           <= 32'h0;
          H2_reg           <= 32'h0;
          H3_reg           <= 32'h0;
          H4_reg           <= 32'h0;
          H5_reg           <= 32'h0;
          H6_reg           <= 32'h0;
          H7_reg           <= 32'h0;
          digest_valid_reg <= 0;
          t_ctr_reg        <= 6'h0;
          sha256_ctrl_reg  <= CTRL_IDLE;
        end
      else begin

          if (a_h_we)
            begin
              a_reg <= a_new;
              b_reg <= b_new;
              c_reg <= c_new;
              d_reg <= d_new;
              e_reg <= e_new;
              f_reg <= f_new;
              g_reg <= g_new;
              h_reg <= h_new;
            end

          if (H_we)
            begin
              H0_reg <= H0_new;
              H1_reg <= H1_new;
              H2_reg <= H2_new;
              H3_reg <= H3_new;
              H4_reg <= H4_new;
              H5_reg <= H5_new;
              H6_reg <= H6_new;
              H7_reg <= H7_new;
            end

          if (t_ctr_we)
            t_ctr_reg <= t_ctr_new;

          if (digest_valid_we)
            digest_valid_reg <= digest_valid_new;

          if (sha256_ctrl_we)
            sha256_ctrl_reg <= sha256_ctrl_new;
        end
    end // reg_update


  //----------------------------------------------------------------
  // digest_logic
  //
  // The logic needed to init as well as update the digest.
  //----------------------------------------------------------------
  always @*
    begin : digest_logic
      H0_new = 32'h0;
      H1_new = 32'h0;
      H2_new = 32'h0;
      H3_new = 32'h0;
      H4_new = 32'h0;
      H5_new = 32'h0;
      H6_new = 32'h0;
      H7_new = 32'h0;
      H_we = 0;

      if (digest_init)
        begin
          H_we = 1;
          if (mode)
            begin
	      if (first_block)
		begin
		  H0_new = SHA256_H0_0;
		  H1_new = SHA256_H0_1;
		  H2_new = SHA256_H0_2;
		  H3_new = SHA256_H0_3;
		  H4_new = SHA256_H0_4;
		  H5_new = SHA256_H0_5;
		  H6_new = SHA256_H0_6;
		  H7_new = SHA256_H0_7;
		end
	      else
		begin
		  // Current sha256 module is NOT the first in the pipelined sha256 core
		  // Initialize H* to the "digest" from previous sha() stage.
		  H0_new  = digest_in[255:224];
		  H1_new  = digest_in[223:192];
		  H2_new  = digest_in[191:160];
		  H3_new  = digest_in[159:128];
		  H4_new  = digest_in[127:96];
		  H5_new  = digest_in[95:64];
		  H6_new  = digest_in[63:32];
		  H7_new  = digest_in[31:0];
		end
            end
          else
            begin
              H0_new = SHA224_H0_0;
              H1_new = SHA224_H0_1;
              H2_new = SHA224_H0_2;
              H3_new = SHA224_H0_3;
              H4_new = SHA224_H0_4;
              H5_new = SHA224_H0_5;
              H6_new = SHA224_H0_6;
              H7_new = SHA224_H0_7;
            end
        end

      if (digest_update)
        begin
          H0_new = H0_reg + a_reg;
          H1_new = H1_reg + b_reg;
          H2_new = H2_reg + c_reg;
          H3_new = H3_reg + d_reg;
          H4_new = H4_reg + e_reg;
          H5_new = H5_reg + f_reg;
          H6_new = H6_reg + g_reg;
          H7_new = H7_reg + h_reg;
          H_we = 1;
        end
    end // digest_logic


  //----------------------------------------------------------------
  // t1_logic
  //
  // The logic for the T1 function.
  //----------------------------------------------------------------
  reg [31 : 0] sum1;
  reg [31 : 0] ch;
  always @*
    begin : t1_logic

      sum1 = {e_reg[5  : 0], e_reg[31 :  6]} ^
             {e_reg[10 : 0], e_reg[31 : 11]} ^
             {e_reg[24 : 0], e_reg[31 : 25]};

      ch = (e_reg & f_reg) ^ ((~e_reg) & g_reg);

    end // t1_logic

// t1 calculation, using csa
  wire [31:0] 	   t1_sum;
  wire [31:0] 	   t1_carry;
  
  csa_32x6 csa_32x6_1(
		      .in1(h_reg),
		      .in2(sum1),
		      .in3(ch),
		      .in4(k_data),
		      .in5(w_data_sum),
		      .in6({w_data_carry[30:0], 1'b0}),
		      .sum(t1_sum),
		      .carry(t1_carry)
		      );

  always @*
    begin
      t1 = t1_sum + {t1_carry[30:0], 1'b0};
   end
  
  
  //----------------------------------------------------------------
  // t2_logic
  //
  // The logic for the T2 function
  //----------------------------------------------------------------
  reg [31 : 0] t2_sum0;
  reg [31 : 0] t2_maj;
  always @*
    begin : t2_logic

      t2_sum0 = {a_reg[1  : 0], a_reg[31 :  2]} ^
             {a_reg[12 : 0], a_reg[31 : 13]} ^
             {a_reg[21 : 0], a_reg[31 : 22]};

      t2_maj = (a_reg & b_reg) ^ (a_reg & c_reg) ^ (b_reg & c_reg);

    end // t2_logic


// t2 calculation, using csa
  wire [31:0] 	   a_new_sum;
  wire [31:0] 	   a_new_carry;
  wire [31:0] 	   e_new_sum;
  wire [31:0] 	   e_new_carry;

  csa_32x4 a_new_csa(
		     .in1(t1_sum),
		     .in2({t1_carry[30:0], 1'b0}),
		     .in3(t2_sum0),
		     .in4(t2_maj),
		     .sum(a_new_sum),
		     .carry(a_new_carry)
		     );
  
  csa_32x3 e_new_csa(
		     .in1(t1_sum),
		     .in2({t1_carry[30:0], 1'b0}),
		     .in3(d_reg),
		     .sum(e_new_sum),
		     .carry(e_new_carry)
		     );
  

  //----------------------------------------------------------------
  // state_logic
  //
  // The logic needed to init as well as update the state during
  // round processing.
  //----------------------------------------------------------------
  always @*
    begin : state_logic
      a_new  = 32'h0;
      b_new  = 32'h0;
      c_new  = 32'h0;
      d_new  = 32'h0;
      e_new  = 32'h0;
      f_new  = 32'h0;
      g_new  = 32'h0;
      h_new  = 32'h0;
      a_h_we = 0;

      if (state_init)
        begin
          a_h_we = 1;
          if (first_block)
            begin
              if (mode)
                begin
                  a_new  = SHA256_H0_0;
                  b_new  = SHA256_H0_1;
                  c_new  = SHA256_H0_2;
                  d_new  = SHA256_H0_3;
                  e_new  = SHA256_H0_4;
                  f_new  = SHA256_H0_5;
                  g_new  = SHA256_H0_6;
                  h_new  = SHA256_H0_7;
                end
              else
                begin
                  a_new  = SHA224_H0_0;
                  b_new  = SHA224_H0_1;
                  c_new  = SHA224_H0_2;
                  d_new  = SHA224_H0_3;
                  e_new  = SHA224_H0_4;
                  f_new  = SHA224_H0_5;
                  g_new  = SHA224_H0_6;
                  h_new  = SHA224_H0_7;
                end
            end
          else
            begin

//              a_new  = H0_reg;
//              b_new  = H1_reg;
//              c_new  = H2_reg;
//              d_new  = H3_reg;
//              e_new  = H4_reg;
//              f_new  = H5_reg;
//              g_new  = H6_reg;
//              h_new  = H7_reg;
	      // Current sha256 module is NOT the first in the pipelined sha256 core
	      // Initialize H* to the "digest" from previous sha() stage.
              a_new  = digest_in[255:224];
              b_new  = digest_in[223:192];
              c_new  = digest_in[191:160];
              d_new  = digest_in[159:128];
              e_new  = digest_in[127:96];
              f_new  = digest_in[95:64];
              g_new  = digest_in[63:32];
              h_new  = digest_in[31:0];
            end
        end

      if (state_update)
        begin
//          a_new  = t1 + t2;
          a_new  = a_new_sum + {a_new_carry[30:0], 1'b0};
          b_new  = a_reg;
          c_new  = b_reg;
          d_new  = c_reg;
//          e_new  = d_reg + t1;
          e_new  = e_new_sum + {e_new_carry[30:0], 1'b0};
          f_new  = e_reg;
          g_new  = f_reg;
          h_new  = g_reg;
          a_h_we = 1;
        end
    end // state_logic

  
  //----------------------------------------------------------------
  // t_ctr
  //
  // Update logic for the round counter, a monotonically
  // increasing counter with reset.
  //----------------------------------------------------------------
  always @*
    begin : t_ctr
      t_ctr_new = 0;
      t_ctr_we  = 0;

      if (t_ctr_rst)
        begin
          t_ctr_new = 0;
          t_ctr_we  = 1;
        end

      if (t_ctr_inc)
        begin
          t_ctr_new = t_ctr_reg + 1'b1;
          t_ctr_we  = 1;
        end
    end // t_ctr


  //----------------------------------------------------------------
  // sha256_ctrl_fsm
  //
  // Logic for the state machine controlling the core behaviour.
  //----------------------------------------------------------------
  always @*
    begin : sha256_ctrl_fsm
      digest_init      = 0;
      digest_update    = 0;

      state_init       = 0;
      state_update     = 0;

      first_block      = 0;
      ready_flag       = 0;

      w_init           = 0;
      w_next           = 0;

      t_ctr_inc        = 0;
      t_ctr_rst        = 0;

      digest_valid_new = 0;
      digest_valid_we  = 0;

      sha256_ctrl_new  = CTRL_IDLE;
      sha256_ctrl_we   = 0;


      case (sha256_ctrl_reg)
        CTRL_IDLE:
          begin
            ready_flag = 1;

            if (init)
              begin
                digest_init      = 1;
                w_init           = 1;
                state_init       = 1;
//                first_block      = 1;
                t_ctr_rst        = 1;
                digest_valid_new = 0;
                digest_valid_we  = 1;
                sha256_ctrl_new  = CTRL_ROUNDS;
                sha256_ctrl_we   = 1;
		if (first)
		  // Current sha256 module is the first in the pipelined sha256 core
		  // Initialize H* to the default setting
                  first_block      = 1;
              end

            if (next)
              begin
                t_ctr_rst        = 1;
                w_init           = 1;
                state_init       = 1;
                digest_valid_new = 0;
                digest_valid_we  = 1;
                sha256_ctrl_new  = CTRL_ROUNDS;
                sha256_ctrl_we   = 1;
              end
          end


        CTRL_ROUNDS:
          begin
            w_next       = 1;
            state_update = 1;
            t_ctr_inc    = 1;

            if (t_ctr_reg == SHA256_ROUNDS)
              begin
                sha256_ctrl_new = CTRL_DONE;
                sha256_ctrl_we  = 1;
              end
          end


        CTRL_DONE:
          begin
            digest_update    = 1;
            digest_valid_new = 1;
            digest_valid_we  = 1;

            sha256_ctrl_new  = CTRL_IDLE;
            sha256_ctrl_we   = 1;
          end
      endcase // case (sha256_ctrl_reg)
    end // sha256_ctrl_fsm

endmodule // sha256_core_pipelined
