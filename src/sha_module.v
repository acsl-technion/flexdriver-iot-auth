/*
 * Copyright (c) 2021 Gabi Malka.
 * Licensed under the 2-clause BSD license, see LICENSE for details.
 * SPDX-License-Identifier: BSD-2-Clause
 */

////////////////////////////////////////////////////////////////////////////////////////////////  
// sha Module
// ==========
//
// Modifying sha256_core to support pipelined sha calculation:
// Adding two input fifos to sha256_core, to accept both the input text as well as the previous pipe-stage signature (H*)
// Gabi, June-2021
//

module sha_module (
  input wire 	      clk,
  input wire 	      reset,

// 'First' pipestate in a multi stage sha calculatin		   
  input wire 	      first,

 // Block input to sha module
  input wire 	      text_vld,
  output wire 	      text_rdy,
  input wire [511:0]  text_data,

 // H input to sha module
  input wire 	      hin_vld,
  output wire 	      hin_rdy,
  input wire [255:0]  hin_data,

 // H output: 
  output wire 	      hout_vld,
  input wire 	      hout_rdy,
  output wire [255:0] hout_data

  );

  reg 				     textfifo_rdy;
  wire 				     textfifo_vld;
  wire [511:0] 	                     textfifo_data;
  reg 				     hinfifo_rdy;
  wire 				     hinfifo_vld;
  wire [255:0] 	                     hinfifo_data;

  wire [255:0] 			     sha_digest;
  reg 				     sha_init;
  reg 				     sha_next;
  wire 				     sha_ready;
  wire 				     sha_valid;
  reg 				     sha_busy;
  reg 				     sha_last;
  reg 				     sha_out_valid;
  reg [31:0] 			     sha_read_counter;
  reg 				     sha2fifo_input_vld;
  
  // sha input fifo (512 x 512 bit, constructed of two 256bit fifos connected in parallel):
//  axis_512x512b_fifo ik2sha_fifo (
//  .s_aclk(clk),                                                         // input wire s_aclk
//  .s_aresetn(~reset),                                                   // input wire s_aresetn
//  .s_axis_tvalid(ik2fifo_vld),                                          // input wire s_axis_tvalid
//  .s_axis_tready(ik2fifo_rdy),                                          // output wire s_axis_tready
//  .s_axis_tdata(ik2fifo_data),                                          // input wire [511 : 0] s_axis_tdata
//  .s_axis_tlast(ik2fifo_last),                                          // input wire s_axis_tlast
//  .m_axis_tvalid(fifo2sha_vld),                                         // output wire m_axis_tvalid
//  .m_axis_tready(fifo2sha_rdy),                                         // input wire m_axis_tready
//  .m_axis_tdata(fifo2sha_data),                                         // output wire [511 : 0] m_axis_tdata
//  .m_axis_tlast(fifo2sha_last),                                         // output wire m_axis_tlast
//  .axis_data_count(fifo2sha_data_count)                                 // output wire [9 : 0] axis_data_count
//);
//
//  // sha results (digests) 512 x 256bit fifo:
//  axis_512x256b_fifo sha2ik_fifo (
//    .s_aclk(clk),                                                 // input wire s_aclk
//    .s_aresetn(~reset),                                           // input wire s_aresetn
//    .s_axis_tvalid(sha2fifo_input_vld),                          // input wire s_axis_tvalid
//    .s_axis_tready(sha2fifo_output_rdy),                          // output wire s_axis_tready
//    .s_axis_tdata(sha2fifo_data),                                 // input wire [255 : 0] s_axis_tdata
//    .s_axis_tlast(1'b1),                                          // input wire s_axis_tlast
//    .m_axis_tvalid(fifo2ik_vld),                                  // output wire m_axis_tvalid
//    .m_axis_tready(fifo2ik_rdy),                                  // input wire m_axis_tready
//    .m_axis_tdata(fifo2ik_data),                                  // output wire [255 : 0] m_axis_tdata
//    .m_axis_tlast(fifo2ik_last),                                  // output wire m_axis_tlast
//    .axis_data_count(fifo2ik_data_count)                          // output wire [9 : 0] axis_data_count
//  );

// sha units control state machine: Controlling the digest calculation per each sha unit.
localparam
  SHA_IDLE = 3'd0,
  SHA_READ_FIRST = 3'd1,
  SHA_WAIT_NEXT = 3'd2,
  SHA_READ_NEXT = 3'd3,
  SHA_READ_REST = 3'd4,
  SHA_WAIT_OUTPUT_VALID = 3'd5,
  SHA_WAIT_OUTPUT_READ = 3'd6;
 
  reg [2:0]   sha_state;


// sha2fifo state machine: Reading sha units result to output fifo
localparam
  FIFO2SHA_IDLE = 3'd0,
  FIFO2SHA_WAIT_NEXT_BLOCK = 3'd1,
  FIFO2SHA_READ_NEXT_BLOCK = 3'd2,
  FIFO2SHA_READ_REST = 3'd3,
  FIFO2SHA_LAST_BLOCK = 3'd4;
  
  reg [2:0]   fifo2sha_state;


// Input fifo to sha_fifo state machine 
// ====================================
// Transferring a complete packet from input fifo to the selected sha fifo.
// The packet transfer begins only if the target sha fifo is empty, to avoid any confusion with possibly previous sha calculation 
//
//  always @(posedge clk) begin
//    if (reset) begin
//      fifo2sha_state <= FIFO2SHA_IDLE;
//      shafifoin_vld <= 32'h0000;
//    end
//    else begin
//      case (fifo2sha_state)
//        FIFO2SHA_IDLE: begin
//	  fifo2sha_rdy <= 1'b0;
//	  shafifoin_vld <= 32'h0000;
//	  
//          if (fifo2sha_vld & selected_shafifo_free) begin
//            fifo2sha_state <= FIFO2SHA_READ_NEXT_BLOCK;
//	  end
//	  
//	  else 
//            fifo2sha_state <= FIFO2SHA_IDLE;
//	end
//	
//        FIFO2SHA_LAST_BLOCK: begin
//	  fifo2sha_rdy <= 1'b0;
//	  shafifoin_vld <= 32'h0000;
//
//	  // Packet transfer is ended: Select next sha unit
//          fifo2sha_state <= FIFO2SHA_IDLE;
//	end
//	
//        FIFO2SHA_READ_NEXT_BLOCK: begin
//	  fifo2sha_rdy <= 1'b1;
//	  shafifoin_vld <= selected_sha_unit;
//          fifo2sha_state <= FIFO2SHA_READ_REST;
////          fifo2sha_lastQ <= fifo2sha_last;
//	end
//	
//        FIFO2SHA_READ_REST: begin
//	  fifo2sha_rdy <= 1'b0;
//	  shafifoin_vld <= 32'h0000;
//
//          if (fifo2sha_last)
//            fifo2sha_state <= FIFO2SHA_LAST_BLOCK;
//	  else
//            fifo2sha_state <= FIFO2SHA_WAIT_NEXT_BLOCK;
//	end
//	
//        FIFO2SHA_WAIT_NEXT_BLOCK: begin 
//
//          if (fifo2sha_vld)
//            fifo2sha_state <= FIFO2SHA_READ_NEXT_BLOCK;
//          else
//            fifo2sha_state <= FIFO2SHA_WAIT_NEXT_BLOCK;
//	end
//	
//	default: begin
//          fifo2sha_state <= FIFO2SHA_IDLE;
//	  fifo2sha_rdy <= 1'b0;
//	  shafifoin_vld <= 32'h0000;
//	end
//	
//      endcase
//    end
//  end


  // Per sha input fifo
  // For sha unit j, in a multi-block case, all blocks are loaded to fifo, before proceeding to next sha unit
  // Notice that despite its short depth (16 entries only) this fifo still consumes 8 (!!!) 36kb BRAMs
  //  axis_16x512b_fifo sha_fifo (
  //    .s_aclk(clk),                               // input wire s_aclk
  //    .s_aresetn(~reset),                         // input wire s_aresetn
  //    .s_axis_tvalid(shafifoin_vld[j]),           // input wire s_axis_tvalid
  //    .s_axis_tready(shafifoin_rdy[j]),           // output wire s_axis_tready
  //    .s_axis_tdata(fifo2sha_data),               // input wire [511 : 0] s_axis_tdata
  //    .s_axis_tlast(fifo2sha_last),               // input wire s_axis_tlast
  //    .m_axis_tvalid(shafifoout_vld[j]),          // output wire m_axis_tvalid
  //    .m_axis_tready(shafifoout_rdy[j]),         // input wire m_axis_tready
  //    .m_axis_tdata(shafifoout_data[j]),          // output wire [511 : 0] m_axis_tdata
  //    .m_axis_tlast(shafifoout_last[j]),          // output wire m_axis_tlast
  //    .axis_data_count(shafifoout_data_count[j])  // output wire [4 : 0] axis_data_count
  //  );
  
  // hin fifo
  fifo_distram_16x256b sha_module_hin_fifo
    (
     .s_aclk(clk),                // input wire s_aclk
     .s_aresetn(~reset),          // input wire s_aresetn
     .s_axis_tvalid(hin_vld),  // input wire s_axis_tvalid
     .s_axis_tready(hin_rdy),  // output wire s_axis_tready
     .s_axis_tdata(hin_data),    // input wire [255 : 0] s_axis_tdata
     .m_axis_tvalid(hinfifo_vld),  // output wire m_axis_tvalid
     .m_axis_tready(hinfifo_rdy),  // input wire m_axis_tready
     .m_axis_tdata(hinfifo_data)    // output wire [255 : 0] m_axis_tdata
     );

  // textin fifo
  fifo_distram_16x512 sha_module_textin_fifo
    (
     .s_aclk(clk),                // input wire s_aclk
     .s_aresetn(~reset),          // input wire s_aresetn
     .s_axis_tvalid(text_vld),  // input wire s_axis_tvalid
     .s_axis_tready(text_rdy),  // output wire s_axis_tready
     .s_axis_tdata(text_data),    // input wire [511 : 0] s_axis_tdata
     .m_axis_tvalid(textfifo_vld),  // output wire m_axis_tvalid
     .m_axis_tready(textfifo_rdy),  // input wire m_axis_tready
     .m_axis_tdata(textfifo_data)    // output wire [511 : 0] m_axis_tdata
     );

  // Asserting 'last'
  // We utilize the original sha256_core logic, which aimed to digest multiple blocks.
  // Howeve, since the HMAC sha calculation is pipelined, each sha stage digests a single block, thus each block is considered 'last'
  assign shafifoout_last = 1'b1;

  assign hout_vld = sha_out_valid;

  
  // fifos_in to sha_core  state machine
  // ===============================
  // The SM will load next available block (text & hin) to the sha unit, once that unit is free, and the output port is ready
  //
  always @(posedge clk) begin
    if (reset) begin
      sha_state <= SHA_IDLE;
      sha_init <= 1'b0;
      sha_next <= 1'b0;
      sha_last <= 1'b0;
      sha_busy <= 1'b0;
      //      shafifoout_rdy  <= 1'b0;
      textfifo_rdy  <= 1'b0;
      hinfifo_rdy  <= 1'b0;
      sha_out_valid <= 1'b0;
    end
    else begin
      case (sha_state)
        SHA_IDLE: begin
	  sha_init <= 1'b0;
	  sha_next <= 1'b0;
	  sha_busy <= 1'b0;
	  //	  shafifoout_rdy  <= 1'b0;
	  textfifo_rdy  <= 1'b0;
	  hinfifo_rdy  <= 1'b0;

          if (textfifo_vld && (first || hinfifo_vld) && hout_rdy && ~sha_busy) begin
	    // A new sha operation is started when:
	    // 1. A new text block is present
	    // 2. Previous sig (Hin) is present, if current sha_core instance is NOT the first in a multi stage pipeline 
	    // 3. The sha output port is ready to accept the resulting sig (Hout)  
	    // 4. current sha_core is not busy with previous operation
            sha_state <= SHA_READ_FIRST;
	  end
	  
	  else 
            sha_state <= SHA_IDLE;
	end
	
        SHA_READ_FIRST: begin
	  sha_busy <= 1'b1;
	  sha_init <= 1'b1;
//	  shafifoout_rdy  <= 1'b1;
	  textfifo_rdy  <= 1'b1;
	  if (~first && hinfifo_vld)
	    // hin fifo is read only in a non-first pipe stage
	    hinfifo_rdy  <= 1'b1;
	  
	  sha_last <= shafifoout_last;
          sha_state <= SHA_READ_REST;
	end
	
        SHA_READ_REST: begin 
	  sha_init <= 1'b0;
	  sha_next <= 1'b0;
//	  shafifoout_rdy <= 1'b0;
	  textfifo_rdy  <= 1'b0;
	  hinfifo_rdy  <= 1'b0;
          sha_state <= SHA_WAIT_OUTPUT_VALID;
	end

//      SHA_WAIT_NEXT: begin 
//        if (textfifo_vld)
//          sha_state <= SHA_READ_NEXT;
//        else
//          sha_state <= SHA_WAIT_NEXT;
//	end
//	
//      SHA_READ_NEXT: begin
//	  sha_next <= 1'b1;
//	  shafifoout_rdy  <= 1'b1;
//	  textfifo_rdy  <= 1'b1;
//	  if (hin_present)
//	    hinfifo_rdy  <= 1'b1;
//
//	  sha_last <= shafifoout_last;
//        sha_state <= SHA_READ_REST;
//	end
//	
	SHA_WAIT_OUTPUT_VALID: begin
          if (sha_ready) begin
            if (sha_last) begin
	      // This is the last block (of single or multiple blocks digest operation). 
	      // Prepare for reading the result to output fifo
              sha_state <= SHA_WAIT_OUTPUT_READ;
	      sha_out_valid <= 1'b1;
	    end
            else
	      // Not the last block... Goto digesting next block
	      // Irrelevant for hmac calculation, since each sha calc is a single block
              sha_state <= SHA_WAIT_NEXT;
	  end
            else
              sha_state <= SHA_WAIT_OUTPUT_VALID;
	end
	
	SHA_WAIT_OUTPUT_READ: begin
	  //          if (sha2fifo_input_vld & sha_read_counter) begin
	  // Jth sha unit output is being read to output fifo
	  // Turn off the Jth output valid indicator
	  sha_out_valid <= 1'b0;
          sha_busy <= 1'b0;
          sha_state <= SHA_IDLE;
	end
	// else
	//         sha_state <= SHA_WAIT_OUTPUT_READ;

	default: begin
          sha_state <= SHA_IDLE;
	end
      endcase
    end
  end


  // tie digest_in to all-zero, if current sha_module instance is the first in the pipe
  wire [255:0] digest_in;
  assign digest_in = first ? 256'b0 : hinfifo_data;

  assign hout_data = sha_digest;
  
  sha256_core_pipelined sha256_core_pipelined
    (
     .clk(clk),
     .reset_n(~reset),
     .init(sha_init),
     .next(sha_next),
     .mode(1'b1), // set mode to sha256

     .first(first),
     .digest_in(digest_in),

     .block(textfifo_data),    
     .ready(sha_ready),
     .digest(sha_digest),
     .digest_valid(sha_valid)
     );
  
endmodule
