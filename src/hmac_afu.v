/*
 * Copyright (c) 2021 Gabi Malka.
 * Licensed under the 2-clause BSD license, see LICENSE for details.
 * SPDX-License-Identifier: BSD-2-Clause
 */
module hmac_afu(
	       clk,
	       reset,

	       afu_soft_reset,
	       pci2sbu_axi4stream_vld,
	       pci2sbu_axi4stream_rdy,
	       pci2sbu_axi4stream_tdata,
	       pci2sbu_axi4stream_tkeep,
	       pci2sbu_axi4stream_tlast,
	       pci2sbu_axi4stream_tuser, 

	       sbu2pci_axi4stream_vld,
	       sbu2pci_axi4stream_rdy,
	       sbu2pci_axi4stream_tdata,
	       sbu2pci_axi4stream_tkeep,
	       sbu2pci_axi4stream_tlast,
	       sbu2pci_axi4stream_tuser,
	       
	       axilite_aw_rdy,
	       axilite_aw_vld,
	       axilite_aw_addr,
	       axilite_aw_prot,
	       axilite_w_rdy,
	       axilite_w_vld,
	       axilite_w_data,
	       axilite_w_strobe,
	       axilite_b_rdy,
	       axilite_b_vld,
	       axilite_b_resp,
	       axilite_ar_rdy,
	       axilite_ar_vld,
	       axilite_ar_addr,
	       axilite_ar_prot,
	       axilite_r_rdy,
	       axilite_r_vld,
	       axilite_r_data,
	       axilite_r_resp,

	       fld_pci_sample_soft_reset,
	       fld_pci_sample_enable,
	       afu_events
	       );
  
  input          clk;
  input          reset;
  
  output 	 afu_soft_reset;
  output	 pci2sbu_axi4stream_rdy;
  input          pci2sbu_axi4stream_vld;
  input [511:0]  pci2sbu_axi4stream_tdata;
  input [63:0] 	 pci2sbu_axi4stream_tkeep;
  input [0:0] 	 pci2sbu_axi4stream_tlast;
  input [71:0] 	 pci2sbu_axi4stream_tuser;
  
  input          sbu2pci_axi4stream_rdy;
  output         sbu2pci_axi4stream_vld;
  output [511:0] sbu2pci_axi4stream_tdata;
  output [63:0]  sbu2pci_axi4stream_tkeep;
  output [0:0] 	 sbu2pci_axi4stream_tlast;
  output [71:0]  sbu2pci_axi4stream_tuser;
  
  output 	 axilite_aw_rdy;
  input 	 axilite_aw_vld;
  input [63:0] 	 axilite_aw_addr;
  input [2:0] 	 axilite_aw_prot;
  output 	 axilite_w_rdy;
  input 	 axilite_w_vld;
  input [31:0] 	 axilite_w_data;
  input [3:0] 	 axilite_w_strobe;
  input 	 axilite_b_rdy;
  output 	 axilite_b_vld;
  output [1:0] 	 axilite_b_resp;
  output 	 axilite_ar_rdy;
  input 	 axilite_ar_vld;
  input [63:0] 	 axilite_ar_addr;
  input [2:0] 	 axilite_ar_prot;
  input 	 axilite_r_rdy;
  output 	 axilite_r_vld;
  output [31:0]  axilite_r_data;
  output [1:0] 	 axilite_r_resp;
  output 	 fld_pci_sample_soft_reset;
  output [1:0] 	 fld_pci_sample_enable;
  output [63:0]  afu_events;

`include "hmac_params.v"

  // Limit number of zuc modules to 8
  localparam NUM_MODULES = NUMBER_OF_MODULES < 'd9 ? NUMBER_OF_MODULES : 'd8;
  
//------------------------Local axi4lite ------------------
  // ======================================================
  // AFU registers/counters and its axi4lite address mapping
  // ======================================================
  //
  // afu_ctrl0    General AFU & modules control
  //       [31] - hmac_afu reset. Writing '1 will reset hmac_afu (same as power up/hw reset)
  //       [30] - Reserved
  //       [29] - hmac: sbu2pci chanel_id indication enable
  //              When set, sbu2pci.tuser[0] is toggled between successive sbi2pci transactions
  //
  //       [28] - Force incoming pci2sbu_tuser[EOM].
  //              Temporarily added per Haggai's request, until EOM is implemented in FLD
  //             
  //    [27:20] - zuc_module i [7 thru 0] enabled. Module i enable is ignored, if module i is not instantiated
  //              Default setting, 8'hff: All zuc_modules are enabled
  //    [19:18] - Force AFU/Modules Bypass
  //              00 - Normal operation
  //              01 - Force hmac core bypass:
  //                   hmac core will respond with the exact input coap request, independent of hmac_match test results
  //              10 - Force AFU bypass: All messages are bypased to sbu2pci, independent of the incoming message status
  //              11 - Force Module bypass: Zuc core is bypassed. Relevant only to 'good' messages which already assigned to cores
  //                   Default setting: 'b00 - Normal mode
  //    [17:16] - fifo_in arbitration/selection mode:
  //              x0, 10: Reserved
  //              11: Simple round robin between the fifox_in
  //              hmac default setting, 11 - Simple round robin between the fifox_in
  //     [15:8] - Strict_priority assigned to queue0 in input buffer. Actual assumed priorities:
  //              q0_priority = ctrl0[15:8]/256
  //              q1_priority = 1 - ctrl0[15:8]/256
  //              Default: Priority disabled: [15:8] == 8'h00 
  //      [7:0] - input_buffer_watermark (two buffer lines == 128B == tick). Max value: 9'h1f0 (496) 
  //              The watermark is effective to all channel buffers in input buffer.
  //              channel[x] input_buffer content is not read to zuc modules, until its capacity exceeds the watermark.
  //              Default setting: 10'h000: input_buffer is read to zuc modules once it holds at least one message.
  reg [31:0]      afu_ctrl0;
  reg             afu_ctrl0_wr;

  // afu_ctrl1    Modules fifo_in watermark
  //    [31:28] - Module 7 fifo_in capacity high watermark, 32 fifo lines (2KB) per tick. Max setting: 4'hf (480 lines).
  //              The transfer from fifo7_in to zuc_core is held until this watermark is exceeded.
  //              Potential deadlock: There is insufficient free space in fifo_in for next message, and the watermark still not met.
  //              To avoind the above deadlock, the fifo hold is terminated upon meeting the watermark OR fifo_in_full
  //              fifo_in_full is asserted upon a failed atempt to write to fifo_in, due to insufficient free space. 
  //
  //              This capability is aimed for testing the zuc_cores utilization & tpt:
  //              1. To utilize all zuc_cores, there is a need to apply the messages to the cores as fast as possible.
  //              2. To eliminate the dependence on pci2sbu incoming messages rate, we accumulate into fifo_in first
  //              3. Once the watermark is exceeded, the messages are fed to the zuc cores at full speed (512b/clock). 
  //              Usage Note: This watermark is effective only once, immediateley after writing afu_ctrl1.
  //                          To reactivate, rewrite to afu_ctrl1 is required 
  //                            
  //     [27:0] - Modules 6 thru 0 fifo_in capacity high watermark.
  //              Default setting, 32'h00000000: Zero watermark to all modules fifo_in            
  reg [31:0]      afu_ctrl1;
  reg             afu_ctrl1_wr;

  // afu_ctrl2    Per channel behavior
  //    [31:30] - hmac: sha units test mode
  //              00 - normal mode // default setting
  //              01 - test mode, single block sha operation       
  //              1x - test mode, two blocks sha operation       
  //    [29:20] - Reserved
  //       [19] - PCI_SAMPLE_TRIGGER_IN
  //       [18] - PCI_SAMPLE_RATE
  //       [17] - PCI_SAMPLE_METADATA
  //       [16] - Enable messages metadata on sbu2pci_data ethernet & message headers, bits [59:0]
  //              0 - No metadata. sbu2pci_data[59:0] are cleared.
  //              1 - Metadata is added. See "Internal AFU Message Header" for details
  //              Default setting, cleared: No metadata is added to headers
  //     [15:0] - message ordering mask per channel. If ctrl2[x] is set, no messages ordering for chidx.
  //              Useful in case there is a problem with messages ordering.
  //              hmac default setting: 0x000000ff: No bypass, No message ordering for all channels 
  reg [31:0]      afu_ctrl2;
  reg             afu_ctrl2_wr;
  
  // afu_ctrl3    General afu functions
  //      [31:2] - Reserved
  //         [1] - Clear HMAC Message Counters
  //               0 - HMAC Message counters are unaffected
  //               1 - HMAC Message counters are cleared
  //         [0] - Clear backpressure Counters
  //               0 - Backpressure counters are unaffected
  //               1 - Backpressure counters are cleared
  //              Default setting, 32'h00000000
  reg [31:0]      afu_ctrl3;
  reg             afu_ctrl3_wr;

  // afu_ctrl4     Histograms Control
  //     [31:20] - Reserved
  //     [19:12] - Histogram Arrays Enable.
  //               A histogram array will start accumulating events once it has been enabled. Disabling a histogram array will halt further events accumulation,
  //               while maintaining the array contents.
  //               [19:16] reserved
  //	           [15]    sbu2pci responses size histogram enable
  //	           [14]    pci2sbu messages size histogram enable
  //	           [13]    pci2sbu packets&EOM size histogram enable
  //	           [12]    pci2sbu packets size histogram enable
  //		   [23:20] Reserved
  //               Default: 8'h00, all histograms are disabled
  //	 [11:10] - Reserved
  //	   [9:8] - Histogram clear operation.
  //               Edge sensitive control: The selected clear operation takes effect ONLY once, and after the write operation.
  //               00 - No operation
  //               01 - Clear buckets of specified channel in specified histo_array
  //               10 - Clear buckets of all channels in the specified histo_array
  //               11 - Clear buckets of all channels in all histo_arrays
  //               Default: 2'b00, No Operation
  //         [7] - Reserved
  //       [6:4] - Histogram array select. The selected array to be cleared:
  //               Note: This selection is relevant to HISTO_CLEAR_OP==01 or HISTO_CLEAR_OP==10 operations only.
  //               000 - pci2sbu packets size histogram
  //               001 - pci2sbu packets&EOM size histogram
  //               010 - pci2sbu messages size histogram
  //               011 - sbu2pci responses size histogram
  //               1xx - Reserved
  //               Default: 3b000
  //       [3:0] - Channel ID select.The selected chid[3:0] to be cleared.
  //               Note: This selection is relevant to HISTO_CLEAR_OP==01 operation only.
  //               Default: 4'h0
  //
  reg [31:0]      afu_ctrl4;
  reg             afu_ctrl4_wr;

  // afu_ctrl5   pci2sbu & sbu2pci sampling fifos enable
  //      [31] - pci2sbu & sbu2pci sampling fifos reset
  //             Edge sensitive control: The clear operation takes effect ONLY once, and after the write operation.
  //    [30:4] - Reserved
  //     [3:0] - Sampling Enable:
  //             [3] - afu_sbu2pci sampling fifo enable
  //             [2] - afu_pci2sbu sampling fifo enable
  //             [1] - fld_sbu2pci sampling fifo enable
  //             [0] - fld_pci2sbu sampling fifo enable
  //             Default: 4'h0 - Sampling is disabled
  //
  reg [31:0]      afu_ctrl5;
  reg             afu_ctrl5_wr;

  // afu_ctrl8 & 9   Sampling trigger
  //    afu_ctrl8[31:0] - Smpling_trigger[31:0]
  //    afu_ctrl9[31:0] - Smpling_trigger[63:32]
  reg [31:0]      afu_ctrl8;
  reg [31:0]      afu_ctrl9;


  reg [31:0] 	  afu_counter0;
  reg [31:0] 	  afu_counter1;
  reg [31:0] 	  afu_counter2;
  reg [31:0] 	  afu_counter3;
  reg [31:0] 	  afu_counter4;
  reg [31:0] 	  afu_counter5;
  reg [31:0] 	  afu_counter6;
  reg [31:0] 	  afu_counter7;
  reg [32:0] 	  afu_counter8;
  reg [32:0] 	  afu_counter9;
  
  reg 		  pci2sbu_pushback;
  reg 		  sbu2pci_pushback;
  reg [47:0] 	  afu_pci2sbu_pushback;
  reg [47:0] 	  afu_sbu2pci_pushback;
  reg [31:0] 	  afu_pci2sbu_pushbackl;
  reg [31:0] 	  afu_sbu2pci_pushbackl;

  reg [31:0] 	  afu_scratchpad; // Scratch pad, read/write register, for axi4lite transactions testing
  reg 		  afu_reset;
  reg [7:0] 	  afu_reset_count;
  reg 		  pci_sample_reset;
  reg [7:0] 	  pci_sample_reset_count;
  wire 		  afu_pci_sample_soft_reset;
  wire 		  afu_pci2sbu_sample_enable;
  wire 		  afu_sbu2pci_sample_enable;
  wire 		  module_in_sample_enable;
  wire 		  input_buffer_sample_enable;
  reg [47:0] 	  timestamp;
  reg [31:0] 	  timestampl;

  // Total counters
  reg [47:0] 	  total_hmac_received_requests_count;
  reg [47:0] 	  total_hmac_requests_match_count;
  reg [47:0] 	  total_hmac_requests_nomatch_count;
  reg [47:0] 	  total_hmac_forwarded_requests_count;
  reg [31:0] 	  total_hmac_received_requests_countl;
  reg [31:0] 	  total_hmac_requests_match_countl;
  reg [31:0] 	  total_hmac_requests_nomatch_countl;
  reg [31:0] 	  total_hmac_forwarded_requests_countl;

  // Per queue counters
  reg [63:0] 	  total_hmac_queue0_received_data;
  reg [32:0] 	  total_hmac_queue0_received_delta;
  reg [47:0] 	  total_hmac_queue0_received_requests;
  reg [47:0] 	  total_hmac_queue0_dropped_requests;
  reg [63:0] 	  total_hmac_queue1_received_data;
  reg [32:0] 	  total_hmac_queue1_received_delta;
  reg [47:0] 	  total_hmac_queue1_received_requests;
  reg [47:0] 	  total_hmac_queue1_dropped_requests;
  reg [31:0] 	  total_hmac_queue0_received_datal;
  reg [31:0] 	  total_hmac_queue0_received_requestsl;
  reg [31:0] 	  total_hmac_queue0_dropped_requestsl;
  reg [31:0] 	  total_hmac_queue1_received_datal;
  reg [31:0] 	  total_hmac_queue1_received_requestsl;
  reg [31:0] 	  total_hmac_queue1_dropped_requestsl;
  
  
  assign afu_soft_reset = afu_reset;
  assign afu_pci_sample_soft_reset = pci_sample_reset;
  assign afu_pci2sbu_sample_enable = afu_ctrl5[2];
  assign afu_sbu2pci_sample_enable = afu_ctrl5[3];
  assign input_buffer_sample_enable = afu_ctrl5[4] && sampling_window;
  assign module_in_sample_enable = afu_ctrl5[5] && sampling_window;
  assign fld_pci_sample_soft_reset = pci_sample_reset;
  assign fld_pci_sample_enable = afu_ctrl5[1:0];

localparam
  AXILITE_AFU_ADDR_WIDTH = 20;

localparam
  ADDR_AFU_CTRL0        = 20'h01000, // write only
  ADDR_AFU_CTRL1        = 20'h01004, // write only
  ADDR_AFU_CTRL2        = 20'h01008, // write only
  ADDR_AFU_CTRL3        = 20'h0100c, // write only
  ADDR_AFU_CTRL4        = 20'h01010, // write only
  ADDR_AFU_CTRL5        = 20'h01014, // write only
  ADDR_AFU_CTRL8        = 20'h01020, // write only
  ADDR_AFU_CTRL9        = 20'h01024, // write only
  ADDR_AFU_SCRATCHPAD   = 20'h01030, // write/read
  ADDR_AFU_COUNTER0     = 20'h01100, // read only
  ADDR_AFU_COUNTER1     = 20'h01104, // read only
  ADDR_AFU_COUNTER2     = 20'h01108, // read only
  ADDR_AFU_COUNTER3     = 20'h0110c, // read only
  ADDR_AFU_COUNTER4     = 20'h01110, // read only
  ADDR_AFU_COUNTER5     = 20'h01114, // read only
  ADDR_AFU_COUNTER6     = 20'h01118, // read only
  ADDR_AFU_COUNTER7     = 20'h0111c, // read only
  ADDR_AFU_COUNTER8     = 20'h01120, // read only
  ADDR_AFU_COUNTER9     = 20'h01124, // read only

  // pci2sbu & sbu2pci pushback counters
  ADDR_AFU_PCI2SBU_PUSHBACKH = 20'h01130, // read only
  ADDR_AFU_PCI2SBU_PUSHBACKL = 20'h01134, // read only
  ADDR_AFU_SBU2PCI_PUSHBACKH = 20'h01138, // read only
  ADDR_AFU_SBU2PCI_PUSHBACKL = 20'h0113c, // read only

// total_hmac messages counters
  ADDR_AFU_HMAC_RECEIVEDH    = 20'h01140, // read only
  ADDR_AFU_HMAC_RECEIVEDL    = 20'h01144, // read only
  ADDR_AFU_HMAC_MATCHH       = 20'h01148, // read only
  ADDR_AFU_HMAC_MATCHL       = 20'h0114c, // read only
  ADDR_AFU_HMAC_NOMATCHH     = 20'h01150, // read only
  ADDR_AFU_HMAC_NOMATCHL     = 20'h01154, // read only
  ADDR_AFU_HMAC_FORWARDEDH   = 20'h01158, // read only
  ADDR_AFU_HMAC_FORWARDEDL   = 20'h0115c, // read only

  // total_hmac per queue messages counters
  ADDR_AFU_HMAC_Q0_DATAH        = 20'h01160, // read only
  ADDR_AFU_HMAC_Q0_DATAL        = 20'h01164, // read only
  ADDR_AFU_HMAC_Q0_RECEIVEDH    = 20'h01168, // read only
  ADDR_AFU_HMAC_Q0_RECEIVEDL    = 20'h0116c, // read only
  ADDR_AFU_HMAC_Q0_DROPPEDH     = 20'h01170, // read only
  ADDR_AFU_HMAC_Q0_DROPPEDL     = 20'h01174, // read only
  ADDR_AFU_HMAC_Q1_DATAH        = 20'h01180, // read only
  ADDR_AFU_HMAC_Q1_DATAL        = 20'h01184, // read only
  ADDR_AFU_HMAC_Q1_RECEIVEDH    = 20'h01188, // read only
  ADDR_AFU_HMAC_Q1_RECEIVEDL    = 20'h0118c, // read only
  ADDR_AFU_HMAC_Q1_DROPPEDH     = 20'h01190, // read only
  ADDR_AFU_HMAC_Q1_DROPPEDL     = 20'h01194, // read only

  ADDR_TIMESTAMPH               = 20'h01200, // read only
  ADDR_TIMESTAMPL               = 20'h01204; // read only


localparam
  ADDR_AFU_HISTO_BASE     = 20'h02000, // hist tables start address.
  ADDR_AFU_HISTO0_BASE    = 20'h02000, // hist_table 0 start address. 1KB=256x4B address space is assigned to each histo table  
  ADDR_AFU_HISTO1_BASE    = 20'h02400, // hist_table 1 start address
  ADDR_AFU_HISTO2_BASE    = 20'h02800, // hist_table 2 start address 
  ADDR_AFU_HISTO3_BASE    = 20'h02c00, // hist_table 3 start address 
  ADDR_AFU_HISTO4_BASE    = 20'h03000, // hist_table 4 start address 
  ADDR_AFU_HISTO5_BASE    = 20'h03400, // hist_table 5 start address 
  ADDR_AFU_HISTO6_BASE    = 20'h03800, // hist_table 6 start address 
  ADDR_AFU_HISTO7_BASE    = 20'h03c00, // hist_table 7 start address 
  ADDR_AFU_HISTO_END      = 20'h04000; // hist_table 7 end address

  localparam
    // hmac keys array
    ADDR_HMAC_KEYS_BASE   = 20'h04000, // hmac keys table, write_only, Address space: 'h04000..'h05000, 1Kx32b = 'h1000.
    ADDR_HMAC_KEYS_END    = 20'h05000;

  localparam
  // PCI sampling buffers
  ADDR_SAMPLE_BUFFERS_BASE = AFU_CLK_PCI2SBU,                     // 20'h08000 
  ADDR_PCI2SBU_SAMPLE_BASE = AFU_CLK_PCI2SBU,                     // 20'h08000 
  ADDR_PCI2SBU_SAMPLE_END  = AFU_CLK_PCI2SBU + 20'h0100,          // 20'h08100 
  ADDR_SBU2PCI_SAMPLE_BASE = AFU_CLK_SBU2PCI,                     // 20'h08100
  ADDR_SBU2PCI_SAMPLE_END  = AFU_CLK_SBU2PCI + 20'h0100,          // 20'h08200
  ADDR_MODULE_IN_SAMPLE_BASE = AFU_CLK_MODULE_IN,                 // 20'h08200
  ADDR_MODULE_IN_SAMPLE_END  = AFU_CLK_MODULE_IN + 20'h0100,      // 20'h08300
  ADDR_INPUT_BUFFER_SAMPLE_BASE = AFU_CLK_INPUT_BUFFER,           // 20'h08300
  ADDR_INPUT_BUFFER_SAMPLE_END = AFU_CLK_INPUT_BUFFER + 20'h0100, // 20'h08400
  ADDR_SAMPLE_BUFFERS_END = AFU_CLK_INPUT_BUFFER + 20'h0100; // 20'h08400

  
  // axi4lite fsm signals
  reg [1:0] 	  axi_rstate;
  reg [1:0] 	  axi_rnext;
  reg [31:0] 	  axi_rdata;
  reg 		  axi_arready;
  wire 		  axi_aw_hs;
  wire 		  axi_w_hs;
  reg [1:0] 	  axi_wstate;
  reg [1:0] 	  axi_wnext;
  reg 		  kbuffer_write;
  reg [AXILITE_AFU_ADDR_WIDTH-1 : 0] axi_waddr;
  wire [AXILITE_AFU_ADDR_WIDTH-1 : 0] axi_raddr;
  
  localparam
    WRIDLE                     = 2'd0,
    WRDATA                     = 2'd1,
    WRRESP                     = 2'd2,
    RDIDLE                     = 2'd0,
    RDTABLEWAIT1               = 2'd1,
    RDTABLEWAIT2               = 2'd2,
    RDDATA                     = 2'd3;
  
  // Histograms-AFU interface 
  wire 	       hist_pci2sbu_packet_enable;
  reg 	       hist_pci2sbu_packet_event;
  reg [15:0]   hist_pci2sbu_packet_event_size;
  reg [3:0]    hist_pci2sbu_packet_event_chid;
  wire [31:0]  hist_pci2sbu_packet_dout;

  wire	       hist_pci2sbu_eompacket_enable;
  reg 	       hist_pci2sbu_eompacket_event;
  reg [15:0]   hist_pci2sbu_eompacket_event_size;
  reg [3:0]    hist_pci2sbu_eompacket_event_chid;
  wire [31:0]  hist_pci2sbu_eompacket_dout;

  wire	       hist_pci2sbu_message_enable;
  reg 	       hist_pci2sbu_message_event;
  reg [15:0]   hist_pci2sbu_message_event_size;
  reg [3:0]    hist_pci2sbu_message_event_chid;
  wire [31:0]  hist_pci2sbu_message_dout;

  wire	       hist_sbu2pci_response_enable;
  reg 	       hist_sbu2pci_response_event;
  reg [15:0]   hist_sbu2pci_response_event_size;
  reg [3:0]    hist_sbu2pci_response_event_chid;
  wire [31:0]  hist_sbu2pci_response_dout;

  wire 	       hist_clear = afu_ctrl4_wr;
  wire [1:0]   hist_clear_op =    afu_ctrl4[9:8];
  wire [2:0]   hist_clear_array = afu_ctrl4[6:4];
  wire [3:0]   hist_clear_chid =  afu_ctrl4[3:0];
  reg 	       clear_backpressure_counters;
  reg 	       clear_hmac_message_counters;
  
  assign hist_pci2sbu_packet_enable = afu_ctrl5[8];
  assign hist_pci2sbu_eompacket_enable = afu_ctrl5[9];
  assign hist_pci2sbu_message_enable = afu_ctrl5[10];
  assign hist_sbu2pci_response_enable = afu_ctrl5[11];
    

  // axi4lite read fsm
  assign axilite_ar_rdy = axi_arready;
  assign axilite_r_data   = axi_rdata;
  assign axilite_r_resp   = 2'b00;  // OKAY
  assign axilite_r_vld  = (axi_rstate == RDDATA);
  assign axi_raddr = {1'b0, axilite_ar_addr[AXILITE_AFU_ADDR_WIDTH-2:0]}; // address MSB is forced to 0, to enfoce a positive integer 
  assign axi_rd_table = ((axi_raddr >= ADDR_AFU_HISTO_BASE) && (axi_raddr < ADDR_AFU_HISTO_END) ||
			(axi_raddr >= ADDR_SAMPLE_BUFFERS_BASE) && (axi_raddr < ADDR_SAMPLE_BUFFERS_END))   ? 1'b1 : 1'b0;
  
  // rstate
  always @(posedge clk) begin
    if (reset) begin
      axi_rstate <= RDIDLE;
    end
    else begin
      axi_rstate <= axi_rnext;
    end
  end
  
  // rnext
  always @(*) begin
    case (axi_rstate)
      RDIDLE:
	begin
	  axi_arready = 1'b0;
          if (axilite_ar_vld && ~axi_rd_table)
	    begin
	      axi_arready = 1'b1;
              axi_rnext = RDDATA;
	    end  
	  else if (axilite_ar_vld && axi_rd_table)
            axi_rnext = RDTABLEWAIT1;
          else
            axi_rnext = RDIDLE;
	end // case: RDIDLE
      
      RDTABLEWAIT1:
	// Wait 2 clocks if the histograms arrays are read (BRAM read latency==2)
        axi_rnext = RDTABLEWAIT2;

      RDTABLEWAIT2:
	begin
	  axi_arready = 1'b1;
          axi_rnext = RDDATA;
	end
      
      RDDATA:
	begin
	  axi_arready = 1'b0;
          if (axilite_r_rdy && axilite_r_vld)
            axi_rnext = RDIDLE;
          else
            axi_rnext = RDDATA;
	end
      
      default:
        axi_rnext = RDIDLE;
    endcase
  end
  
  // rdata
  always @(posedge clk) begin
    if (reset)
      begin
	afu_pci2sbu_pushbackl <= 32'hdeadf00d;
	afu_sbu2pci_pushbackl <= 32'hdeadf00d;
	total_hmac_received_requests_countl <= 32'hdeadf00d;
	total_hmac_requests_match_countl <= 32'hdeadf00d;
	total_hmac_requests_nomatch_countl <= 32'hdeadf00d;
	total_hmac_forwarded_requests_countl <= 32'hdeadf00d;
      end
    else if (axilite_ar_rdy & axilite_ar_vld)
      begin
	axi_rdata <= 32'hdeadf00d;
	if (axi_raddr == ADDR_AFU_COUNTER0)
	  axi_rdata <= afu_counter0;
	if (axi_raddr == ADDR_AFU_COUNTER1)
	  axi_rdata <= afu_counter1;
	if (axi_raddr == ADDR_AFU_COUNTER2)
	  axi_rdata <= afu_counter2;
	if (axi_raddr == ADDR_AFU_COUNTER3)
	  axi_rdata <= afu_counter3;
	if (axi_raddr == ADDR_AFU_COUNTER4)
	  axi_rdata <= afu_counter4;
	if (axi_raddr == ADDR_AFU_COUNTER5)
	  axi_rdata <= afu_counter5;
	if (axi_raddr == ADDR_AFU_COUNTER6)
	  axi_rdata <= afu_counter6;
	if (axi_raddr == ADDR_AFU_COUNTER7)
	  axi_rdata <= afu_counter7;
	if (axi_raddr == ADDR_AFU_COUNTER8)
	  begin
	    axi_rdata <= afu_counter8[31:0];
	  end
	if (axi_raddr == ADDR_AFU_COUNTER9)
	  begin
	    axi_rdata <= afu_counter9[31:0];
	  end

	if (axi_raddr == ADDR_AFU_SCRATCHPAD)
	  axi_rdata <= afu_scratchpad;

	if (axi_raddr == ADDR_AFU_PCI2SBU_PUSHBACKH)
	  begin
	    axi_rdata <= {16'b0, afu_pci2sbu_pushback[47:32]};
	    // the lower part is sampled when reading the higher part, to preserve the lower part for next axilite read
	    afu_pci2sbu_pushbackl <= afu_pci2sbu_pushback[31:0];
	  end

	if (axi_raddr == ADDR_AFU_PCI2SBU_PUSHBACKL)
	  begin
	    axi_rdata <= afu_pci2sbu_pushbackl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_SBU2PCI_PUSHBACKH)
	  begin
	    axi_rdata <= {16'b0, afu_sbu2pci_pushback[47:32]};
	    // the lower part is sampled when reading the higher part, to preserve the lower part for next axilite read
	    afu_sbu2pci_pushbackl <= afu_sbu2pci_pushback[31:0];
	  end
	if (axi_raddr == ADDR_AFU_SBU2PCI_PUSHBACKL)
	  begin
	    axi_rdata <= afu_sbu2pci_pushbackl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_RECEIVEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_received_requests_count[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_received_requests_countl <= total_hmac_received_requests_count[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_RECEIVEDL)
	  begin
	    axi_rdata <= total_hmac_received_requests_countl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_MATCHH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_requests_match_count[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_requests_match_countl <= total_hmac_requests_match_count[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_MATCHL)
	  begin
	    axi_rdata <= total_hmac_requests_match_countl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_NOMATCHH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_requests_nomatch_count[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_requests_nomatch_countl <= total_hmac_requests_nomatch_count[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_NOMATCHL)
	  begin
	    axi_rdata <= total_hmac_requests_nomatch_countl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_FORWARDEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_forwarded_requests_count[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_forwarded_requests_countl <= total_hmac_forwarded_requests_count[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_FORWARDEDL)
	  begin
	    axi_rdata <= total_hmac_forwarded_requests_countl[31:0];
	  end
	
	if (axi_raddr == ADDR_AFU_HMAC_Q0_DATAH)
	  begin
	    axi_rdata <= {total_hmac_queue0_received_data[63:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue0_received_datal <= total_hmac_queue0_received_data[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q0_DATAL)
	  begin
	    axi_rdata <= total_hmac_queue0_received_datal[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_Q0_RECEIVEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_queue0_received_requests[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue0_received_requestsl <= total_hmac_queue0_received_requests[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q0_RECEIVEDL)
	  begin
	    axi_rdata <= total_hmac_queue0_received_requestsl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_Q0_DROPPEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_queue0_dropped_requests[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue0_dropped_requestsl <= total_hmac_queue0_dropped_requests[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q0_DROPPEDL)
	  begin
	    axi_rdata <= total_hmac_queue0_dropped_requestsl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_Q1_DATAH)
	  begin
	    axi_rdata <= {total_hmac_queue1_received_data[63:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue1_received_datal <= total_hmac_queue1_received_data[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q1_DATAL)
	  begin
	    axi_rdata <= total_hmac_queue1_received_datal[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_Q1_RECEIVEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_queue1_received_requests[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue1_received_requestsl <= total_hmac_queue1_received_requests[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q1_RECEIVEDL)
	  begin
	    axi_rdata <= total_hmac_queue1_received_requestsl[31:0];
	  end

	if (axi_raddr == ADDR_AFU_HMAC_Q1_DROPPEDH)
	  begin
	    axi_rdata <= {16'b0, total_hmac_queue1_dropped_requests[47:32]};
	    // the lower part is sampled when reading the hgher part, to preserve the lower part for next axilite read
	    total_hmac_queue1_dropped_requestsl <= total_hmac_queue1_dropped_requests[31:0];
	  end
	if (axi_raddr == ADDR_AFU_HMAC_Q1_DROPPEDL)
	  begin
	    axi_rdata <= total_hmac_queue1_dropped_requestsl[31:0];
	  end
	
	// Histograms read:
	if ((axi_raddr >= ADDR_AFU_HISTO0_BASE) && (axi_raddr < ADDR_AFU_HISTO1_BASE))
	  // Reading pci2sbu_packets_size histogram
	  axi_rdata <= hist_pci2sbu_packet_dout;

	if ((axi_raddr >= ADDR_AFU_HISTO1_BASE) && (axi_raddr < ADDR_AFU_HISTO2_BASE))
	  // Reading pci2sbu_packets_size histogram
	  axi_rdata <= hist_pci2sbu_eompacket_dout;

	if ((axi_raddr >= ADDR_AFU_HISTO2_BASE) && (axi_raddr < ADDR_AFU_HISTO3_BASE))
	  // Reading pci2sbu_packets_size histogram
	  axi_rdata <= hist_pci2sbu_message_dout;

	if ((axi_raddr >= ADDR_AFU_HISTO3_BASE) && (axi_raddr < ADDR_AFU_HISTO4_BASE))
	  // Reading pci2sbu_packets_size histogram
	  axi_rdata <= hist_sbu2pci_response_dout;

	// PCI sample buffers read:
	if ((axi_raddr >= ADDR_PCI2SBU_SAMPLE_BASE) && (axi_raddr < ADDR_PCI2SBU_SAMPLE_END))
	  axi_rdata <= pci2sbu_sample_rdata;
	if ((axi_raddr >= ADDR_SBU2PCI_SAMPLE_BASE) && (axi_raddr < ADDR_SBU2PCI_SAMPLE_END))
	  axi_rdata <= sbu2pci_sample_rdata;
	if ((axi_raddr >= ADDR_MODULE_IN_SAMPLE_BASE) && (axi_raddr < ADDR_MODULE_IN_SAMPLE_END))
	  axi_rdata <= module_in_sample_rdata;
	if ((axi_raddr >= ADDR_INPUT_BUFFER_SAMPLE_BASE) && (axi_raddr < ADDR_INPUT_BUFFER_SAMPLE_END))
	  axi_rdata <= input_buffer_sample_rdata;

	if (axi_raddr == ADDR_TIMESTAMPH)
	  begin
	    axi_rdata <= {16'h0000, timestamp[47:32]};
	    timestampl <= timestamp[31:0];
	  end
	if (axi_raddr == ADDR_TIMESTAMPL)
	  axi_rdata <= timestampl;
      end

  end // always @ (posedge clk)
  
  // axilite write fsm
  assign axilite_aw_rdy = (axi_wstate == WRIDLE);
  assign axilite_w_rdy  = (axi_wstate == WRDATA);
  assign axilite_b_resp = 2'b00;  // OKAY
  assign axilite_b_vld  = (axi_wstate == WRRESP);
  assign axi_aw_hs      = axilite_aw_vld & axilite_aw_rdy;
  assign axi_w_hs       = axilite_w_vld  & axilite_w_rdy;
  
  // wstate
  always @(posedge clk) begin
    if (reset)
      axi_wstate <= WRIDLE;
    else
      axi_wstate <= axi_wnext;
  end
  
  // wnext
  always @(*) begin
    case (axi_wstate)
      WRIDLE:
        if (axilite_aw_vld)
          axi_wnext = WRDATA;
        else
          axi_wnext = WRIDLE;
      WRDATA:
        if (axilite_w_vld)
          axi_wnext = WRRESP;
        else
          axi_wnext = WRDATA;

      WRRESP:
        if (axilite_b_rdy)
          axi_wnext = WRIDLE;
        else
          axi_wnext = WRRESP;
      default:
        axi_wnext = WRIDLE;
    endcase
  end
  
  // waddr
  always @(posedge clk) begin
    if (axi_aw_hs)
      axi_waddr <= {1'b0, axilite_aw_addr[AXILITE_AFU_ADDR_WIDTH-2 : 0]}; // address MSB is forced to 0, to enfoce a positive integer  
  end
  
  // writing to AFU ctrl registers
  always @(posedge clk) begin
    if (reset) begin
      afu_ctrl0 <= 32'h3ff30000;  // Default:  All zuc modules are enabled,
                                  //          Input buffer to HMAC modules round-robin arbitration, input_buffer watermark = 0
                                  //          sbu2pci.channel_id indication is enabled 
                                  //          EOM is forced 
                                  //          No AFU/Modules bypass
                                  //          Queues priority disabled
                                  //          Zero input_buffer watermark
      afu_ctrl1 <= 32'b0;         // Default: fifox_in high watermark set to 0 (== no watermark). No headers metadata
      afu_ctrl2 <= 32'h0000ffff;  // Default: message id ordering is disabled to all channels. Sampling trigger disabled
      afu_ctrl3 <= 32'h00000000;  // Default
      afu_ctrl4 <= 32'h00000000;  // Default: All histograms are disabled
      afu_ctrl5 <= 32'h00000000;  // Default: pci2sbu & sbu2pci axi4stream_data sampling is disabled
      afu_ctrl8 <= 32'h00000000;  // Default: Sampling trigger
      afu_ctrl9 <= 32'h00000000;  // Default: Sampling trigger
      afu_reset <= 1'b0;
      afu_reset_count <= 8'h00;
      afu_ctrl0_wr <= 1'b0;
      afu_ctrl1_wr <= 1'b0;
      afu_ctrl2_wr <= 1'b0;
      afu_ctrl3_wr <= 1'b0;
      afu_ctrl4_wr <= 1'b0;
      afu_ctrl5_wr <= 1'b0;
      afu_scratchpad <= 32'hdeadf00d;
      pci_sample_reset <= 1'b0;
      pci_sample_reset_count <= 8'h00;
      kbuffer_write <= 1'b0;
    end
    else begin
      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL0)
	begin
	  afu_ctrl0[31:0] <= axilite_w_data[31:0];
	  afu_ctrl0_wr <= 1'b1; // indication that afu_ctrl0 been written. Asserted to 1 clock !!
	  if (axilite_w_data[31])
	    begin
	      afu_reset <= 1'b1;
	      afu_reset_count <= AFU_SOFT_RESET_WIDTH;
	    end
	end
      else
	  afu_ctrl0_wr <= 1'b0;

      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL1)
	begin
	  afu_ctrl1[31:0] <= axilite_w_data[31:0];
	  afu_ctrl1_wr <= 1'b1; // indication to zuc_modules that fifox_in watermark has been written. Asserted to 1 clock !!
	end
      else
	  afu_ctrl1_wr <= 1'b0;
	
      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL2)
	begin
	  afu_ctrl2[31:0] <= axilite_w_data[31:0];
	  afu_ctrl2_wr <= 1'b1; // indication that message ordering mask has been written. Asserted to 1 clock !!
	end
      else
	afu_ctrl2_wr <= 1'b0;
      
      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL3)
	begin
	  afu_ctrl3[31:0] <= axilite_w_data[31:0];
	  clear_backpressure_counters <= axilite_w_data[0];
	  clear_hmac_message_counters <= axilite_w_data[1];
	  afu_ctrl3_wr <= 1'b1;
	end
      else
	begin
	  clear_backpressure_counters <= 1'b0;
	  clear_hmac_message_counters <= 1'b0;
	  afu_ctrl3_wr <= 1'b0;
	end

      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL4)
	begin
	  afu_ctrl4[31:0] <= axilite_w_data[31:0];
	  afu_ctrl4_wr <= 1'b1; // indication that histo operation has been written. Asserted to 1 clock !!
	  if (axilite_w_data[16])
	    begin
	      pci_sample_reset <= 1'b1;
	      pci_sample_reset_count <= PCI_SAMPLE_SOFT_RESET_WIDTH;
	    end
	end
      else
	afu_ctrl4_wr <= 1'b0;

      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL5)
	begin
	  afu_ctrl5[31:0] <= axilite_w_data[31:0];
	  afu_ctrl5_wr <= 1'b1; // indication that pci sampling operation has been written. Asserted to 1 clock !!
	end
      else
	afu_ctrl5_wr <= 1'b0;
      
      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL8)
	begin
	  afu_ctrl8[31:0] <= axilite_w_data[31:0];
	end
      
      if (axi_w_hs && axi_waddr == ADDR_AFU_CTRL9)
	begin
	  afu_ctrl9[31:0] <= axilite_w_data[31:0];
	end
      
      if (axi_w_hs && axi_waddr == ADDR_AFU_SCRATCHPAD)
	afu_scratchpad[31:0] <= axilite_w_data[31:0];

      if (axi_w_hs && (axi_waddr >= ADDR_HMAC_KEYS_BASE && axi_waddr < ADDR_HMAC_KEYS_END))
	begin
	  kbuffer_write <= 1'b1;
	end
      else 
	  kbuffer_write <= 1'b0;

      // hmac_afu reset:
      if (afu_reset)
	begin
	  if (afu_reset_count > 0)
	    // afu_reset is asserted to AFU_SOFT_RESET_WIDTH zuc_clocks
	    afu_reset_count <= afu_reset_count - 8'h01;
	  else
	    afu_reset <= 1'b0;
	end

      // pci_sample reset:
      if (pci_sample_reset)
	begin
	  if (pci_sample_reset_count > 0)
	    // pci_sample_reset is asserted to PCI_SAMPLE_SOFT_RESET_WIDTH zuc_clocks, 
	    // to accomodate for the synchronizers between the AFU FLD domains
	    pci_sample_reset_count <= pci_sample_reset_count - 8'h01;
	  else
	    pci_sample_reset <= 1'b0;
	end
    end
  end

  // hmac test mode
  wire [2:0] hmac_test_mode;
  wire 	     hmac_round_robin_arb;
  assign     hmac_test_mode = afu_ctrl2[31:29];
  assign     hmac_round_robin_arb = (afu_ctrl0[17:16] == 2'b11) ? 1'b1 : 1'b0;
  
  
  // Modules fifo_in watermark
  wire [4:0]     module_fifo_in_watermark[NUM_MODULES-1:0];
  wire 		 module_fifo_in_watermark_met[NUM_MODULES-1:0];

  // fifo_in watermark is active only in a round_robin fifo_in arbitration mode (hmac_round_robin_arb) 
  // non-zero watermark while in other fifo_in load_based arbitration mode, actually disrupts the arbitration scheme. 
  assign   module_fifo_in_watermark[0] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[3:0]} : 4'h0; 
  assign   module_fifo_in_watermark[1] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[7:4]} : 4'h0;
  assign   module_fifo_in_watermark[2] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[11:8]} : 4'h0;
  assign   module_fifo_in_watermark[3] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[15:12]} : 4'h0;
  assign   module_fifo_in_watermark[4] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[19:16]} : 4'h0;
  assign   module_fifo_in_watermark[5] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[23:20]} : 4'h0;
  assign   module_fifo_in_watermark[6] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[27:24]} : 4'h0;
  assign   module_fifo_in_watermark[7] = (hmac_round_robin_arb) ? {afu_ctrl1_wr, afu_ctrl1[31:28]} : 4'h0;

  wire   module_in_test_mode;
  wire sbu2pci_channel_id_enable;
  reg  sbu2pci_channel_id;

  // hmac: module_test_mode is not used
  // assign module_in_test_mode = afu_ctrl0[29];
  assign module_in_test_mode = 1'b0;
  assign sbu2pci_channel_id_enable = afu_ctrl0[29];


//===================================================================================================================================
// zuc AFU
//===================================================================================================================================
//
// AFU Input buffer: Message buffering scheme:
// Input buffer is physically split to 16 queues, with dedicated chidx_head/chidx_tail pointers (wrapped around the queue size)
// After last input message in channel x is complete (EOM has been observed), ... 
//    chidx_head points to beginning of the oldest received message in channel ID x
//    chidx_tail points to next free line to be written with next incoming message
//    chidx_message_size specifies the total number of bytes in latter received message, which is then stored the the message header
//
// A message buffer begins with one header 512b line, followed by the rest of the message data
//    Once a message input is complete (EOM arrived), a 512b header is prepended to the message data, 
//    (written to the beginning of current message buffer) including message info: USER, Channel ID, Message size, EOM Indicatoin, etc
//
// The Message Buffering Scheme state machine also implements the interaction with pci2sbu input port.
//    Input_buffer space availability per chidx is calculated per channel:
//       chidx_buffer_full = chidx_tail - chidx_head
// upon arrival of message data line from pci2sbu:
// 1. If (pci2sbu_axi4stream_vld & chidx_eom) // start_of_new_message
//       chidx_eom = '0;
//       Sample relevant TUSER info at first message line
//          {chidx, chidx_user} = pci2sbu_axi4stream_tuser...  
//       First message line in input_buffer is cleared, to avoid false header indication
//       This line will be later updated with correct header, once the whole message has been received (step #7 below)
//       For this purpose, a copy of chidx_tail (which currently points to the message start) is saved
//          chidx_message_start = chidx_tail
//          input_buffer(chidx_tail++) <- 0  
//          chidx_message_size = 0;
//    endif
// 2. input_buffer(chidx_tail++) <- pci2sbu_axi4stream_tdata[masked by tkeep])
// 4. Update chidx_message_size (masked by tkeep)
// 5. assign chidx_header = chidx, chidx_message_size, chidx_user // continuously update chidx_header line
// 6. Repeat 1..5 until EOM  
//
// Upon arrival of EOM (line containing EOM already stored at step 2 above):
// 7. Mark end_of_message
//    chidx_eom = '1;
//    Store the message header to first line in latter stored message:
//    Implementation note: This technique may impose a critical path of read after write.
//        Pay attention to force at least one clock delay for read_after_write operation
//    input_buffer(chidx_message_start) <- chidx_header
// 8. chidx_in_message_count++;  // Holds number of complete messages in chidx input buffer. Used in Message Read Scheme. See below
// 9. Repeat from 1 // wait for next line from pci2sbu

  // AFU status:
  wire 	 [31:0] afu_status;
  wire 	 [15:0] chid_in_buffers_not_empty;
  
  assign chid_in_buffers_not_empty = {chid_in_buffer_not_empty[15],chid_in_buffer_not_empty[14],chid_in_buffer_not_empty[13],chid_in_buffer_not_empty[12],
				  chid_in_buffer_not_empty[11],chid_in_buffer_not_empty[10], chid_in_buffer_not_empty[9], chid_in_buffer_not_empty[8],
				  chid_in_buffer_not_empty[7], chid_in_buffer_not_empty[6], chid_in_buffer_not_empty[5], chid_in_buffer_not_empty[4],
				  chid_in_buffer_not_empty[3], chid_in_buffer_not_empty[2], chid_in_buffer_not_empty[1], chid_in_buffer_not_empty[0]};
  
  assign afu_status[23:20] =  current_in_chid;
  assign afu_status[19] = trigger_is_met;
  assign afu_status[18:16] = {packet_in_nstate != 4'h0, message_out_nstate != 4'h0, sbu2pci_out_nstate != 4'h0};
  assign afu_status[15:8] = {zuc_out_stats[7][3:0] != 4'h0, zuc_out_stats[6][3:0] != 4'h0, zuc_out_stats[5][3:0] != 4'h0, zuc_out_stats[4][3:0] != 4'h0,
                             zuc_out_stats[3][3:0] != 4'h0, zuc_out_stats[2][3:0] != 4'h0, zuc_out_stats[1][3:0] != 4'h0, zuc_out_stats[0][3:0] != 4'h0};
  assign afu_status[5] =  current_in_buffer_full;
  assign afu_status[4] = (chid_in_buffers_not_empty == 16'h0000) ? 1'b0 : 1'b1;
  assign afu_status[3] = (messages_validD == 16'h0000) ? 1'b0 : 1'b1;
  assign afu_status[2] = (fifo3_out_message_count == 8'h000 && fifo2_out_message_count == 8'h000 &&
			  fifo1_out_message_count == 8'h000 && fifo0_out_message_count == 8'h000 &&
			  fifo7_out_message_count == 8'h000 && fifo6_out_message_count == 8'h000 &&
			  fifo5_out_message_count == 8'h000 && fifo4_out_message_count == 8'h000) ? 1'b0 : 1'b1;
  assign afu_status[1] = (fifo_out_message_valid_regD == 8'h00) ? 1'b0 : 1'b1;
  assign afu_status[0] = (afu_status[18:8] == 11'h000 && afu_status[4:1] == 4'h00) ? 1'b0 : 1'b1;

// hmac_afu status & statistis registers
  always @(posedge clk) begin
    if (reset || afu_reset)
      begin
	afu_counter0 <= 32'h00000000;
	afu_counter1 <= 32'h00000000;
	afu_counter2 <= 32'h00000000;
	afu_counter3 <= 32'h00000000;
	afu_counter4 <= 32'h00000000;
	afu_counter5 <= 32'h00000000;
	afu_counter6 <= 32'h00000000;
	afu_counter7 <= 32'h00000000;
	afu_counter8 <= 33'h000000000;
	afu_counter9 <= 33'h000000000;
	timestamp <= 48'h000000000000;
	afu_pci2sbu_pushback <= 48'h000000000000;
	afu_sbu2pci_pushback <= 48'h000000000000;
      end
    else
      begin
	// Free running counter, used to timestamp afu samples.
	// Count is started immediately after reset (either hard or soft reset).
	// Count is wrapped around 2^48
	// Max time duration (@ 125 Mhz afu clock): 2^48 / 125 * 10^6 = 2252800 sec = 625 hours 
	timestamp <= timestamp + 1'b1;

	// counter0
	// [31:16]  - per channel, data_flits count > 0, in input buffer. chidx at bit [x]
	// [15:0]   - per channel, message count > 0, in input buffer. chidx at bit [x]
	//	afu_counter0 <= {8'h00, fifo_in_free_regD, messages_validD};
	afu_counter0 <= {chid_in_buffers_not_empty, messages_validD};

	// counter1: AFU status
	// [31:24]   Reserved
	// [23:20]   Currently received channel ID
	//    [19]   Reserved
	// [18:16]   Either of {packet_in_nstate, message_out_nstate, sbu2pci_out_nstate} SMs is busy
	//  [15:8]   Either of zuc_modules SMs is busy
	//   [7:6]   Reserved
	//     [5]   Input buffer of currently received chid is full
	//     [4]   There are data flits in input buffer, in either of the channels
	//     [3]   There are pending message requests in input buffer, in either of the channels
	//     [2]   Pending responses count in fifox_out is not zero
	//     [1]   There are Pending responses in fifox_out
	//     [0]   AFU is busy
	afu_counter1 <= {8'h00, afu_status[23:20], afu_status[19:8], 2'b00, afu_status[5:0]};

	// counter2
	// hmac:  total received hmac requests, counting received packets from pci2sbu
//	afu_counter2 <= total_hmac_received_requests_count;

	// counter3
	// hmac: total requests packets matching the associated sig. Counting forwarded packets from pkts_fwd fifo to fifox_out fifo
//	afu_counter3 <= total_hmac_requests_match_count;

	// counter4
	// hmac: total requests packets NOT matching the associated sig. Counting dropped packets from pkts_fwd fifo.
//	afu_counter4 <= total_hmac_requests_nomatch_count;

	// counter5
	// hmac: total forwarded hmac packets, counting sent packets to sbu2pci
//	afu_counter5 <= total_hmac_forwarded_requests_count;

	// counter6 - afu state machines
	// [31:16]  - Reserved
	// [15:2]   - Reserved
	// [11:8]   - zuc_modules fifox_out to sbu2pci SM
	// [7:4]    - input_buffer to zuc_modules fifox_in SM
	// [3:0]    - pci2sbu to input_buffer SM
	afu_counter6 <= {20'h00000, sbu2pci_out_nstate, message_out_nstate, packet_in_nstate};

	// counter7 - zuc modules state machines
	// [31:28]  - zuc module7 SM
	// [27:24]  - zuc module6 SM
	// [23:20]  - zuc module5 SM
	// [19:16]  - zuc module4 SM
	// [15:12]  - zuc module3 SM
	// [11:8]   - zuc module2 SM
	// [7:4]    - zuc module1 SM
	// [3:0]    - zuc module0 SM
	afu_counter7 <= {zuc_out_stats[7][3:0], zuc_out_stats[6][3:0], zuc_out_stats[5][3:0], zuc_out_stats[4][3:0],
			 zuc_out_stats[3][3:0], zuc_out_stats[2][3:0], zuc_out_stats[1][3:0], zuc_out_stats[0][3:0]};

	if (clear_backpressure_counters) 
	  // The counter is cleared at reset or via afu_ctrl3
	  begin
	    afu_pci2sbu_pushback <= 48'b0;
	  end
	else if (pci2sbu_axi4stream_vld && pci2sbu_pushback)
	  // pci is pushed back by afu
	  begin
	    if (afu_pci2sbu_pushback < 49'h0ffffffffffff)
	      // Count is saturated at max unsigned 48bit value.
	      begin
		afu_pci2sbu_pushback <= afu_pci2sbu_pushback + 1;
	      end
	  end

	if (clear_backpressure_counters) 
	  // The counter is cleared at reset or via afu_ctrl3
	  begin
	    afu_sbu2pci_pushback <= 48'b0;
	  end
	else if (sbu2pci_pushback)
	  // afu is pushed back by pci
	  begin
	    if (afu_sbu2pci_pushback < 49'h0ffffffffffff)
	      // Count is saturated at max unsigned 32bit value.
	      begin
		afu_sbu2pci_pushback <= afu_sbu2pci_pushback + 1;
	      end
	  end
      end
  end
    
  reg         pci2sbu_ready;
  reg 	      sbu2pci_valid;
  
  reg 	      current_in_eom;
  reg 	      current_in_pkt_type;
  reg [12:0]  current_in_headD;
  reg [12:0]  current_in_head;
  
  reg 	      current_in_somD;
  reg 	      current_in_som;
  reg 	      chid0_in_som;
  reg 	      chid1_in_som;
  reg 	      chid2_in_som;
  reg 	      chid3_in_som;
  reg 	      chid4_in_som;
  reg 	      chid5_in_som;
  reg 	      chid6_in_som;
  reg 	      chid7_in_som;
  reg 	      chid8_in_som;
  reg 	      chid9_in_som;
  reg 	      chid10_in_som;
  reg 	      chid11_in_som;
  reg 	      chid12_in_som;
  reg 	      chid13_in_som;
  reg 	      chid14_in_som;
  reg 	      chid15_in_som;

  reg 	      current_out_eom;
  reg 	      current_out_som;
  reg 	      chid0_out_som;
  reg 	      chid1_out_som;
  reg 	      chid2_out_som;
  reg 	      chid3_out_som;
  reg 	      chid4_out_som;
  reg 	      chid5_out_som;
  reg 	      chid6_out_som;
  reg 	      chid7_out_som;
  reg 	      chid8_out_som;
  reg 	      chid9_out_som;
  reg 	      chid10_out_som;
  reg 	      chid11_out_som;
  reg 	      chid12_out_som;
  reg 	      chid13_out_som;
  reg 	      chid14_out_som;
  reg 	      chid15_out_som;

  reg [12:0]  current_in_tailD;
  reg [12:0]  current_in_tail;
  reg 	      current_in_tail_incremented;
  reg [12:0]  chid0_in_tail;
  reg [12:0]  chid1_in_tail;
  reg [12:0]  chid2_in_tail;
  reg [12:0]  chid3_in_tail;
  reg [12:0]  chid4_in_tail;
  reg [12:0]  chid5_in_tail;
  reg [12:0]  chid6_in_tail;
  reg [12:0]  chid7_in_tail;
  reg [12:0]  chid8_in_tail;
  reg [12:0]  chid9_in_tail;
  reg [12:0]  chid10_in_tail;
  reg [12:0]  chid11_in_tail;
  reg [12:0]  chid12_in_tail;
  reg [12:0]  chid13_in_tail;
  reg [12:0]  chid14_in_tail;
  reg [12:0]  chid15_in_tail;
  
  reg [12:0]  current_out_headD;
  reg [12:0]  current_out_head;
  reg 	      current_out_head_incremented;
  reg [12:0]  chid0_out_head;
  reg [12:0]  chid1_out_head;
  reg [12:0]  chid2_out_head;
  reg [12:0]  chid3_out_head;
  reg [12:0]  chid4_out_head;
  reg [12:0]  chid5_out_head;
  reg [12:0]  chid6_out_head;
  reg [12:0]  chid7_out_head;
  reg [12:0]  chid8_out_head;
  reg [12:0]  chid9_out_head;
  reg [12:0]  chid10_out_head;
  reg [12:0]  chid11_out_head;
  reg [12:0]  chid12_out_head;
  reg [12:0]  chid13_out_head;
  reg [12:0]  chid14_out_head;
  reg [12:0]  chid15_out_head;


  reg [11:0]   current_in_message_idD;
  reg [11:0]   current_in_message_id;
  reg [11:0]   chid0_in_message_id;
  reg [11:0]   chid1_in_message_id;
  reg [11:0]   chid2_in_message_id;
  reg [11:0]   chid3_in_message_id;
  reg [11:0]   chid4_in_message_id;
  reg [11:0]   chid5_in_message_id;
  reg [11:0]   chid6_in_message_id;
  reg [11:0]   chid7_in_message_id;
  reg [11:0]   chid8_in_message_id;
  reg [11:0]   chid9_in_message_id;
  reg [11:0]   chid10_in_message_id;
  reg [11:0]   chid11_in_message_id;
  reg [11:0]   chid12_in_message_id;
  reg [11:0]   chid13_in_message_id;
  reg [11:0]   chid14_in_message_id;
  reg [11:0]   chid15_in_message_id;

  reg [9:0]   chid_in_message_count[NUM_CHANNELS-1:0];

  reg [31:0]   total_chid0_in_message_count;
  reg [31:0]   total_chid1_in_message_count;
  reg [31:0]   total_chid2_in_message_count;
  reg [31:0]   total_chid3_in_message_count;
  reg [31:0]   total_chid4_in_message_count;
  reg [31:0]   total_chid5_in_message_count;
  reg [31:0]   total_chid6_in_message_count;
  reg [31:0]   total_chid7_in_message_count;
  reg [31:0]   total_chid8_in_message_count;
  reg [31:0]   total_chid9_in_message_count;
  reg [31:0]   total_chid10_in_message_count;
  reg [31:0]   total_chid11_in_message_count;
  reg [31:0]   total_chid12_in_message_count;
  reg [31:0]   total_chid13_in_message_count;
  reg [31:0]   total_chid14_in_message_count;
  reg [31:0]   total_chid15_in_message_count;

  reg [9:0]   current_in_message_linesD; // Number of received pci2sbu_tdata lines. Max value: 9KB/mesage ==> ('d144 == 'h90) x 512b lines
  reg [9:0]   current_in_message_lines;
  reg [9:0]   chid0_in_message_lines;
  reg [9:0]   chid1_in_message_lines;
  reg [9:0]   chid2_in_message_lines;
  reg [9:0]   chid3_in_message_lines;
  reg [9:0]   chid4_in_message_lines;
  reg [9:0]   chid5_in_message_lines;
  reg [9:0]   chid6_in_message_lines;
  reg [9:0]   chid7_in_message_lines;
  reg [9:0]   chid8_in_message_lines;
  reg [9:0]   chid9_in_message_lines;
  reg [9:0]   chid10_in_message_lines;
  reg [9:0]   chid11_in_message_lines;
  reg [9:0]   chid12_in_message_lines;
  reg [9:0]   chid13_in_message_lines;
  reg [9:0]   chid14_in_message_lines;
  reg [9:0]   chid15_in_message_lines;

  reg [12:0]   current_in_message_startD; // start address of currently received  message in input buffer
  reg [12:0]   current_in_message_start;
  reg [12:0]   chid0_in_message_start;
  reg [12:0]   chid1_in_message_start;
  reg [12:0]   chid2_in_message_start;
  reg [12:0]   chid3_in_message_start;
  reg [12:0]   chid4_in_message_start;
  reg [12:0]   chid5_in_message_start;
  reg [12:0]   chid6_in_message_start;
  reg [12:0]   chid7_in_message_start;
  reg [12:0]   chid8_in_message_start;
  reg [12:0]   chid9_in_message_start;
  reg [12:0]   chid10_in_message_start;
  reg [12:0]   chid11_in_message_start;
  reg [12:0]   chid12_in_message_start;
  reg [12:0]   chid13_in_message_start;
  reg [12:0]   chid14_in_message_start;
  reg [12:0]   chid15_in_message_start;

  reg [15:0]   current_in_message_sizeD; // Message size, as indicated in message_header[495:480]
  reg [15:0]   current_in_message_size;
  reg [15:0]   chid0_in_message_size;
  reg [15:0]   chid1_in_message_size;
  reg [15:0]   chid2_in_message_size;
  reg [15:0]   chid3_in_message_size;
  reg [15:0]   chid4_in_message_size;
  reg [15:0]   chid5_in_message_size;
  reg [15:0]   chid6_in_message_size;
  reg [15:0]   chid7_in_message_size;
  reg [15:0]   chid8_in_message_size;
  reg [15:0]   chid9_in_message_size;
  reg [15:0]   chid10_in_message_size;
  reg [15:0]   chid11_in_message_size;
  reg [15:0]   chid12_in_message_size;
  reg [15:0]   chid13_in_message_size;
  reg [15:0]   chid14_in_message_size;
  reg [15:0]   chid15_in_message_size;

  reg [10:0]   current_in_buffer_data_countD;
  wire [10:0]  current_in_buffer_free_data_count;
  reg [10:0]   chid_in_buffer_data_count[NUM_CHANNELS-1:0];
  reg 	       chid_in_buffer_not_empty[NUM_CHANNELS-1:0];

  reg [7:0]   current_in_opcode; // Message opcode
  reg [7:0]   current_in_opcodeD; // Message opcode
  reg [7:0]   chid0_in_opcode;
  reg [7:0]   chid1_in_opcode;
  reg [7:0]   chid2_in_opcode;
  reg [7:0]   chid3_in_opcode;
  reg [7:0]   chid4_in_opcode;
  reg [7:0]   chid5_in_opcode;
  reg [7:0]   chid6_in_opcode;
  reg [7:0]   chid7_in_opcode;
  reg [7:0]   chid8_in_opcode;
  reg [7:0]   chid9_in_opcode;
  reg [7:0]   chid10_in_opcode;
  reg [7:0]   chid11_in_opcode;
  reg [7:0]   chid12_in_opcode;
  reg [7:0]   chid13_in_opcode;
  reg [7:0]   chid14_in_opcode;
  reg [7:0]   chid15_in_opcode;
  
  reg [15:0]   input_buffer_watermark_met; // per channel indication: (input_buffer_watermark_met[x]==1) ==> watermark has been met for chidx
  reg [9:0]    input_buffer_watermark;
  reg [12:0]   current_in_message_status_update;
  reg [12:0]   current_in_message_status_adrs;
  reg [7:0]    current_in_message_status; // Incoming message status
  reg [7:0]    current_fifo_in_message_cmd;
  reg 	       current_fifo_in_message_ok;
  reg 	       current_fifo_in_message_type;
  reg 	       current_fifo_in_header;
  reg 	       current_fifo_in_eth_header;
  
  reg [2:0]    current_fifo_in_id;
  wire 	       current_in_zuccmd;
  wire 	       current_in_illegal_cmd;
  reg 	       current_in_message_ok;
  reg 	       current_in_mask_message_id;
//  reg [3:0]    current_in_context;
  reg [3:0]    current_in_chid;
  reg [3:0]    current_out_chid;
  reg [4:0]    current_out_chid_delta;
  reg [3:0]    current_out_context;
  reg 	       update_channel_in_regs;
  reg 	       update_channel_out_regs;
  reg 	       update_fifo_in_regs;
  
  reg [3:0]    message_out_nstate;
  reg 	       input_buffer_rden;
  wire 	       current_fifo_in_message_eom;
  reg [47:0]   current_fifo_in_message_metadata;
  reg [15:0]   current_fifo_in_message_size;
  reg [15:0]   current_out_message_size;
  reg [15:0]   current_fifo_in_message_words;
  reg [10:0]   current_fifo_in_message_lines;
  reg [10:0]   current_fifo_in_message_flits;
  reg [7:0]    current_fifo_in_message_status;
  reg [15:0]   current_fifo_in_steering_tag;
  
  wire	       fifo_in_ready[NUM_MODULES-1:0];
//  wire	       fifo_in_ready[7:0];
  reg	       module_in_valid;
  wire	       fifo_out_valid[NUM_MODULES-1:0];
//  wire	       fifo_out_valid[7:0];
  reg 	       message_afubypass_pending;
//  reg 	       message_data_valid;
  reg 	       message_afubypass_valid;
  
  reg 	       fifo_in_readyD;
  reg 	       fifo_in_readyQ;
  reg 	       input_buffer_write;
  reg 	       input_buffer_meta_write;
  reg 	       input_buffer_wren;
  reg 	       write_eth_header;
  reg 	       packet_in_progress;
  reg 	       current_in_tfirst;      // hmac: "first packet flit" indicator
  reg [3:0]    packet_in_nstate;
  reg [511:0]  current_in_eth_header; // hmac: The complete eth header is considered
  
  wire 	       message_out_validD;
  wire [15:0]  messages_validD;
  wire [31:0]  messages_valid_doubleregD;
  reg 	       fifo_in_full[NUM_MODULES-1:0];
//  reg 	       fifo_in_full[7:0];
  wire 	       fifo_in_free_regD0;
  wire 	       fifo_in_free_regD1;
  wire 	       fifo_in_free_regD2;
  wire 	       fifo_in_free_regD3;
  wire 	       fifo_in_free_regD4;
  wire 	       fifo_in_free_regD5;
  wire 	       fifo_in_free_regD6;
  wire 	       fifo_in_free_regD7;
  wire [7:0]   fifo_in_free_regD;
  wire [15:0]   fifo_in_free_doubleregD;
  reg [3:0]    fifo_in_id_delta;
  wire 	       zuc_module0_enable;
  wire 	       zuc_module1_enable;
  wire 	       zuc_module2_enable;
  wire 	       zuc_module3_enable;
  wire 	       zuc_module4_enable;
  wire 	       zuc_module5_enable;
  wire 	       zuc_module6_enable;
  wire 	       zuc_module7_enable;
  
  wire [515:0] module_in_data;
  
  wire [5:0]   next_out_chid;
  wire [15:0]  fifo7_in_free_count;
  wire [15:0]  fifo6_in_free_count;
  wire [15:0]  fifo5_in_free_count;
  wire [15:0]  fifo4_in_free_count;
  wire [15:0]  fifo3_in_free_count;
  wire [15:0]  fifo2_in_free_count;
  wire [15:0]  fifo1_in_free_count;
  wire [15:0]  fifo0_in_free_count;
  wire [3:0]   next_fifo_in_id;
  
  // ???? TBD: Check possible optimization of this logic, assuming message_data is always DW aligned 
  wire [63:0]  current_out_keep;
  wire [515:0] message_afubypass_data;
  reg [515:0]  fifo_out_dataD;
  reg 	       fifo_out_lastD;
  wire 	       fifo_out_last[NUM_MODULES-1:0];
//  wire 	       fifo_out_last[7:0];
  reg 	       fifo_out_userD;
  wire 	       fifo_out_user[NUM_MODULES-1:0];
//  wire 	       fifo_out_user[7:0];
  reg [7:0]    fifo_out_statusD;
  wire [11:0]  fifo0_out_message_id;
  wire [11:0]  fifo1_out_message_id;
  wire [11:0]  fifo2_out_message_id;
  wire [11:0]  fifo3_out_message_id;
  wire [11:0]  fifo4_out_message_id;
  wire [11:0]  fifo5_out_message_id;
  wire [11:0]  fifo6_out_message_id;
  wire [11:0]  fifo7_out_message_id;
  wire [3:0]  fifo0_out_chid;
  wire [3:0]  fifo1_out_chid;
  wire [3:0]  fifo2_out_chid;
  wire [3:0]  fifo3_out_chid;
  wire [3:0]  fifo4_out_chid;
  wire [3:0]  fifo5_out_chid;
  wire [3:0]  fifo6_out_chid;
  wire [3:0]  fifo7_out_chid;
  wire [11:0]  fifo0_out_expected_message_id;
  wire [11:0]  fifo1_out_expected_message_id;
  wire [11:0]  fifo2_out_expected_message_id;
  wire [11:0]  fifo3_out_expected_message_id;
  wire [11:0]  fifo4_out_expected_message_id;
  wire [11:0]  fifo5_out_expected_message_id;
  wire [11:0]  fifo6_out_expected_message_id;
  wire [11:0]  fifo7_out_expected_message_id;
  wire [7:0]   fifo_out_message_valid_regD;
  wire [15:0]  fifo_out_message_valid_doubleregD;
  reg [3:0]    current_fifo_out_id;
  reg [3:0]    fifo_out_id_delta;
  wire [3:0]   next_fifo_out_id;
  reg [11:0]   current_fifo_out_message_id;
  reg [15:0]   current_fifo_out_message_size;
  reg [15:0]   ip_header_length;
  reg [15:0]   udp_header_length;
  reg 	       sbu2pci_afubypass_inprogress;
  reg [3:0]    sbu2pci_out_nstate;
  reg	       module_out_ready;
  reg	       module_out_status_ready;
  wire 	       fifo_out_status_valid[NUM_MODULES-1:0];
//  wire 	       fifo_out_status_valid[7:0];
  
  reg 	       update_fifo_out_regs;
  reg [3:0]    current_fifo_out_chid;
  reg [3:0]    current_fifo_out_status;
  
  reg [15:0]   fifo0_in_total_load;  // Total load held in fifox_in.
                                     // Equivalent to total clocks, it takes the zucx_module to handle the whole fifox_in content
                                     // Max fifox_in load is when it holds maximum number of shortest messages:
                                     // Max messages in fifox_in  = input_buffer_size / shortest message size = 512/4 = 128 messages
                                     // Max load: max_messages x message latency: 128 * 62 clocks = 'd7936 = 'h1f00
                                     //
                                     // fifox_in_total_load update scheme: 
                                     // Upon adding a new message to fifox_in, it is incremented with the message_size/4 + message_overhead (48 clocks)  
                                     // Once the message zuc init ended, the message overhead (48) is deducted from *total_load
                                     // Once the message flit is done, the flit length (between 1 and 16) is deducted from *total_load
  reg [15:0]    fifo1_in_total_load;
  reg [15:0]    fifo2_in_total_load;
  reg [15:0]    fifo3_in_total_load;
  reg [15:0]    fifo4_in_total_load;
  reg [15:0]    fifo5_in_total_load;
  reg [15:0]    fifo6_in_total_load;
  reg [15:0]    fifo7_in_total_load;
  reg [8:0]    fifo0_in_message_count;
  reg [8:0]    fifo1_in_message_count;
  reg [8:0]    fifo2_in_message_count;
  reg [8:0]    fifo3_in_message_count;
  reg [8:0]    fifo4_in_message_count;
  reg [8:0]    fifo5_in_message_count;
  reg [8:0]    fifo6_in_message_count;
  reg [8:0]    fifo7_in_message_count;
  reg [8:0]    fifo0_out_message_count;
  reg [8:0]    fifo1_out_message_count;
  reg [8:0]    fifo2_out_message_count;
  reg [8:0]    fifo3_out_message_count;
  reg [8:0]    fifo4_out_message_count;
  reg [8:0]    fifo5_out_message_count;
  reg [8:0]    fifo6_out_message_count;
  reg [8:0]    fifo7_out_message_count;
  reg [15:0]   chid0_last_message_id;
  reg [15:0]   chid1_last_message_id;
  reg [15:0]   chid2_last_message_id;
  reg [15:0]   chid3_last_message_id;
  reg [15:0]   chid4_last_message_id;
  reg [15:0]   chid5_last_message_id;
  reg [15:0]   chid6_last_message_id;
  reg [15:0]   chid7_last_message_id;
  reg [15:0]   chid8_last_message_id;
  reg [15:0]   chid9_last_message_id;
  reg [15:0]   chid10_last_message_id;
  reg [15:0]   chid11_last_message_id;
  reg [15:0]   chid12_last_message_id;
  reg [15:0]   chid13_last_message_id;
  reg [15:0]   chid14_last_message_id;
  reg [15:0]   chid15_last_message_id;
  
  reg [15:0]   fifo0_out_last_message_id;
  reg [15:0]   fifo1_out_last_message_id;
  reg [15:0]   fifo2_out_last_message_id;
  reg [15:0]   fifo3_out_last_message_id;
  reg [15:0]   fifo4_out_last_message_id;
  reg [15:0]   fifo5_out_last_message_id;
  reg [15:0]   fifo6_out_last_message_id;
  reg [15:0]   fifo7_out_last_message_id;

  reg [31:0]   total_fifo0_out_message_count;
  reg [31:0]   total_fifo1_out_message_count;
  reg [31:0]   total_fifo2_out_message_count;
  reg [31:0]   total_fifo3_out_message_count;
  reg [31:0]   total_fifo4_out_message_count;
  reg [31:0]   total_fifo5_out_message_count;
  reg [31:0]   total_fifo6_out_message_count;
  reg [31:0]   total_fifo7_out_message_count;
  reg [35:0]   total_afubypass_message_count;

  wire [12:0]  input_buffer_wadrs;
  wire [12:0]  input_buffer_meta_wadrs;
  wire [515:0] input_buffer_wdata;
  wire [47:0]  input_buffer_meta_wdata;
  wire [12:0]  input_buffer_radrs;
  wire [515:0] input_buffer_rd;
  wire [515:0] input_buffer_rdata;
  wire [47:0]  input_buffer_meta_rdata;
//  wire 	       update_zuc_module_regs[NUM_MODULES-1:0];
//  wire 	       hmac_match[NUM_MODULES-1:0];
  wire 	       update_zuc_module_regs[7:0];
  wire 	       hmac_match[7:0];


  wire [515:0] fifo_out_data[NUM_MODULES-1:0];
  wire [7:0]   fifo_out_status[NUM_MODULES-1:0];
  wire [9:0]   fifo_in_data_count[NUM_MODULES-1:0];
//  wire [515:0] fifo_out_data[7:0];
//  wire [7:0]   fifo_out_status[7:0];
//  wire [9:0]   fifo_in_data_count[7:0];

  wire [7:0]   zuc0_status_data;
  wire [7:0]   zuc1_status_data;
  wire [7:0]   zuc2_status_data;
  wire [7:0]   zuc3_status_data;
  wire [31:0]  zuc_out_stats[NUM_MODULES-1:0];
//  wire [31:0]  zuc_out_stats[7:0];
  wire [15:0]  zuc_progress[NUM_MODULES-1:0];
//  wire [15:0]  zuc_progress[7:0];
  reg [2:0]    input_buffer_read_latency;

  wire 	       current_in_buffer_full;
  wire 	       current_in_buffer_watermark_met;
  wire 	       current_out_last;
  reg [7:0]    current_response_cmd;
  reg          current_out_zuccmd;
  reg          current_fifo_out_message_type; // hmac: 0: EThernet, only
  reg [15:0]   current_response_tuser;

  

  assign pci2sbu_axi4stream_rdy = pci2sbu_ready;

// TBD: connect to afu events
  assign afu_events = 64'b0;

  assign next_out_chid = {1'b0, current_out_chid} + current_out_chid_delta;
  assign next_fifo_in_id = {1'b0, current_fifo_in_id} + fifo_in_id_delta;

  assign fifo7_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[7]};
  assign fifo6_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[6]};
  assign fifo5_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[5]};
  assign fifo4_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[4]};
  assign fifo3_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[3]};
  assign fifo2_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[2]};
  assign fifo1_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[1]};
  assign fifo0_in_free_count = MODULE_FIFO_IN_SIZE - {6'b0, fifo_in_data_count[0]};

  assign next_fifo_out_id = (current_fifo_out_id + fifo_out_id_delta) & 4'h7; // MOD 8 addition
  

// Input Message buffering logic:
// ==============================  
//channel_in (write) arguments selection
  always @(*) begin
    case (current_in_chid)
      0:
	begin
	  current_in_tailD = chid0_in_tail;  // write_to pointer
	  current_in_headD = chid0_out_head; // read pointer. The out_head pointer is used to calculate free space in chidx_input_buffer
              	                             // Notice that *_out_head register is updated by the message read SM 
	  current_in_somD = chid0_in_som;    // All messages in current channel buffer are complete. No partial messages
	                                     // som will be cleared once next message started to be written to buffer
	                                     // som will be set once last line of last packet has been written to buffer  
	  current_in_message_idD = chid0_in_message_id; // Locally generated message ID, to be used for messages ordering to sbu2pci
                                             // Messages IDs are sequentially incremented. wrapped around a 10 bit counter.
	                                     // A separate message ID counter per channnel
	                                     // Per channel, both enc and auth messages share the same ID counter
	  current_in_message_sizeD = chid0_in_message_size;
	  current_in_opcodeD = chid0_in_opcode;
	  current_in_message_startD = chid0_in_message_start;
	  current_in_message_linesD = chid0_in_message_lines;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[0];
	end
      1:
	begin
	  current_in_tailD = chid1_in_tail;
	  current_in_headD = chid1_out_head;
	  current_in_somD = chid1_in_som;
	  current_in_message_sizeD = chid1_in_message_size;
	  current_in_opcodeD = chid1_in_opcode;
	  current_in_message_startD = chid1_in_message_start;
	  current_in_message_linesD = chid1_in_message_lines;
	  current_in_message_idD = chid1_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[1];
	end
      
      2:
	begin
	  current_in_tailD = chid2_in_tail;
	  current_in_headD = chid2_out_head;
	  current_in_somD = chid2_in_som;
	  current_in_message_sizeD = chid2_in_message_size;
	  current_in_opcodeD = chid2_in_opcode;
	  current_in_message_startD = chid2_in_message_start;
	  current_in_message_linesD = chid2_in_message_lines;
	  current_in_message_idD = chid2_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[2];
	end
      
      3:
	begin
	  current_in_tailD = chid3_in_tail;
	  current_in_headD = chid3_out_head;
	  current_in_somD = chid3_in_som;
	  current_in_message_sizeD = chid3_in_message_size;
	  current_in_opcodeD = chid3_in_opcode;
	  current_in_message_startD = chid3_in_message_start;
	  current_in_message_linesD = chid3_in_message_lines;
	  current_in_message_idD = chid3_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[3];
	end
      
      4:
	begin
	  current_in_tailD = chid4_in_tail;
	  current_in_headD = chid4_out_head;
	  current_in_somD = chid4_in_som;
	  current_in_message_sizeD = chid4_in_message_size;
	  current_in_opcodeD = chid4_in_opcode;
	  current_in_message_startD = chid4_in_message_start;
	  current_in_message_linesD = chid4_in_message_lines;
	  current_in_message_idD = chid4_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[4];
	end
      
      5:
	begin
	  current_in_tailD = chid5_in_tail;
	  current_in_headD = chid5_out_head;
	  current_in_somD = chid5_in_som;
	  current_in_message_sizeD = chid5_in_message_size;
	  current_in_opcodeD = chid5_in_opcode;
	  current_in_message_startD = chid5_in_message_start;
	  current_in_message_linesD = chid5_in_message_lines;
	  current_in_message_idD = chid5_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[5];
	end
      
      6:
	begin
	  current_in_tailD = chid6_in_tail;
	  current_in_headD = chid6_out_head;
	  current_in_somD = chid6_in_som;
	  current_in_message_sizeD = chid6_in_message_size;
	  current_in_opcodeD = chid6_in_opcode;
	  current_in_message_startD = chid6_in_message_start;
	  current_in_message_linesD = chid6_in_message_lines;
	  current_in_message_idD = chid6_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[6];
	end
      
      7:
	begin
	  current_in_tailD = chid7_in_tail;
	  current_in_headD = chid7_out_head;
	  current_in_somD = chid7_in_som;
	  current_in_message_sizeD = chid7_in_message_size;
	  current_in_opcodeD = chid7_in_opcode;
	  current_in_message_startD = chid7_in_message_start;
	  current_in_message_linesD = chid7_in_message_lines;
	  current_in_message_idD = chid7_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[7];
	end
      
      8:
	begin
	  current_in_tailD = chid8_in_tail;
	  current_in_headD = chid8_out_head;
	  current_in_somD = chid8_in_som;
	  current_in_message_sizeD = chid8_in_message_size;
	  current_in_opcodeD = chid8_in_opcode;
	  current_in_message_startD = chid8_in_message_start;
	  current_in_message_linesD = chid8_in_message_lines;
	  current_in_message_idD = chid8_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[8];
	end
      
      9:
	begin
	  current_in_tailD = chid9_in_tail;
	  current_in_headD = chid9_out_head;
	  current_in_somD = chid9_in_som;
	  current_in_message_sizeD = chid9_in_message_size;
	  current_in_opcodeD = chid9_in_opcode;
	  current_in_message_startD = chid9_in_message_start;
	  current_in_message_linesD = chid9_in_message_lines;
	  current_in_message_idD = chid9_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[9];
	end
      
      10:
	begin
	  current_in_tailD = chid10_in_tail;
	  current_in_headD = chid10_out_head;
	  current_in_somD = chid10_in_som;
	  current_in_message_sizeD = chid10_in_message_size;
	  current_in_opcodeD = chid10_in_opcode;
	  current_in_message_startD = chid10_in_message_start;
	  current_in_message_linesD = chid10_in_message_lines;
	  current_in_message_idD = chid10_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[10];
	end
      
      11:
	begin
	  current_in_tailD = chid11_in_tail;
	  current_in_headD = chid11_out_head;
	  current_in_somD = chid11_in_som;
	  current_in_message_sizeD = chid11_in_message_size;
	  current_in_opcodeD = chid11_in_opcode;
	  current_in_message_startD = chid11_in_message_start;
	  current_in_message_linesD = chid11_in_message_lines;
	  current_in_message_idD = chid11_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[11];
	end
      
      12:
	begin
	  current_in_tailD = chid12_in_tail;
	  current_in_headD = chid12_out_head;
	  current_in_somD = chid12_in_som;
	  current_in_message_sizeD = chid12_in_message_size;
	  current_in_opcodeD = chid12_in_opcode;
	  current_in_message_startD = chid12_in_message_start;
	  current_in_message_linesD = chid12_in_message_lines;
	  current_in_message_idD = chid12_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[12];
	end
      
      13:
	begin
	  current_in_tailD = chid13_in_tail;
	  current_in_headD = chid13_out_head;
	  current_in_somD = chid13_in_som;
	  current_in_message_sizeD = chid13_in_message_size;
	  current_in_opcodeD = chid13_in_opcode;
	  current_in_message_startD = chid13_in_message_start;
	  current_in_message_linesD = chid13_in_message_lines;
	  current_in_message_idD = chid13_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[13];
	end
      
      14:
	begin
	  current_in_tailD = chid14_in_tail;
	  current_in_headD = chid14_out_head;
	  current_in_somD = chid14_in_som;
	  current_in_message_sizeD = chid14_in_message_size;
	  current_in_opcodeD = chid14_in_opcode;
	  current_in_message_startD = chid14_in_message_start;
	  current_in_message_linesD = chid14_in_message_lines;
	  current_in_message_idD = chid14_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[14];
	end
      
      15:
	begin
	  current_in_tailD = chid15_in_tail;
	  current_in_headD = chid15_out_head;
	  current_in_somD = chid15_in_som;
	  current_in_message_sizeD = chid15_in_message_size;
	  current_in_opcodeD = chid15_in_opcode;
	  current_in_message_startD = chid15_in_message_start;
	  current_in_message_linesD = chid15_in_message_lines;
	  current_in_message_idD = chid15_in_message_id;
	  current_in_buffer_data_countD = chid_in_buffer_data_count[15];
	end
      
      default: begin
      end
    endcase
  end


  //channel_out (read) arguments selection
  always @(*) begin
    case (current_out_chid)
      0:
	begin
	  current_out_headD = chid0_out_head; // read_from pointer
	end
      1:
	begin
	  current_out_headD = chid1_out_head;
	end
      
      2:
	begin
	  current_out_headD = chid2_out_head;
	end
      
      3:
	begin
	  current_out_headD = chid3_out_head;
	end
      
      4:
	begin
	  current_out_headD = chid4_out_head;
	end
      
      5:
	begin
	  current_out_headD = chid5_out_head;
	end
      
      6:
	begin
	  current_out_headD = chid6_out_head;
	end
      
      7:
	begin
	  current_out_headD = chid7_out_head;
	end
      
      8:
	begin
	  current_out_headD = chid8_out_head;
	end
      
      9:
	begin
	  current_out_headD = chid9_out_head;
	end
      
      10:
	begin
	  current_out_headD = chid10_out_head;
	end
      
      11:
	begin
	  current_out_headD = chid11_out_head;
	end
      
      12:
	begin
	  current_out_headD = chid12_out_head;
	end
      
      13:
	begin
	  current_out_headD = chid13_out_head;
	end
      
      14:
	begin
	  current_out_headD = chid14_out_head;
	end
      
      15:
	begin
	  current_out_headD = chid15_out_head;
	end
      
      default: begin
      end
    endcase
  end

  
  //zuc module fifo_in arguments selection
  always @(*) begin
    case (current_fifo_in_id)
      0:
	begin
	  fifo_in_readyD = fifo_in_ready[0];
	end
      1:
	begin
	  fifo_in_readyD = fifo_in_ready[1];
	end
      
      2:
	begin
	  fifo_in_readyD = fifo_in_ready[2];
	end
      
      3:
	begin
	  fifo_in_readyD = fifo_in_ready[3];
	end

      4:
	begin
	  fifo_in_readyD = fifo_in_ready[4];
	end
      5:
	begin
	  fifo_in_readyD = fifo_in_ready[5];
	end
      
      6:
	begin
	  fifo_in_readyD = fifo_in_ready[6];
	end
      
      7:
	begin
	  fifo_in_readyD = fifo_in_ready[7];
	end
      
      default: begin
      end
    endcase
  end

  
// channel_in (write) & channel_out (read) arguments update
  always @(posedge clk) begin
    if (reset || afu_reset) begin
      // head & tail & message_start of all channels are intialized to the beginning of the per-channel buffer
      ////  for (i = 0, i < NUM_CHANNELS ; i++)
      ////     chidx_tail <= {i[3:0], LOG(CHANNEL_BUFFER_SIZE)'b0}; // chid is the index to the channel buffer in input RAM
      // som is set to indicate that at the beginning, all chaneel buffers are empty, thus the next incoming packet is obviously a message start
      chid0_out_head <= {4'h0, 9'h000};
      chid0_in_tail <= {4'h0, 9'h000};
      chid0_in_message_start <= {4'h0, 9'h000};
      chid0_in_som <= 1'b1;
      chid0_in_message_id <= 12'h000;
      chid0_in_message_lines <= 10'h000;
      chid0_in_opcode <= 8'h00;

      // message_count is a common register to both write & read operations, so no need for an in/out identifier
      // Unsigned count, max 256 messages/channel: 512 (=8K/16) entries/channel, minimum 1024b/message
      // Both input_buffer write & read state machines affect this count register
      chid1_out_head <= {4'h1, 9'h000};
      chid1_in_tail <= {4'h1, 9'h000};
      chid1_in_message_start <= {4'h1, 9'h000};
      chid1_in_som <= 1'b1;
      chid1_in_message_id <= 12'h000;
      chid1_in_message_lines <= 10'h000;
      chid2_out_head <= {4'h2, 9'b0};
      chid2_in_tail <= {4'h2, 9'b0};
      chid2_in_message_start <= {4'h2, 9'b0};
      chid2_in_som <= 1'b1;
      chid2_in_message_id <= 12'h000;
      chid2_in_message_lines <= 10'h000;
      chid3_out_head <= {4'h3, 9'b0};
      chid3_in_tail <= {4'h3, 9'b0};
      chid3_in_message_start <= {4'h3, 9'b0};
      chid3_in_som <= 1'b1;
      chid3_in_message_id <= 12'h000;
      chid3_in_message_lines <= 10'h000;
      chid4_out_head <= {4'h4, 9'b0};
      chid4_in_tail <= {4'h4, 9'b0};
      chid4_in_message_start <= {4'h4, 9'b0};
      chid4_in_som <= 1'b1;
      chid4_in_message_id <= 12'h000;
      chid4_in_message_lines <= 10'h000;
      chid5_out_head <= {4'h5, 9'b0};
      chid5_in_tail <= {4'h5, 9'b0};
      chid5_in_message_start <= {4'h5, 9'b0};
      chid5_in_som <= 1'b1;
      chid5_in_message_id <= 12'h000;
      chid5_in_message_lines <= 10'h000;
      chid6_out_head <= {4'h6, 9'b0};
      chid6_in_tail <= {4'h6, 9'b0};
      chid6_in_message_start <= {4'h6, 9'b0};
      chid6_in_som <= 1'b1;
      chid6_in_message_id <= 12'h000;
      chid6_in_message_lines <= 10'h000;
      chid7_out_head <= {4'h7, 9'b0};
      chid7_in_tail <= {4'h7, 9'b0};
      chid7_in_message_start <= {4'h7, 9'b0};
      chid7_in_som <= 1'b1;
      chid7_in_message_id <= 12'h000;
      chid7_in_message_lines <= 10'h000;
      chid8_out_head <= {4'h8, 9'b0};
      chid8_in_tail <= {4'h8, 9'b0};
      chid8_in_message_start <= {4'h8, 9'b0};
      chid8_in_som <= 1'b1;
      chid8_in_message_id <= 12'h000;
      chid8_in_message_lines <= 10'h000;
      chid9_out_head <= {4'h9, 9'b0};
      chid9_in_tail <= {4'h9, 9'b0};
      chid9_in_message_start <= {4'h9, 9'b0};
      chid9_in_som <= 1'b1;
      chid9_in_message_id <= 12'h000;
      chid9_in_message_lines <= 10'h000;
      chid10_out_head <= {4'ha, 9'b0};
      chid10_in_tail <= {4'ha, 9'b0};
      chid10_in_message_start <= {4'ha, 9'b0};
      chid10_in_som <= 1'b1;
      chid10_in_message_id <= 12'h000;
      chid10_in_message_lines <= 10'h000;
      chid11_out_head <= {4'hb, 9'b0};
      chid11_in_tail <= {4'hb, 9'b0};
      chid11_in_message_start <= {4'hb, 9'b0};
      chid11_in_som <= 1'b1;
      chid11_in_message_id <= 12'h000;
      chid11_in_message_lines <= 10'h000;
      chid12_out_head <= {4'hc, 9'b0};
      chid12_in_tail <= {4'hc, 9'b0};
      chid12_in_message_start <= {4'hc, 9'b0};
      chid12_in_som <= 1'b1;
      chid12_in_message_id <= 12'h000;
      chid12_in_message_lines <= 10'h000;
      chid13_out_head <= {4'hd, 9'b0};
      chid13_in_tail <= {4'hd, 9'b0};
      chid13_in_message_start <= {4'hd, 9'b0};
      chid13_in_som <= 1'b1;
      chid13_in_message_id <= 12'h000;
      chid13_in_message_lines <= 10'h000;
      chid14_out_head <= {4'he, 9'b0};
      chid14_in_tail <= {4'he, 9'b0};
      chid14_in_message_start <= {4'he, 9'b0};
      chid14_in_som <= 1'b1;
      chid14_in_message_id <= 12'h000;
      chid14_in_message_lines <= 10'h000;
      chid15_out_head <= {4'hf, 9'b0};
      chid15_in_tail <= {4'hf, 9'b0};
      chid15_in_message_start <= {4'hf, 9'b0};
      chid15_in_som <= 1'b1;
      chid15_in_message_id <= 12'h000;
      chid15_in_message_lines <= 10'h000;

      // Accumulated in_mesage_count
      // Stuck at max_count
      // Cleared when read via axi_lite (to be implemented)
      total_chid0_in_message_count <= 32'b0;
      total_chid1_in_message_count <= 32'b0;
      total_chid2_in_message_count <= 32'b0;
      total_chid3_in_message_count <= 32'b0;
      total_chid4_in_message_count <= 32'b0;
      total_chid5_in_message_count <= 32'b0;
      total_chid6_in_message_count <= 32'b0;
      total_chid7_in_message_count <= 32'b0;
      total_chid8_in_message_count <= 32'b0;
      total_chid9_in_message_count <= 32'b0;
      total_chid10_in_message_count <= 32'b0;
      total_chid11_in_message_count <= 32'b0;
      total_chid12_in_message_count <= 32'b0;
      total_chid13_in_message_count <= 32'b0;
      total_chid14_in_message_count <= 32'b0;
      total_chid15_in_message_count <= 32'b0;
      total_hmac_received_requests_count <= 48'b0;
    end
    
    else begin
      if (clear_hmac_message_counters)
	// Cleared via afu_ctrl3
	total_hmac_received_requests_count <= 48'b0;
      
      if (update_channel_in_regs)
	// Updating channel_in registers
	// This indication also used in message_out state machine to increment a per-channel message_count
	begin
	  // Update occurs after a packet receive has completed, during either of the states:
	  // PACKET_IN_IDLE,PACKET_IN_PROGRESS, PACKET_IN_EOM
	  // In case of back-to-back packets, current_in_chid will last for 1 clock only, but this should be enough for this update
	  if (current_in_eom)
	    total_hmac_received_requests_count <= total_hmac_received_requests_count + 1;

	  case (current_in_chid)
	    0:
	      begin
		chid0_in_tail <= current_in_tail;
		chid0_in_message_start <= current_in_message_start;
		chid0_in_message_lines <= current_in_message_lines;
		chid0_in_som <= current_in_som;
		chid0_in_message_size <= current_in_message_size;
		chid0_in_opcode <= current_in_opcode;

		if (current_in_eom) begin
		  // These variables are updated only upon end_of_message
		  chid0_in_message_id <= current_in_message_id;
		  
		  // Message count is not incremented if there are both inc and dec request at the same time
		  //		  chid0_in_message_count <= chid0_in_message_count + (update_channel_out_regs && (current_in_chid == current_out_chid) ? 0 : 1);
		  total_chid0_in_message_count <= total_chid0_in_message_count + 1;
		  
		end
	      end
	    1:
	      begin
		chid1_in_tail <= current_in_tail;
		chid1_in_message_start <= current_in_message_start;
		chid1_in_message_lines <= current_in_message_lines;
		chid1_in_som <= current_in_som;
		chid1_in_message_size <= current_in_message_size;
		chid1_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid1_in_message_id <= current_in_message_id;
		  total_chid1_in_message_count <= total_chid1_in_message_count + 1;
		end
	      end
	    
	    2:
	      begin
		chid2_in_tail <= current_in_tail;
		chid2_in_message_start <= current_in_message_start;
		chid2_in_message_lines <= current_in_message_lines;
		chid2_in_som <= current_in_som;
		chid2_in_message_size <= current_in_message_size;
		chid2_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid2_in_message_id <= current_in_message_id;
		  total_chid2_in_message_count <= total_chid2_in_message_count + 1;
		end
	      end
	    
	    3:
	      begin
		chid3_in_tail <= current_in_tail;
		chid3_in_message_start <= current_in_message_start;
		chid3_in_message_lines <= current_in_message_lines;
		chid3_in_som <= current_in_som;
		chid3_in_message_size <= current_in_message_size;
		chid3_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid3_in_message_id <= current_in_message_id;
		  total_chid3_in_message_count <= total_chid3_in_message_count + 1;
		end
	      end
	    
	    4:
	      begin
		chid4_in_tail <= current_in_tail;
		chid4_in_message_start <= current_in_message_start;
		chid4_in_message_lines <= current_in_message_lines;
		chid4_in_som <= current_in_som;
		chid4_in_message_size <= current_in_message_size;
		chid4_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid4_in_message_id <= current_in_message_id;
		  total_chid4_in_message_count <= total_chid4_in_message_count + 1;
		end
	      end
	    
	    5:
	      begin
		chid5_in_tail <= current_in_tail;
		chid5_in_message_start <= current_in_message_start;
		chid5_in_message_lines <= current_in_message_lines;
		chid5_in_som <= current_in_som;
		chid5_in_message_size <= current_in_message_size;
		chid5_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid5_in_message_id <= current_in_message_id;
		  total_chid5_in_message_count <= total_chid5_in_message_count + 1;
		end
	      end
	    
	    6:
	      begin
		chid6_in_tail <= current_in_tail;
		chid6_in_message_start <= current_in_message_start;
		chid6_in_message_lines <= current_in_message_lines;
		chid6_in_som <= current_in_som;
		chid6_in_message_size <= current_in_message_size;
		chid6_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid6_in_message_id <= current_in_message_id;
		  total_chid6_in_message_count <= total_chid6_in_message_count + 1;
		end
	      end
	    
	    7:
	      begin
		chid7_in_tail <= current_in_tail;
		chid7_in_message_start <= current_in_message_start;
		chid7_in_message_lines <= current_in_message_lines;
		chid7_in_som <= current_in_som;
		chid7_in_message_size <= current_in_message_size;
		chid7_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid7_in_message_id <= current_in_message_id;
		  total_chid7_in_message_count <= total_chid7_in_message_count + 1;
		end
	      end
	    
	    8:
	      begin
		chid8_in_tail <= current_in_tail;
		chid8_in_message_start <= current_in_message_start;
		chid8_in_message_lines <= current_in_message_lines;
		chid8_in_som <= current_in_som;
		chid8_in_message_size <= current_in_message_size;
		chid8_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid8_in_message_id <= current_in_message_id;
		  total_chid8_in_message_count <= total_chid8_in_message_count + 1;
		end
	      end
	    
	    9:
	      begin
		chid9_in_tail <= current_in_tail;
		chid9_in_message_start <= current_in_message_start;
		chid9_in_message_lines <= current_in_message_lines;
		chid9_in_som <= current_in_som;
		chid9_in_message_size <= current_in_message_size;
		chid9_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid9_in_message_id <= current_in_message_id;
		  total_chid9_in_message_count <= total_chid9_in_message_count + 1;
		end
	      end
	    
	    10:
	      begin
		chid10_in_tail <= current_in_tail;
		chid10_in_message_start <= current_in_message_start;
		chid10_in_message_lines <= current_in_message_lines;
		chid10_in_som <= current_in_som;
		chid10_in_message_size <= current_in_message_size;
		chid10_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid10_in_message_id <= current_in_message_id;
		  total_chid10_in_message_count <= total_chid10_in_message_count + 1;
		end
	      end
	    
	    11:
	      begin
		chid11_in_tail <= current_in_tail;
		chid11_in_message_start <= current_in_message_start;
		chid11_in_message_lines <= current_in_message_lines;
		chid11_in_som <= current_in_som;
		chid11_in_message_size <= current_in_message_size;
		chid11_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid11_in_message_id <= current_in_message_id;
		  total_chid11_in_message_count <= total_chid11_in_message_count + 1;
		end
	      end
	    
	    12:
	      begin
		chid12_in_tail <= current_in_tail;
		chid12_in_message_start <= current_in_message_start;
		chid12_in_message_lines <= current_in_message_lines;
		chid12_in_som <= current_in_som;
		chid12_in_message_size <= current_in_message_size;
		chid12_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid12_in_message_id <= current_in_message_id;
		  total_chid12_in_message_count <= total_chid12_in_message_count + 1;
		end
	      end
	    
	    13:
	      begin
		chid13_in_tail <= current_in_tail;
		chid13_in_message_start <= current_in_message_start;
		chid13_in_message_lines <= current_in_message_lines;
		chid13_in_som <= current_in_som;
		chid13_in_message_size <= current_in_message_size;
		chid13_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid13_in_message_id <= current_in_message_id;
		  total_chid13_in_message_count <= total_chid13_in_message_count + 1;
		end
	      end
	    
	    14:
	      begin
		chid14_in_tail <= current_in_tail;
		chid14_in_message_start <= current_in_message_start;
		chid14_in_message_lines <= current_in_message_lines;
		chid14_in_som <= current_in_som;
		chid14_in_message_size <= current_in_message_size;
		chid14_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid14_in_message_id <= current_in_message_id;
		  total_chid14_in_message_count <= total_chid14_in_message_count + 1;
		end
	      end
	    
	    15:
	      begin
		chid15_in_tail <= current_in_tail;
		chid15_in_message_start <= current_in_message_start;
		chid15_in_message_lines <= current_in_message_lines;
		chid15_in_som <= current_in_som;
		chid15_in_message_size <= current_in_message_size;
		chid15_in_opcode <= current_in_opcode;
		if (current_in_eom) begin
		  chid15_in_message_id <= current_in_message_id;
		  total_chid15_in_message_count <= total_chid15_in_message_count + 1;
		end
	      end
	    
	    default: begin
	    end
	  endcase
	end

      if (update_channel_out_regs)
	// Updating channel_out registers
	begin
	  // Update occurs after a complete message has been read from buffer
	  case (current_out_chid)
	    0:
	      begin
		chid0_out_head <= current_out_head;
		chid0_out_som <= current_out_som;
	      end
	    1:
	      begin
		chid1_out_head <= current_out_head;
		chid1_out_som <= current_out_som;
	      end
	    
	    2:
	      begin
		chid2_out_head <= current_out_head;
		chid2_out_som <= current_out_som;
	      end
	    
	    3:
	      begin
		chid3_out_head <= current_out_head;
		chid3_out_som <= current_out_som;
	      end
	    
	    4:
	      begin
		chid4_out_head <= current_out_head;
		chid4_out_som <= current_out_som;
	      end
	    
	    5:
	      begin
		chid5_out_head <= current_out_head;
		chid5_out_som <= current_out_som;
	      end
	    
	    6:
	      begin
		chid6_out_head <= current_out_head;
		chid6_out_som <= current_out_som;
	      end
	    
	    7:
	      begin
		chid7_out_head <= current_out_head;
		chid7_out_som <= current_out_som;
	      end
	    
	    8:
	      begin
		chid8_out_head <= current_out_head;
		chid8_out_som <= current_out_som;
	      end
	    
	    9:
	      begin
		chid9_out_head <= current_out_head;
		chid9_out_som <= current_out_som;
	      end
	    
	    10:
	      begin
		chid10_out_head <= current_out_head;
		chid10_out_som <= current_out_som;
	      end
	    
	    11:
	      begin
		chid11_out_head <= current_out_head;
		chid11_out_som <= current_out_som;
	      end
	    
	    12:
	      begin
		chid12_out_head <= current_out_head;
		chid12_out_som <= current_out_som;
	      end
	    
	    13:
	      begin
		chid13_out_head <= current_out_head;
		chid13_out_som <= current_out_som;
	      end
	    
	    14:
	      begin
		chid14_out_head <= current_out_head;
		chid14_out_som <= current_out_som;
	      end
	    
	    15:
	      begin
		chid15_out_head <= current_out_head;
		chid15_out_som <= current_out_som;
	      end
	    
	    default: begin
	    end
	  endcase
	end
    end
  end  


  generate
  genvar k;
    // in_message_count[*] update:
    // Message count is unchanged if there is both inc and dec request at the same time
  for (k = 0; k < NUM_CHANNELS ; k = k + 1) begin: in_message_counters
    always @(posedge clk) 
      begin
	if (reset || afu_reset) 
	  begin
	    chid_in_message_count[k] <= 10'h000;
	  end
	else 
	  begin
	  if ((current_in_eom && update_channel_in_regs && (current_in_chid == k)) && ~(update_channel_out_regs && (current_out_chid == k)))
	    chid_in_message_count[k] <= chid_in_message_count[k] + 1'b1;
	  else if (~(current_in_eom && update_channel_in_regs && (current_in_chid == k)) && (update_channel_out_regs && (current_out_chid == k)))
	    chid_in_message_count[k] <= chid_in_message_count[k] - 1'b1;
	  end
      end  
  end
  endgenerate


// fifox_in_total_load calculation:
  wire [2:0] update_fifo0_in_load;
  wire [2:0] update_fifo1_in_load;
  wire [2:0] update_fifo2_in_load;
  wire [2:0] update_fifo3_in_load;
  wire [2:0] update_fifo4_in_load;
  wire [2:0] update_fifo5_in_load;
  wire [2:0] update_fifo6_in_load;
  wire [2:0] update_fifo7_in_load;
  wire [15:0] current_fifo_in_message_load;
  wire [15:0] current_fifo_in_message_overhead;
  wire [15:0] current_zuc0_flit_overhead;
  wire [15:0] current_zuc0_message_overhead;
  wire [15:0] current_zuc1_flit_overhead;
  wire [15:0] current_zuc1_message_overhead;
  wire [15:0] current_zuc2_flit_overhead;
  wire [15:0] current_zuc2_message_overhead;
  wire [15:0] current_zuc3_flit_overhead;
  wire [15:0] current_zuc3_message_overhead;
  wire [15:0] current_zuc4_flit_overhead;
  wire [15:0] current_zuc4_message_overhead;
  wire [15:0] current_zuc5_flit_overhead;
  wire [15:0] current_zuc5_message_overhead;
  wire [15:0] current_zuc6_flit_overhead;
  wire [15:0] current_zuc6_message_overhead;
  wire [15:0] current_zuc7_flit_overhead;
  wire [15:0] current_zuc7_message_overhead;

  assign update_fifo0_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b000), zuc_progress[0][1:0]};
  assign update_fifo1_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b001), zuc_progress[1][1:0]};
  assign update_fifo2_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b010), zuc_progress[2][1:0]};
  assign update_fifo3_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b011), zuc_progress[3][1:0]};
  assign update_fifo4_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b100), zuc_progress[4][1:0]};
  assign update_fifo5_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b101), zuc_progress[5][1:0]};
  assign update_fifo6_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b110), zuc_progress[6][1:0]};
  assign update_fifo7_in_load = {update_fifo_in_regs && (current_fifo_in_id == 3'b111), zuc_progress[7][1:0]};
  assign current_fifo_in_message_overhead = (current_fifo_in_message_cmd == MESSAGE_CMD_INTEG) ? 16'h002e :        // I message overhead: 46 clocks
					    (current_fifo_in_message_cmd == MESSAGE_CMD_CONF) ? 16'h002c :         // I message overhead: 44 clocks 
					    (current_fifo_in_message_cmd == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // MODULEBYPASS message overhead: 6 clocks
					    16'h0000;

  assign current_fifo_in_message_load = (current_fifo_in_message_cmd == MESSAGE_CMD_MODULEBYPASS) ?
					(current_fifo_in_message_lines + 1) + current_fifo_in_message_overhead : // In bypass, header line should be added 
					(current_fifo_in_message_words) + current_fifo_in_message_overhead;

  assign current_zuc0_flit_overhead = ({4'h0, zuc_progress[0][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[0][15:8]};
  assign current_zuc0_message_overhead = ({4'h0, zuc_progress[0][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[0][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[0][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc1_flit_overhead = ({4'h0, zuc_progress[1][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[1][15:8]};
  assign current_zuc1_message_overhead = ({4'h0, zuc_progress[1][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[1][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[1][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc2_flit_overhead = ({4'h0, zuc_progress[2][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[2][15:8]};
  assign current_zuc2_message_overhead = ({4'h0, zuc_progress[2][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[2][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[2][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc3_flit_overhead = ({4'h0, zuc_progress[3][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[3][15:8]};
  assign current_zuc3_message_overhead = ({4'h0, zuc_progress[3][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[3][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[3][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc4_flit_overhead = ({4'h0, zuc_progress[4][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[4][15:8]};
  assign current_zuc4_message_overhead = ({4'h0, zuc_progress[4][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[4][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[4][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc5_flit_overhead = ({4'h0, zuc_progress[5][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[5][15:8]};
  assign current_zuc5_message_overhead = ({4'h0, zuc_progress[5][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[5][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[5][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc6_flit_overhead = ({4'h0, zuc_progress[6][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[6][15:8]};
  assign current_zuc6_message_overhead = ({4'h0, zuc_progress[6][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[6][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[6][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;
  assign current_zuc7_flit_overhead = ({4'h0, zuc_progress[7][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0001 : {8'h00, zuc_progress[7][15:8]};
  assign current_zuc7_message_overhead = ({4'h0, zuc_progress[7][7:4]} == MESSAGE_CMD_INTEG) ? 16'h002e : // 46 clocks overhead per I message 
					    ({4'h0, zuc_progress[7][7:4]} == MESSAGE_CMD_CONF) ? 16'h002c : // 44 clocks overhead per C message 
					    ({4'h0, zuc_progress[7][7:4]} == MESSAGE_CMD_MODULEBYPASS) ? 16'h0006 : // 6 clocks overhead per MODULEBYPASS message 
					    16'h0000;

  
  always @(posedge clk) begin
    if (reset || afu_reset) begin
      fifo0_in_message_count <= 0;
      fifo1_in_message_count <= 0;
      fifo2_in_message_count <= 0;
      fifo3_in_message_count <= 0;
      fifo4_in_message_count <= 0;
      fifo5_in_message_count <= 0;
      fifo6_in_message_count <= 0;
      fifo7_in_message_count <= 0;
      fifo0_in_total_load <= 0;
      fifo1_in_total_load <= 0;
      fifo2_in_total_load <= 0;
      fifo3_in_total_load <= 0;
      fifo4_in_total_load <= 0;
      fifo5_in_total_load <= 0;
      fifo6_in_total_load <= 0;
      fifo7_in_total_load <= 0;
    end
    else begin
      // Update fifo0_in message count:
      // 1. Increment if loaded with a new message from input_buffer
      // 2. Decrement if a message read to zuc0 module
      // 3. Do nothing, if both 1 & 2 occur at the same time
      if (update_fifo_in_regs && (current_fifo_in_id == 3'b000) && ~update_zuc_module_regs[0])
	fifo0_in_message_count <= fifo0_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b000)) && update_zuc_module_regs[0])
	fifo0_in_message_count <= fifo0_in_message_count - 1;
      // else, do nothing
      
      if (update_fifo_in_regs && (current_fifo_in_id == 3'b001) && ~update_zuc_module_regs[1])
	fifo1_in_message_count <= fifo1_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b001)) && update_zuc_module_regs[1])
	fifo1_in_message_count <= fifo1_in_message_count - 1;

      if (update_fifo_in_regs && (current_fifo_in_id == 3'b010) && ~update_zuc_module_regs[2])
	fifo2_in_message_count <= fifo2_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b010)) && update_zuc_module_regs[2])
	fifo2_in_message_count <= fifo2_in_message_count - 1;

      if (update_fifo_in_regs && (current_fifo_in_id == 3'b011) && ~update_zuc_module_regs[3])
	fifo3_in_message_count <= fifo3_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b011)) && update_zuc_module_regs[3])
	fifo3_in_message_count <= fifo3_in_message_count - 1;

      if (update_fifo_in_regs && (current_fifo_in_id == 3'b100) && ~update_zuc_module_regs[4])
	fifo4_in_message_count <= fifo4_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b100)) && update_zuc_module_regs[4])
	fifo4_in_message_count <= fifo4_in_message_count - 1;
      
      if (update_fifo_in_regs && (current_fifo_in_id == 3'b101) && ~update_zuc_module_regs[5])
	fifo5_in_message_count <= fifo5_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b101)) && update_zuc_module_regs[5])
	fifo5_in_message_count <= fifo5_in_message_count - 1;

      if (update_fifo_in_regs && (current_fifo_in_id == 3'b110) && ~update_zuc_module_regs[6])
	fifo6_in_message_count <= fifo6_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b110)) && update_zuc_module_regs[6])
	fifo6_in_message_count <= fifo6_in_message_count - 1;

      if (update_fifo_in_regs && (current_fifo_in_id == 3'b111) && ~update_zuc_module_regs[7])
	fifo7_in_message_count <= fifo7_in_message_count + 1;
      else if (~(update_fifo_in_regs && (current_fifo_in_id == 3'b111)) && update_zuc_module_regs[7])
	fifo7_in_message_count <= fifo7_in_message_count - 1;


      // fifox_in total load calculation:
      case (update_fifo0_in_load)
	0:
	  begin
	    // Do nothing
	  end
	1:
	  begin
	    // Another message overhead is done by zuc0
	    fifo0_in_total_load <= fifo0_in_total_load - current_zuc0_message_overhead;
	  end
	
	2:
	  begin
	    // Message overhead is done by zuc0
	    fifo0_in_total_load <= fifo0_in_total_load - current_zuc0_flit_overhead;
	  end
	3:
	  begin
	    // Reserved. Do nothing
	  end
	4:
	  begin
	    // A new message have been loaded to fifo0_in
	    fifo0_in_total_load <= fifo0_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    // A new message have been loaded to fifo0_in, along with zuc0 done with a message_overhead
	    fifo0_in_total_load <= fifo0_in_total_load + current_fifo_in_message_load - current_zuc0_message_overhead;
	  end
	6:
	  begin
	    // A new message have been loaded to fifo0_in, along with zuc0 done with another flit
	    fifo0_in_total_load <= fifo0_in_total_load + current_fifo_in_message_load - current_zuc0_flit_overhead;
	  end
	7:
	  begin
	    // Impossible case, do nothing
	  end
	
	default: begin
	end
      endcase

      case (update_fifo1_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo1_in_total_load <= fifo1_in_total_load - current_zuc1_message_overhead;
	  end
	
	2:
	  begin
	    fifo1_in_total_load <= fifo1_in_total_load - current_zuc1_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo1_in_total_load <= fifo1_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo1_in_total_load <= fifo1_in_total_load + current_fifo_in_message_load - current_zuc1_message_overhead;
	  end
	6:
	  begin
	    fifo1_in_total_load <= fifo1_in_total_load + current_fifo_in_message_load - current_zuc1_flit_overhead;
	  end
	7:
	  begin
	  end
	
	default: begin
	end
      endcase

      case (update_fifo2_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo2_in_total_load <= fifo2_in_total_load - current_zuc2_message_overhead;
	  end
	
	2:
	  begin
	    fifo2_in_total_load <= fifo2_in_total_load - current_zuc2_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo2_in_total_load <= fifo2_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo2_in_total_load <= fifo2_in_total_load + current_fifo_in_message_load - current_zuc2_message_overhead;
	  end
	6:
	  begin
	    fifo2_in_total_load <= fifo2_in_total_load + current_fifo_in_message_load - current_zuc2_flit_overhead;
	  end
	7:
	  begin
	  end
	
	default: begin
	end
      endcase

      case (update_fifo3_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo3_in_total_load <= fifo3_in_total_load - current_zuc3_message_overhead;
	  end
	
	2:
	  begin
	    fifo3_in_total_load <= fifo3_in_total_load - current_zuc3_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo3_in_total_load <= fifo3_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo3_in_total_load <= fifo3_in_total_load + current_fifo_in_message_load - current_zuc3_message_overhead;
	  end
	6:
	  begin
	    fifo3_in_total_load <= fifo3_in_total_load + current_fifo_in_message_load - current_zuc3_flit_overhead;
	  end
	7:
	  begin
	  end

	
	default: begin
	end
      endcase

      case (update_fifo4_in_load)
	0:
	  begin
	    // Do nothing
	  end
	1:
	  begin
	    // Another message overhead is done by zuc0
	    fifo4_in_total_load <= fifo4_in_total_load - current_zuc4_message_overhead;
	  end
	
	2:
	  begin
	    // Message overhead is done by zuc0
	    fifo4_in_total_load <= fifo4_in_total_load - current_zuc4_flit_overhead;
	  end
	3:
	  begin
	    // Reserved. Do nothing
	  end
	4:
	  begin
	    // A new message have been loaded to fifo0_in
	    fifo4_in_total_load <= fifo4_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    // A new message have been loaded to fifo0_in, along with zuc0 done with a message_overhead
	    fifo4_in_total_load <= fifo4_in_total_load + current_fifo_in_message_load - current_zuc4_message_overhead;
	  end
	6:
	  begin
	    // A new message have been loaded to fifo0_in, along with zuc0 done with another flit
	    fifo4_in_total_load <= fifo4_in_total_load + current_fifo_in_message_load - current_zuc4_flit_overhead;
	  end
	7:
	  begin
	    // Impossible case, do nothing
	  end
	
	default: begin
	end
      endcase

      case (update_fifo5_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo5_in_total_load <= fifo5_in_total_load - current_zuc5_message_overhead;
	  end
	
	2:
	  begin
	    fifo5_in_total_load <= fifo5_in_total_load - current_zuc5_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo5_in_total_load <= fifo5_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo5_in_total_load <= fifo5_in_total_load + current_fifo_in_message_load - current_zuc5_message_overhead;
	  end
	6:
	  begin
	    fifo5_in_total_load <= fifo5_in_total_load + current_fifo_in_message_load - current_zuc5_flit_overhead;
	  end
	7:
	  begin
	  end
	
	default: begin
	end
      endcase

      case (update_fifo6_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo6_in_total_load <= fifo6_in_total_load - current_zuc6_message_overhead;
	  end
	
	2:
	  begin
	    fifo6_in_total_load <= fifo6_in_total_load - current_zuc6_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo6_in_total_load <= fifo6_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo6_in_total_load <= fifo6_in_total_load + current_fifo_in_message_load - current_zuc6_message_overhead;
	  end
	6:
	  begin
	    fifo6_in_total_load <= fifo6_in_total_load + current_fifo_in_message_load - current_zuc6_flit_overhead;
	  end
	7:
	  begin
	  end
	
	default: begin
	end
      endcase

      case (update_fifo7_in_load)
	0:
	  begin
	  end
	1:
	  begin
	    fifo7_in_total_load <= fifo7_in_total_load - current_zuc7_message_overhead;
	  end
	
	2:
	  begin
	    fifo7_in_total_load <= fifo7_in_total_load - current_zuc7_flit_overhead;
	  end
	3:
	  begin
	  end
	4:
	  begin
	    fifo7_in_total_load <= fifo7_in_total_load + current_fifo_in_message_load;
	  end
	5:
	  begin
	    fifo7_in_total_load <= fifo7_in_total_load + current_fifo_in_message_load - current_zuc7_message_overhead;
	  end
	6:
	  begin
	    fifo7_in_total_load <= fifo7_in_total_load + current_fifo_in_message_load - current_zuc7_flit_overhead;
	  end
	7:
	  begin
	  end
	
	default: begin
	end
      endcase

    end
  end


  // input_buffer full/empty indication:
  // Calculated per channel.
  // buffer full means less than 4 lines left in current_buffer
  assign current_in_buffer_full = (current_in_buffer_data_countD >= CHANNEL_BUFFER_MAX_CAPACITY) ? 1'b1 : 1'b0;
  assign current_in_buffer_free_data_count = ~current_in_buffer_full ? CHANNEL_BUFFER_MAX_CAPACITY - current_in_buffer_data_countD : 11'h0000;
  
  //(current_in_tail >= current_in_headD) ?
  //  				   (current_in_tail - current_in_headD) >= (CHANNEL_BUFFER_MAX_CAPACITY) :
  //  				   (current_in_headD - current_in_tail) <= CHANNEL_BUFFER_SIZE_WATERMARK;
generate
  genvar j;
  for (j = 0; j < NUM_CHANNELS ; j = j + 1) begin: input_buffers_counters
    always @(posedge clk) begin
      if (reset || afu_reset) begin
	chid_in_buffer_data_count[j] <= 11'h000;
      end
      
      else begin
	if ((current_in_chid == j) && (current_out_chid == j))
	  // Check for concurrent inc & dec of same counter
	  begin 
	    if (current_in_tail_incremented && ~current_out_head_incremented)
		chid_in_buffer_data_count[j] <= chid_in_buffer_data_count[j] + 1'b1;
	    else if (~current_in_tail_incremented && current_out_head_incremented)
		chid_in_buffer_data_count[j] <= chid_in_buffer_data_count[j] - 1'b1;
	      // else do nothing
	  end

	else if (current_in_chid == j)
	  // Check for increment only:
	  begin 
	    if (current_in_tail_incremented)
	      chid_in_buffer_data_count[j] <= chid_in_buffer_data_count[j] + 1'b1;
	  end

	else if (current_out_chid == j)
	  // Check for decrement only:
	  begin 
	    if (current_out_head_incremented)
	      chid_in_buffer_data_count[j] <= chid_in_buffer_data_count[j] - 1'b1;
	  end

	chid_in_buffer_not_empty[j] <= chid_in_buffer_data_count[j] > 10'h0000;
      end
    end  
  end
endgenerate


  // hmac: No opcodes
  //  assign current_in_zuccmd = module_in_force_modulebypass ? 1'b0 : (current_in_opcode  == MESSAGE_CMD_CONF) || (current_in_opcode  == MESSAGE_CMD_INTEG);
  // assign current_in_zuccmd = (current_in_opcode  == MESSAGE_CMD_CONF) || (current_in_opcode  == MESSAGE_CMD_INTEG);
  // assign current_in_illegal_cmd = (current_in_opcode > 8'h03);
  
  // hmac: message size checks are not implemented
  //  wire [9:0] current_in_flits1, current_in_flits2, current_in_flits;
  //  assign current_in_flits1 = (current_in_message_size & 16'hffc0) >> 6;
  //  assign current_in_flits2 = (current_in_message_size & 16'h003f) > 0 ? 1 : 0;
  //  assign current_in_flits = current_in_flits1 + current_in_flits2;
  

  // input_buffer watermark (see afu_ctrl0[7:0] configuration):
  // Since the watermark logic is handled outside the packet_in* SM, *watrmark_met is valid only if head and tail belong to current chid
  assign current_in_buffer_watermark_met = (current_in_buffer_data_countD >= input_buffer_watermark) ? 1'b1 : 1'b0;
  
  always @(posedge clk) begin
    if (reset || afu_reset) begin
      input_buffer_watermark_met <= 16'hffff; //Default: watermark is 'met' for all channels 
      input_buffer_watermark <= 10'h000;
    end

    else begin
      if (afu_ctrl0_wr)
	begin
	  input_buffer_watermark_met <= 16'h0000; // input_buffer watermark has been configured. All 'met' indications are cleared.
	  // Max watermark is limitted to 9'h1f0 == 496 (16 lines below the input buffer size):
	  // Recall that afu_ctrl0[7:0] designate 128B ticks
	  input_buffer_watermark <= (afu_ctrl0[7:3] == 5'h1f) ? 10'h1f0 : {1'b0, afu_ctrl0[7:0], 1'b0};
	end
      else
	begin
	  if (current_in_buffer_watermark_met)
	    // Check whether watermark has been met for current channel. If yes, set its 'met' indication
	    input_buffer_watermark_met <= input_buffer_watermark_met | (16'h0001 << current_in_chid);
	end
    end
  end  
  
// hmac variables:
  reg [15:0]		current_in_tuser_steering_tag;
  reg [15:0] 		current_in_tuser_message_size;
  reg [15:0] 		current_in_tuser_message_lines;
  
  // ==========================================================================================
  // queue0/queue1 strict priority: Prioritizing between the received packets from pci2sbu port
  // ==========================================================================================
  // Assigned priority defined in afu_ctrl0.Q0_PRIORITY ([15:8])
  // Queue0 Strict Priority (unsigned fraction, implicit MSB)
  // afu_ctrl0.Q0_PRIORITY designates the priority assigned to queue0. The complement priority is assigned to queue1, as follows:
  //    q0p = queue0_priority = unsigned_Q0_PRIORITY[7:0] / 256
  //    q1p = queue1_priority = 1  queue0_priority
  //
  // Note: Only two input queues are implemented, queue0 and queue1
  //
  // Prioritizing scheme:
  // 1. A 64b total_received_bytes counter is maintained per each queue
  //    Lets designate queue0 and queue1 total_received_bytes with q0b and q1b, respectively
  // 2. This mechanism strived to maintain the following ratio:
  //       q0b/q1b = q0p/q1p
  //       or
  //       q0b * q1p = q1b * q0p
  // 3. if (q0b * q1p > q1b * q0p) then queue1 will get precedence, and vice versa
  // 4. The point is that inplemeting qxb * qyp (64bit * 8bit) is logic_wise expensive
  //    Instead, the floowing scheme is implemented
  // 5. Along with the 64b total_received_byte counters, a 16bit delta_received_byte is maintained per each queue 
  //    Designated with q0d and q1d
  // 6. Claim: 
  //       Rather than implementing (q0b * q1p = q1b * q0p) the following is implemented:
  //       q0d * q1p = q1d * q0p
  // 7. Proof:
  // 7.1.  Lets assume that we already have (q0b/q1b = q0p/q1p) ==> (q0b * q1p = q1b * q0p)
  // 7.2.  By maintaining (q0d/q1d = q0p/q1p) ==>  (q0d * q1p = q1d * q0p) we also maintain 7.1.
  // 7.3.  Adding equation 7.2. to equation 7.1:
  // 7.3.     q0b * q1p + q0d * qp1 =? q1b * q0p + q1d * qp0
  //          (q0b + q0d) * qp1 =? (q1b + q1d) * qp0
  //       and we got a maintained ratio, with the updated total_received  bytes !!!
  //  
  wire [8:0] 		hmac_q0_priority;
  wire [8:0] 		hmac_q1_priority;
  wire 			hmac_queues_priority_disable;
  wire [32:0] 		total_hmac_queue0_received_delta_next;
  wire [32:0] 		total_hmac_queue1_received_delta_next;
  wire [3:0] 		packet_in_selected_queue;
  wire [15:0] 		message_out_selected_queue;
  wire [40:0] 		hmac_queue0_weight;
  wire [40:0] 		hmac_queue1_weight;
  reg [3:0] 		current_in_dropped_queue;

  // Setting queues priority, such that hmac_q0_priority + hmac_q1_priority is always == 9'h100
  // To guarantee that, the afu_ctrl0[15:8] == 8'h00 case is treated separately.
  // Special case: afu_ctrl0[15:8] == 8'h00 is treated as priority_disable.
  assign hmac_queues_priority_disable = (afu_ctrl0[15:8] == 8'h00) ? 1'b1 : 1'b0;
  assign hmac_q0_priority = (afu_ctrl0[15:8] == 8'h00) ? 8'h01 :{1'b0, afu_ctrl0[15:8]};
  assign hmac_q1_priority = (afu_ctrl0[15:8] == 8'h00) ? 8'hff : 9'h100 - {1'b0, afu_ctrl0[15:8]};
  assign total_hmac_queue0_received_delta_next = total_hmac_queue0_received_delta + {17'b0, current_out_message_size};
  assign total_hmac_queue1_received_delta_next = total_hmac_queue1_received_delta + {17'b0, current_out_message_size};

  assign hmac_queue0_weight = total_hmac_queue0_received_delta * hmac_q1_priority;
  assign hmac_queue1_weight = total_hmac_queue1_received_delta * hmac_q0_priority;
  assign packet_in_selected_queue[3:1] = 3'b000;
  assign packet_in_selected_queue[0] = hmac_queue0_weight > hmac_queue1_weight ? 1'b1 : 1'b0;

  assign message_out_selected_queue[15:2] = 14'h0000;
  assign message_out_selected_queue[1:0] = hmac_queue0_weight > hmac_queue1_weight
					   ? 
					   messages_validD[1] ? 2'b10 : 2'b01
					   :
					   2'b01;

  
  // Message_In State Machine: Message read from pci2sbu to local buffer:
  localparam [3:0]
    PACKET_IN_IDLE             = 4'b0000,
    CHANNEL_IN_SELECT          = 4'b0001,
    PACKET_IN_WRITE_ETH_HEADER = 4'b0010,
    PACKET_IN_WRITE_HEADER     = 4'b0011,
    PACKET_IN_WRITE_STATUS     = 4'b0100,
    PACKET_IN_WAIT_WRITE       = 4'b0101,
    PACKET_IN_PROGRESS         = 4'b0110,
    PACKET_IN_DROP             = 4'b1000,
    PACKET_IN_EOM              = 4'b1111;

  always @(posedge clk) begin
    if (reset || afu_reset) begin
      packet_in_nstate <= PACKET_IN_IDLE;
      current_in_message_ok <= 1'b0;
      pci2sbu_ready <= 0;
      pci2sbu_pushback <= 1'b0;
      update_channel_in_regs <= 0;
      current_in_chid <= 4'b0;
      current_in_tail <= 13'b0;
      current_in_tail_incremented <= 0;
      current_in_head <= 13'b0;
      current_in_eom <= 0;
      current_in_pkt_type <= 0;
      current_in_tfirst <= 1;
      current_in_som <= 1;
      current_in_message_id <= 12'h000;  // message IDs per channel buffer: 256. Yet, the counter is 12 bits
      input_buffer_write <= 0;
      input_buffer_meta_write <= 0;
      input_buffer_wren <= 1'b1; // input buffer write port is enabled by default. TBD: Power optimization: Consider enabling upon need only
      write_eth_header = 1'b0;
      packet_in_progress <= 1'b0;
      current_in_message_status_update <= 1'b0;
      current_in_message_status <= 8'h00;
      hist_pci2sbu_packet_event <= 1'b0;
      hist_pci2sbu_eompacket_event <= 1'b0;
      hist_pci2sbu_message_event <= 1'b0;
      total_hmac_queue0_dropped_requests <= 48'b0;
      total_hmac_queue1_dropped_requests <= 48'b0;
    end

    else begin
      if (clear_hmac_message_counters)
//	// Cleared via afu_ctrl3
	begin
	  total_hmac_queue0_dropped_requests <= 48'b0;
	  total_hmac_queue1_dropped_requests <= 48'b0;
	end

      case (packet_in_nstate)
	PACKET_IN_IDLE:
	  // Waiting for next packet in input pci2sbu stream
	  begin
	    current_in_message_ok <= 1'b0;
	    input_buffer_write <= 0;
	    input_buffer_meta_write <= 0;
	    update_channel_in_regs <= 0;
	    pci2sbu_ready <= 0;
	    pci2sbu_pushback <= 1'b0;
	    packet_in_progress <= 1'b0;
	    current_in_message_status <= 8'h00;
	    current_in_tail_incremented <= 1'b0;
	    
	    if (pci2sbu_axi4stream_vld)
	      begin
		// start of a new packet, not neccessarily the first of a message
		//
		// First line of a packet includes a meaningful TUSER data: Keep copy of relevant TUSER data, to be saved later to channel's context
		// Notice that we sample pci2sbu_axi4stream_tdata WITHOUT dropping this line from input stream (pci2sbu_ready not asserted).
		//
		// current_in_chid is used to select the current channel related variables, which are sampled at the following state (clock)
		
		// TBD: Consider current_in_context while choosing a channel to be serviced
		// TBD: Add a scheme to filter unrecognized packets 
		//		current_in_context <= pci2sbu_axi4stream_tuser[63:60];   // Message context
		current_in_tuser_steering_tag <= pci2sbu_axi4stream_tuser[71:56];  // hmac: Steering_tag is separately sampled
		current_in_tuser_message_size <= {2'b00, pci2sbu_axi4stream_tuser[29:16]};  // hmac: Length is separately sampled
		current_in_tuser_message_lines <= pci2sbu_axi4stream_tuser[29:22] + (pci2sbu_axi4stream_tuser[21:16] > 0);
		
		// current_in_chid <= pci2sbu_axi4stream_tuser[59:56];      // Message channel ID
		//		// hmac chid is redifined to serve as queue#
		//                // For test_bench only: Using the upper nibble in pci2sbu_axi4stream_tuser[71:56] as the queue_number
		current_in_chid <= pci2sbu_axi4stream_tuser[71:68];

		// TBD: replace with current_in_chid
		current_in_dropped_queue <= pci2sbu_axi4stream_tuser[71:68];
		
		current_in_eom <= afu_ctrl0[28] ? 1'b1 : pci2sbu_axi4stream_tuser[39]; // End_Of_Message indication: 
		// Current packet is last packet of current message
		// Forced to '1, while EOM not implemented in FLD
		current_in_pkt_type <= pci2sbu_axi4stream_tuser[30];     // packet_type: 0: Ethernet, 1: DRMA RC
		
		packet_in_nstate <= CHANNEL_IN_SELECT;
	      end
	    
	  end // case: PACKET_IN_IDLE
	
	CHANNEL_IN_SELECT:
	  // A new packet is pending in pci2sbu, and we already know its destined channel
	  // Load the selected channel variables from the chidx_* array
	  // First packet line is still valid & pending in pci2sbu_axi4stream_tdata, nothing read so far
	  begin
	    current_in_message_id <= current_in_message_idD; // Holding the ID of the currently handled message
	    current_in_tail <= current_in_tailD;             // Both head and tail are required, for buffer_full calculation
	    current_in_head <= current_in_headD;
	    current_in_som <= current_in_somD;
	    current_in_message_start <= current_in_message_startD;
	    current_in_message_lines <= current_in_message_linesD;
	    current_in_mask_message_id <= ((afu_ctrl2[15:0] >> current_in_chid) & 16'h0001) > 0 ? 1'b1 : 1'b0;

	    // pci2sbu_packet_size update
	    hist_pci2sbu_packet_event_size <= 16'h0000;
	    hist_pci2sbu_packet_event_chid <= current_in_chid;
	    hist_pci2sbu_packet_event <= 1'b0;
	    hist_pci2sbu_eompacket_event_size <= 16'h0000;
	    hist_pci2sbu_eompacket_event_chid <= current_in_chid;
	    hist_pci2sbu_eompacket_event <= 1'b0;
	    hist_pci2sbu_message_event_chid <= current_in_chid;
	    hist_pci2sbu_message_event <= 1'b0;

	    // An Ethernet packet: Sample the header for a later header update
	    if (~current_in_pkt_type)
	      current_in_eth_header <= pci2sbu_axi4stream_tdata[511:0];

	    if (current_in_somD)
	      begin
		// Current packet is first in message of current chid.
		if (current_in_pkt_type)
		  begin
		    // An RDMA RC packet: Capture message size & opcode, and store the header to input buffer
		    // current_in_message_size <= pci2sbu_axi4stream_tdata[495:480];
		    // hmac message_size originates in TUSER[]
		    current_in_message_size <= pci2sbu_axi4stream_tdata[495:480];
		    current_in_opcode <= 8'h00; // hmac: opcode is meaningless		    
		    packet_in_nstate <= PACKET_IN_WRITE_HEADER;
		  end
		else
		  begin
		    // An Ethernet packet: Message size & opcode will be captured from message header after dropping the Ethernet header.
		    packet_in_nstate <= PACKET_IN_WRITE_ETH_HEADER;
		  end
	      end
	    else
	      begin
		// Current packet is not the first of a message: read its length from channel context, independent of packet type
		current_in_message_size <= current_in_message_sizeD;
		current_in_opcode <= current_in_opcodeD;
		if (current_in_pkt_type)
		  begin
		    packet_in_progress <= 1'b1;
		    packet_in_nstate <= PACKET_IN_PROGRESS;
		  end
		else
		  packet_in_nstate <= PACKET_IN_WRITE_ETH_HEADER;
	      end
	  end
	
	PACKET_IN_WRITE_ETH_HEADER:
	  begin
	    if (current_in_som)
	      // Start of a message, store the eth header into input buffer
	      begin
		if (~hmac_queues_priority_disable)
		  begin
		    if (current_in_buffer_free_data_count > current_in_tuser_message_lines)
		      begin
			write_eth_header = 1'b1;
			input_buffer_write <= 1'b1;
			input_buffer_meta_write <= 1'b1;
			pci2sbu_ready <= 1'b1;
			
			// 1-clock write settle
			packet_in_nstate <= PACKET_IN_WAIT_WRITE;
		      end
		    else
		      begin
			// queues priority is enabled and there is insufficient space in input buffer queue to hold the entire packet
			// Drop current packet.
			packet_in_nstate <= PACKET_IN_DROP;
		      end
		  end
		else if (~current_in_buffer_full)
		  // No queues priority,
		  begin
		    write_eth_header = 1'b1;
		    input_buffer_write <= 1'b1;
		    input_buffer_meta_write <= 1'b1;
		    pci2sbu_ready <= 1'b1;

		    // 1-clock write settle
		    packet_in_nstate <= PACKET_IN_WAIT_WRITE;
		  end
		else 
		  // Pushback pci2sbu and wait here...
		  // The pushback takes effect only if pci2sbu_data is valid
		pci2sbu_pushback <= 1'b1;
	      end
	    else
	      // This is an intermmediate packet, and its eth header was already written
	      // Drop current pci2sbu line without writing to input_buffer
	      begin
		write_eth_header = 1'b0;
		pci2sbu_ready <= 1'b1;
		packet_in_nstate <= PACKET_IN_WAIT_WRITE;
	      end
	  end
	
	PACKET_IN_WRITE_HEADER:
	  // Storing message header to input buffer. The header is still valid at pci2sbu_axi4stream_tdata
	  begin
	    // Incoming message header is still not stored to input buffer:
	    // Relevant parts of message header are sampled
	    current_in_message_status_update <= 1'b0;
	    current_in_tail_incremented <= 1'b0;

	    if (pci2sbu_axi4stream_vld && ~current_in_buffer_full)
	      begin
		input_buffer_write <= 1;
		input_buffer_meta_write <= 1;
		pci2sbu_ready <= 1;
		pci2sbu_pushback <= 1'b0;

		if (current_in_som && write_eth_header)
		  // After dropping the Ethernet header, next line is the message header.
		  // Sample message size and opcode:
		  begin
		    // hmac: message_size is in tuser[], not in packet header !
		    // current_in_message_size <= pci2sbu_axi4stream_tdata[495:480];
		    // current_in_opcode <= pci2sbu_axi4stream_tdata[511:504];
		    current_in_opcode <= 8'h00; // hmac: opcode is meaniningless
		    write_eth_header = 1'b0;
		  end
		packet_in_nstate <= PACKET_IN_WAIT_WRITE;
	      end
	    else
	      // input_buffer is full. wait here...
	      begin
		input_buffer_write <= 0;
		input_buffer_meta_write <= 0;
		pci2sbu_ready <= 0;
		// The pushback takes effect only if pci2sbu_data is valid
		pci2sbu_pushback <= 1'b1;
	      end

	  end
	
	PACKET_IN_WAIT_WRITE:
	  begin
	    input_buffer_write <= 0;
	    input_buffer_meta_write <= 0;
	    pci2sbu_ready <= 0;
	    pci2sbu_pushback <= 1'b0;

	    // In an intermmediate Ethernet packet, the header is dropped without being written to input buffer.
	    // Still, even without write, we arive here for the pci2sbu line drop settle.
	    // The following if, prevents tail increment in such a case.
	    if (input_buffer_write)
	      begin
		// Following input_buffer write, increment the *tail pointer
		// The tail pointer is incremented modulo channel_buffer size, to wrap around 9th bit
		current_in_tail <= (current_in_tail & 13'h1e00) | ((current_in_tail + 1) & 13'h01ff);
		current_in_tail_incremented <= 1'b1;
	      end
	    
	    if (pci2sbu_axi4stream_tlast)
	      // last packet of current message has been written to input buffer
	      // som is marked, to indicate end of current message which means; next packet belong to same chid will be a start of new message 
	      // Current channel variables (tail, som, ...)
	      begin
		// Packet has ended. update the channel related variables
		current_in_tfirst <= 1'b1;
		
		hist_pci2sbu_packet_event <= 1'b1;


		if (current_in_eom)
		  begin
		    // End_Of_Message

		    // Prepare to update & write the message header & status into input_buffer header place_holder
		    current_in_message_status_update <= 1'b1;
		    current_in_message_status_adrs <= current_in_message_start;

		    current_in_som <= 1'b1;
		    
		    // hmac: message status is ignored
		    current_in_message_status[2:0] <= 3'b0;
		    
		    packet_in_nstate <= PACKET_IN_WRITE_STATUS;
		  end

		else
		  begin
		    current_in_som <= 1'b0;
		    update_channel_in_regs <= 1'b1;
		    packet_in_nstate <= PACKET_IN_EOM;
		  end // else: !if(current_in_eom)
		
	      end // if (pci2sbu_axi4stream_tlast)
	    
	    else // if (~pci2sbu_axi4stream_tlast)
	      begin
		// current packet still not ended. Keep writing to input buffer
		current_in_tfirst <= 1'b0;
		
		if (write_eth_header)
		  begin
		    packet_in_nstate <= PACKET_IN_WRITE_HEADER;
		  end
		else
		  // This is an Ethernet packet, holding an intermmediate piece of the message.
		  // The zuc header already handled in previous packets
		  // Continue with receiving remaining message payload
		  begin
		    packet_in_progress <= 1'b1;
		    packet_in_nstate <= PACKET_IN_PROGRESS;
		  end
	      end
	  end // case: PACKET_IN_WAIT_WRITE
	
	PACKET_IN_PROGRESS:
	  // Reading a complete packet, until tlast
	  // Burst read is supported, depending on pci2sbu_axi4stream_vld and buffer free space avaiability 
	  begin
	    current_in_tail_incremented <= 1'b0;
	    if (~pci2sbu_axi4stream_vld || current_in_buffer_full)
	      // Keep waiting for both valid and non full buffer:
	      begin
		input_buffer_write <= 0;
		input_buffer_meta_write <= 0;
		pci2sbu_ready <= 0;
		// The pushback takes effect only if pci2sbu_data is valid
		pci2sbu_pushback <= 1'b1;
		packet_in_nstate <= PACKET_IN_PROGRESS;
	      end

	    else
	      begin
		// A line is read from pci2sbu_axi4stream_tdata stream and written to input buffer
		input_buffer_write <= 1;
		input_buffer_meta_write <= 1; // TBD: Recheck this status write. Seems redundant
		pci2sbu_ready <= 1;
		pci2sbu_pushback <= 1'b0;
		current_in_message_lines <= current_in_message_lines + 1;
		hist_pci2sbu_packet_event_size <= hist_pci2sbu_packet_event_size + 64;       // for pci2sbu_packet_size histogram
		hist_pci2sbu_eompacket_event_size <= hist_pci2sbu_eompacket_event_size + 64; // for pci2sbu_eompacket_size histogram

		// 1-clock write settle
		packet_in_nstate <= PACKET_IN_WAIT_WRITE;
	      end
	  end
	
	PACKET_IN_DROP:
	  // Dropping a complete packet, if currently received packet is out_of_priority
	  begin
	    if (~pci2sbu_axi4stream_vld)
	      begin
		pci2sbu_ready <= 0;
		packet_in_nstate <= PACKET_IN_DROP;
	      end

	    else
	      begin
		if (pci2sbu_axi4stream_tlast)
		  begin
		    case (current_in_dropped_queue)
		      QUEUE0:
			begin
			  total_hmac_queue0_dropped_requests <= total_hmac_queue0_dropped_requests + 1'b1;
			end
		      
		      QUEUE1:
			begin
			  total_hmac_queue1_dropped_requests <= total_hmac_queue1_dropped_requests + 1'b1;
			end	
		      
		      default:
			begin
			end
		    endcase // case (current_in_chid)
		    
		    pci2sbu_ready <= 0;
		    packet_in_nstate <= PACKET_IN_EOM;
		  end
		else
		  // Keep dropping...
		    pci2sbu_ready <= 1;
	      end
	  end
	
	PACKET_IN_WRITE_STATUS:
	  begin
	    // current_in_tail already incremented to point to start of next message.
	    current_in_tail_incremented <= 1'b0;
	    current_in_message_lines <= 10'h000;
	    current_in_message_start <= current_in_tail;
	    input_buffer_meta_write <= 1'b1;

	    hist_pci2sbu_packet_event <= 1'b0;
	    hist_pci2sbu_eompacket_event <= 1'b1;
            hist_pci2sbu_message_event_size <= (current_in_message_lines << 6); //Latter message size in bytes 
	    hist_pci2sbu_message_event <= 1'b1;

	    if (~current_in_pkt_type)
	      // Ethernet message ended:
	      // Upon message status update, first message line in input_buffer_data is also overwritten,
	      // with previously sampled header and message related metadata.
	      // Keep notice that while writing the message stats, the head pointer already points to the message start
	      input_buffer_write <= 1'b1; 
	    update_channel_in_regs <= 1'b1;
	    packet_in_nstate <= PACKET_IN_EOM;
	  end

	PACKET_IN_EOM:
	  begin
	    // TBD: Check merging this state with IDLE
	    current_in_tail_incremented <= 1'b0;
	    current_in_message_ok <= 1'b0;
	    current_in_message_status_update <= 1'b0;
	    packet_in_progress <= 1'b0;
	    input_buffer_write <= 0;
	    input_buffer_meta_write <= 0;
	    pci2sbu_ready <= 0;
	    pci2sbu_pushback <= 1'b0;
	    update_channel_in_regs <= 1'b0;
	    hist_pci2sbu_packet_event <= 1'b0;
	    hist_pci2sbu_eompacket_event <= 1'b0;
	    hist_pci2sbu_message_event <= 1'b0;

	    // After end of packet always going to IDLE. Handling a new packet always starts while in IDLE
	    packet_in_nstate <= PACKET_IN_IDLE;

	  end
	
	default:
	  begin
	  end
	
      endcase
    end
  end
  

//=================================================================================================================
// Message read SM: Reading a message from input bufer into the selected ZUC module's fifo_in
//=================================================================================================================
// 1. Prioritize next channel ID to read from: Look at all chidx_valid bits, and round_robin select next valid channel
//    Reminder: chidx_in_message_count > 1 means that chidx has at least one pending message in input buffer
// 2. Look for and round_robin next available ZUC module (any module whose fifox_in has sufficient space to hold the chidx pending message
// 3. Read next message from chidx input_buffer and store to the selected zuc module fifo:
//   3.1. chidx_num_of_lines = chidx_header.message_size/64 // number of 512b lines occupying the message in input buffer
//   3.2. fifox_in <- chidx_header // ZUC module needs it to identify start/end of message, ZUC operation, size, etc.
//   3.3. while (chidx_num_of_lines-- > 0):
//          fifox_in <- input_buffer(chidx_head++)
//   3.4. chidx_in_message_count--;
//   3.5. if (chidx_in_message_count > 0)
//          more complete message(s) are held in chidx input buffer. Read next pending message header:
//          {chidx_header, chidx_valid} = {input_buffer(chidx_head++) , '1};
//   3.6. else
//          No more pending messages. chidx_header should be cleared
//          {chidx_header, chidx_valid} = {'h00000000 , '0};
// 4. Repeat from 1     
  wire         messages_queue0_mask;
  wire         messages_queue1_mask;
  wire 	       messages_queue0_high_watermark;
  wire 	       messages_queue1_high_watermark;
  wire 	       messages_queue0_low_watermark;
  wire 	       messages_queue1_low_watermark;
  wire 	       messages_queue0_empty;
  wire 	       messages_queue1_empty;
  wire [15:0]  messages_masked_validD;
  reg 	       queues_priority_on;
  
  assign messages_validD[15:0] = {input_buffer_watermark_met[15] && (chid_in_message_count[15] > 0),
				  input_buffer_watermark_met[14] && (chid_in_message_count[14] > 0), 
				  input_buffer_watermark_met[13] && (chid_in_message_count[13] > 0),
				  input_buffer_watermark_met[12] && (chid_in_message_count[12] > 0),
				  input_buffer_watermark_met[11] && (chid_in_message_count[11] > 0),
				  input_buffer_watermark_met[10] && (chid_in_message_count[10] > 0),
				  input_buffer_watermark_met[9]  && ( chid_in_message_count[9] > 0),
				  input_buffer_watermark_met[8]  && ( chid_in_message_count[8] > 0),
				  input_buffer_watermark_met[7]  && ( chid_in_message_count[7] > 0),
				  input_buffer_watermark_met[6]  && ( chid_in_message_count[6] > 0),
				  input_buffer_watermark_met[5]  && ( chid_in_message_count[5] > 0),
				  input_buffer_watermark_met[4]  && ( chid_in_message_count[4] > 0),
				  input_buffer_watermark_met[3]  && ( chid_in_message_count[3] > 0),
				  input_buffer_watermark_met[2]  && ( chid_in_message_count[2] > 0),
				  input_buffer_watermark_met[1]  && ( chid_in_message_count[1] > 0),
				  input_buffer_watermark_met[0]  && ( chid_in_message_count[0] > 0)};

  assign messages_queue0_high_watermark = chid_in_message_count[0] > MESSAGES_HIGH_WATERMARK;
  assign messages_queue0_low_watermark = chid_in_message_count[0] < MESSAGES_LOW_WATERMARK;
  assign messages_queue0_empty = chid_in_message_count[0] == 0;
  assign messages_queue1_high_watermark = chid_in_message_count[1] > MESSAGES_HIGH_WATERMARK;
  assign messages_queue1_low_watermark = chid_in_message_count[1] < MESSAGES_LOW_WATERMARK;
  assign messages_queue1_empty = chid_in_message_count[1] == 0;

  // Input queues prioritization (queues 0 & 1 only)
  // If there are pending messages in either of queues 0 & 1, a queue will be selected depending on the prioritiation logic decision priority
  // message_out_selected_queue[0] points to the preferred queue

  //// The priority scheme is active only if there are pending messages in both queues 0 & 1.
  assign messages_queue0_mask = hmac_queues_priority_disable ? 1'b1 : ~(hmac_queue0_weight > hmac_queue1_weight);
  assign messages_queue1_mask = hmac_queues_priority_disable ? 1'b1 :  (hmac_queue0_weight > hmac_queue1_weight);

  assign messages_masked_validD[15:0] = messages_validD[15:0] & {14'h3fff, messages_queue1_mask, messages_queue0_mask};

  
  // There is at least one full message pending in input buffer, ready to be assigned to module
  assign message_out_validD = messages_masked_validD != 16'h0000;
  assign messages_valid_doubleregD[31:0] = {messages_masked_validD, messages_masked_validD};
  

  // Prioriy encoder: Selecting next chid for message_out
  always @(*) begin
    // Find next roun-robin channel with a valid pending message, starting from latter chid
    if (messages_valid_doubleregD[current_out_chid + 1])
      current_out_chid_delta = 1;
    else if (messages_valid_doubleregD[current_out_chid + 2])
      current_out_chid_delta = 2;
    else if (messages_valid_doubleregD[current_out_chid + 3])
      current_out_chid_delta = 3;
    else if (messages_valid_doubleregD[current_out_chid + 4])
      current_out_chid_delta = 4;
    else if (messages_valid_doubleregD[current_out_chid + 5])
      current_out_chid_delta = 5;
    else if (messages_valid_doubleregD[current_out_chid + 6])
      current_out_chid_delta = 6;
    else if (messages_valid_doubleregD[current_out_chid + 7])
      current_out_chid_delta = 7;
    else if (messages_valid_doubleregD[current_out_chid + 8])
      current_out_chid_delta = 8;
    else if (messages_valid_doubleregD[current_out_chid + 9])
      current_out_chid_delta = 9;
    else if (messages_valid_doubleregD[current_out_chid + 10])
      current_out_chid_delta = 10;
    else if (messages_valid_doubleregD[current_out_chid + 11])
      current_out_chid_delta = 11;
    else if (messages_valid_doubleregD[current_out_chid + 12])
      current_out_chid_delta = 12;
    else if (messages_valid_doubleregD[current_out_chid + 13])
      current_out_chid_delta = 13;
    else if (messages_valid_doubleregD[current_out_chid + 14])
      current_out_chid_delta = 14;
    else if (messages_valid_doubleregD[current_out_chid + 15])
      current_out_chid_delta = 15;
    else
      // We are back to same chid.
      // Keep same chid value
      current_out_chid_delta = 0;

  end // always @ begin

  
  // zuc module selection:
  // 1. Candidate fifo_in should have sufficient space to host the message_size
  // 2. among all fifo_in that comply to rule #1, select the fifo_in with the maximum free space 
  //
  // To simplify num of free entries calculation, the invert fifo_data_out value is assumed which is almost same as num of free entries.
  // For example: 
  // i.e in a 512deep fifo, its data_count output is a 9bit unsigned counter
  // Lets assume its data_count=9'h12c = 300.
  // inverting this value yields ~(9'h12c)=9'h0d3, which is 211
  // 211 designates the number (minus 1) of free entries in the fifo: (512-300) = 212
  // *free_count should be bigger (rather than GE) than *message_lines, to account for the header line as well 
  wire [10:0] current_fifo_in_message_linesD;
  assign current_fifo_in_message_linesD = input_buffer_meta_rdata[31:22] + (input_buffer_meta_rdata[21:16] > 0); // Message size in 512b ticks

  assign fifo_in_free_regD7 = (fifo7_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD6 = (fifo6_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD5 = (fifo5_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD4 = (fifo4_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD3 = (fifo3_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD2 = (fifo2_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD1 = (fifo1_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;
  assign fifo_in_free_regD0 = (fifo0_in_free_count > {5'b0, current_fifo_in_message_linesD}) ? 1'b1 : 1'b0;

  reg [7:0] fifo_in_minload;

  // Module i must be instanciated first, before being enabled :)
  assign zuc_module0_enable = (NUM_MODULES > 0) ? afu_ctrl0[20] : 1'b0;
  assign zuc_module1_enable = (NUM_MODULES > 1) ? afu_ctrl0[21] : 1'b0;
  assign zuc_module2_enable = (NUM_MODULES > 2) ? afu_ctrl0[22] : 1'b0;
  assign zuc_module3_enable = (NUM_MODULES > 3) ? afu_ctrl0[23] : 1'b0;
  assign zuc_module4_enable = (NUM_MODULES > 4) ? afu_ctrl0[24] : 1'b0;
  assign zuc_module5_enable = (NUM_MODULES > 5) ? afu_ctrl0[25] : 1'b0;
  assign zuc_module6_enable = (NUM_MODULES > 6) ? afu_ctrl0[26] : 1'b0;
  assign zuc_module7_enable = (NUM_MODULES > 7) ? afu_ctrl0[27] : 1'b0;


  // ===================================================================
  // zuc modules arbitration
  // ===================================================================  
  // Find next (round_robin) zuc module that complies to these conditions:
  // 1. The zuc_module is enabled
  // 2. There is sufficient fifo_in space to host the selected message_size, 
  // hmac: irrelevant... 3. Has the minimum load, among all zuc modules (relevant only in load_based arbitration mode)
  assign fifo_in_free_regD = {zuc_module7_enable && fifo_in_free_regD7 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[7]),
			      zuc_module6_enable && fifo_in_free_regD6 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[6]),
			      zuc_module5_enable && fifo_in_free_regD5 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[5]),
			      zuc_module4_enable && fifo_in_free_regD4 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[4]),
			      zuc_module3_enable && fifo_in_free_regD3 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[3]),
			      zuc_module2_enable && fifo_in_free_regD2 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[2]),
			      zuc_module1_enable && fifo_in_free_regD1 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[1]),
			      zuc_module0_enable && fifo_in_free_regD0 && ((hmac_round_robin_arb) ? 1'b1 : fifo_in_minload[0])};
  assign fifo_in_free_doubleregD = ({fifo_in_free_regD[7:0], fifo_in_free_regD[7:0]} >> current_fifo_in_id);
  
  always @(*) begin
    if (fifo_in_free_doubleregD[1])
      fifo_in_id_delta = 1;
    else if (fifo_in_free_doubleregD[2])
      fifo_in_id_delta = 2;
    else if (fifo_in_free_doubleregD[3])
      fifo_in_id_delta = 3;
    else if (fifo_in_free_doubleregD[4])
      fifo_in_id_delta = 4;
    else if (fifo_in_free_doubleregD[5])
      fifo_in_id_delta = 5;
    else if (fifo_in_free_doubleregD[6])
      fifo_in_id_delta = 6;
    else if (fifo_in_free_doubleregD[7])
      fifo_in_id_delta = 7;
    else
      // We are back to same fifo_in_id.
      // Keep same id value
      fifo_in_id_delta = 0;
  end // always @ begin

  // Find the least loaded module. Return its index in fifo_in_minload[]:
  reg [15:0] fifo0_in_load;
  reg [15:0] fifo1_in_load;
  reg [15:0] fifo2_in_load;
  reg [15:0] fifo3_in_load;
  reg [15:0] fifo4_in_load;
  reg [15:0] fifo5_in_load;
  reg [15:0] fifo6_in_load;
  reg [15:0] fifo7_in_load;
  reg [15:0] fifo_in_7to4_lowest_load;
  reg [15:0] fifo_in_3to0_lowest_load;
  
  reg  fifo_in_load_7ge6;
  reg  fifo_in_load_7ge5;
  reg  fifo_in_load_7ge4;
  reg  fifo_in_load_6ge5;
  reg  fifo_in_load_6ge4;
  reg  fifo_in_load_5ge4;
  reg  fifo_in_load_3ge2;
  reg  fifo_in_load_3ge1;
  reg  fifo_in_load_3ge0;
  reg  fifo_in_load_2ge1;
  reg  fifo_in_load_2ge0;
  reg  fifo_in_load_1ge0;
  reg [5:0] fifo_in_3to0_load_compared;
  reg [5:0] fifo_in_7to4_load_compared;
  reg [3:0] fifo_in_3to0_minload; // An asserted bit points to the modulex, whose load is the lowest among load3 thru load0
  reg [3:0] fifo_in_7to4_minload; // An asserted bit points to the modulex, whose load is the lowest among load7 thru load4

 
  // ===================================================================
  // fifox_in wiring:
  // ===================================================================
  // The selected target fifo for write is done by dedicated fifox_in_valid per fifo 
  // TBD: Replace 64'hffffffffffffffff with count_to_keep(current_fifo_in_message_size[5:0]); 
  assign current_out_keep[63:0] = (current_fifo_in_message_size >= FIFO_LINE_SIZE) ? FULL_LINE_KEEP : 64'hffffffffffffffff;
  wire  [511:0] module_in_metadata;

  //  assign module_in_data = {input_buffer_rdata[515:48], (current_fifo_in_header || current_fifo_in_eth_header) ? current_fifo_in_message_metadata : input_buffer_//rdata[47:0]};
  // hmac: A full header line is always transferred to module_in. No masks !!
  // First line to module is the hmac metadata
  // The key is previously read is already from keys_buffer
  // module_in_metadata[63:0] = hmac key
  // module_in_metadata[79:64] = packet length (TUSER.Length)
  // module_in_metadata[95:80] = Steering Tag (TUSER.steering_tag)
  assign module_in_metadata[511:464] = timestamp[47:0];
  assign module_in_metadata[463:448] = 16'b0;
  assign module_in_metadata[447:400] = total_hmac_received_requests_count[47:0];
  assign module_in_metadata[399:96] = 304'b0;
  assign module_in_metadata[95:80] = input_buffer_meta_rdata[47:32];
  assign module_in_metadata[79:64] = input_buffer_meta_rdata[31:16];
  assign module_in_metadata[63:0] = kbuffer_dout; // kbuffer out is already stable when sampled into module_in_data.
  assign module_in_data = current_out_hmac_metadata ? module_in_metadata : input_buffer_rdata[515:0];
  
  assign current_out_last = input_buffer_rdata[513];
  assign message_afubypass_data = input_buffer_rdata[515:0];
  assign message_afubypass_last = input_buffer_rdata[513];

  wire force_afubypass, module_in_force_modulebypass, module_in_force_corebypass;
  assign force_afubypass = (afu_ctrl0[19:18] == FORCE_AFU_BYPASS) ? 1'b1 : 1'b0;
  assign module_in_force_modulebypass = (afu_ctrl0[19:18] == FORCE_MODULE_BYPASS) ? 1'b1 : 1'b0;
  assign module_in_force_corebypass = (afu_ctrl0[19:18] == FORCE_CORE_BYPASS) ? 1'b1 : 1'b0;
  reg  current_out_hmac_metadata;


  // =====================================================
  // Message_Out State Machine
  // =====================================================
  // A full message is read from local buffer and written to the selected zuc module
  // A message transfer is triggered if there is at least 1 full message in either of the channels input_queues,
  // and the target zuc module omplies to:
  // 1. The zuc_module is enabled
  // 2. There is sufficient space in its fifo_in to host the selected message size, 
  // 3. Depending on the selected arbitration mode (zuc_ctrl0[17:16]): the zuc module is the least loaded, among all zuc modules
  localparam [3:0]
    CHANNEL_OUT_IDLE        = 4'b0000,
    CHANNEL_OUT_SELECT      = 4'b0001,
    CHANNEL_OUT_HEADER      = 4'b0011,
    FIFO_IN_SELECT          = 4'b0100,
    FIFO_IN_WRITE_METADATA  = 4'b0110,
    CHANNEL_OUT_PROGRESS    = 4'b0111,
    CHANNEL_AFUBYPASS       = 4'b1000,
    CHANNEL_OUT_DROP        = 4'b1001,
    CHANNEL_OUT_EOM         = 4'b1010;

  always @(posedge clk) begin
    if (reset || afu_reset) begin
      message_out_nstate <= CHANNEL_OUT_IDLE;
      update_channel_out_regs <= 0;
      update_fifo_in_regs <= 0;
      current_out_eom <= 0;
      current_out_som <= 1;  // ???? Is out_som reg needed?
      current_out_message_size <= 0;
      current_fifo_in_message_size <= 0;
      current_fifo_in_message_words <= 0;
      current_fifo_in_message_lines <= 0;
      current_fifo_in_message_status <= 0;
      current_fifo_in_message_cmd <= MESSAGE_CMD_NOP; // == 8'h00 == MESSAGE_CMD_CONF
      current_out_chid[3:0] <= 4'b0000;
      current_out_head <= 13'h0000;
      current_out_head_incremented <= 0;
      current_fifo_in_id <= NUM_MODULES - 1; // Default to the last instantiated module, such that next selected module is the successive module (i.e: 0)
      current_fifo_in_header <= 1'b0;
      current_fifo_in_eth_header <= 1'b0;
      fifo_in_readyQ  <= 0;
      module_in_valid  <= 0;
      fifo_in_full[0] <= 0;
      fifo_in_full[1] <= 0;
      fifo_in_full[2] <= 0;
      fifo_in_full[3] <= 0;
      fifo_in_full[4] <= 0;
      fifo_in_full[5] <= 0;
      fifo_in_full[6] <= 0;
      fifo_in_full[7] <= 0;
      message_afubypass_pending <= 1'b0;
      message_afubypass_valid <= 1'b0;
      input_buffer_rden <= 1'b0; // TBD: Power optimization: Consider enabling input buffer read upon need only
      input_buffer_read_latency <= 3'b000;
      current_fifo_in_message_ok <= 1'b0;
      current_fifo_in_message_type <= 1'b0;
      current_out_hmac_metadata <= 1'b0;
      total_hmac_queue0_received_data <= 64'b0;
      total_hmac_queue0_received_delta <= 33'b0;
      total_hmac_queue0_received_requests <= 48'b0;
      total_hmac_queue1_received_data <= 64'b0;
      total_hmac_queue1_received_delta <= 33'b0;
      total_hmac_queue1_received_requests <= 48'b0;
      queues_priority_on <= 1'b0;
    end

    else begin
      if (clear_hmac_message_counters)
	// Cleared via afu_ctrl3
	begin
	  total_hmac_queue0_received_data <= 64'b0;
	  total_hmac_queue0_received_delta <= 33'b0;
	  total_hmac_queue0_received_requests <= 48'b0;
	  total_hmac_queue1_received_data <= 64'b0;
	  total_hmac_queue1_received_delta <= 33'b0;
	  total_hmac_queue1_received_requests <= 48'b0;
	end

      if (messages_queue0_high_watermark && messages_queue1_empty || messages_queue1_high_watermark && messages_queue0_empty)
	// If the occupancy diff between queue0 & queue1 is too high, turn off priority.
	// If the occupancy diff between queue0 & queue1 is too high, 
	// While priority is off, the message_out SM will handle all pending messages in queue0/1 
	queues_priority_on <= 1'b0;
      else if (messages_queue0_low_watermark && messages_queue1_low_watermark)
	// both queues are (almost) empty.
	queues_priority_on <= 1'b1;
      
      case (message_out_nstate)
	CHANNEL_OUT_IDLE:
	  // channel ID selection is done outside this SM
	  // Prioritize next channel ID to read from: Look at all chidx_valid bits, and round_robin select next valid channel
	  //   Reminder: chidx_in_message_count > 0 means that chidx has at least one pending message in input buffer
	  
	  begin
	    // Sampling the current status of message_out_validD
	    // Keep in mind that messages_validD is continuously updated by the Packet_In SM,
	    // so it is sampled inorder to priority selection of a temporarily prozen value
	    if (message_out_validD)
	      // There is at least 1 valid message in input buffer
	      begin
		  // Priority scheme is disabled. Revert to the default (round_robin) channel_selection mode
		current_out_chid <= next_out_chid[3:0];
		input_buffer_rden <= 1'b1;
		input_buffer_read_latency <= 3'b000;
		message_out_nstate <= CHANNEL_OUT_SELECT;
	      end
	    else 
	      input_buffer_rden <= 1'b0;
	  end
	
	CHANNEL_OUT_SELECT:
	  begin
	    // Sample the selected channel arguments
	    current_out_head <= current_out_headD;
	    
	    // After selecting chid to read a message from, it is time to select the candidate target zuc
	    // We cannot select the target zuc along with the message source, since we need the source message size for the zuc selection,
	    // and that message size is valid only after selecting the message source
	    
	    // zuc module selection: Round_robin around all zuc modules, whose fifo_in has sufficient space to host the selected message_size
	    // The selection is done ouside this SM, with dedicated logic, and sampled at next state.

	    if (input_buffer_read_latency > 0)
	      // input_buffer read latency is 1 clock
	      message_out_nstate <= CHANNEL_OUT_HEADER;
	    else 
	      input_buffer_read_latency <= input_buffer_read_latency + 1;
	    
	  end

	CHANNEL_OUT_HEADER:
	  begin
	    // At this point, the current_out_head pointer is already settled, reading the first message line of the selected chid,
	    // which is the message HEADER.
	    // Extract message size from header. It is required at next state to select a zuc module,
	    // and increment out_head to point to first real line of message

	    current_fifo_in_message_ok <= ~(input_buffer_meta_rdata[0] || input_buffer_meta_rdata[1] || input_buffer_meta_rdata[2]);
	    current_fifo_in_message_type <= input_buffer_rdata[515];
	    current_fifo_in_message_metadata <= input_buffer_meta_rdata[47:0];

	    // Sample message size and cmd, depending on the header type in input_buffer_data[]
	    // hmac: message_size is extracted from the previously saved TUSER.Length
	    current_fifo_in_steering_tag <= input_buffer_meta_rdata[47:32];
	    current_out_message_size <= input_buffer_meta_rdata[31:16];
	    current_fifo_in_message_size <= input_buffer_meta_rdata[31:16];
	    current_fifo_in_message_words <= {2'b0, input_buffer_meta_rdata[31:18]} + (input_buffer_meta_rdata[17:16] > 0); // Message size in 32b ticks
	    current_fifo_in_message_lines <= input_buffer_meta_rdata[31:22] + (input_buffer_meta_rdata[21:16] > 0); // Message size in 512b ticks
	    current_fifo_in_message_flits <= input_buffer_meta_rdata[31:22] + (input_buffer_meta_rdata[21:16] > 0); // Message size in 512b ticks

	    // current_out_head is not incremented following the sample of the header,
	    // since the message header should also be transferred to the selected zuc module
	    
	    // hmac: cmd is meaningless
	    current_fifo_in_message_cmd <= 8'h00;
	    
	    // Merge message metadata (id & status) into either of message header and eth header 
	    current_fifo_in_header <= 1'b1;
	    
	    message_out_nstate <= FIFO_IN_SELECT;
	  end

	FIFO_IN_SELECT:
	  begin
	    // A message is transferred to a certain fifox_in if there is sufficient space to hold the whole message,
	    // and the message cmd is a valid ZUC command
	    // ???? Potential optimization, to eliminate the waste wait here:
	    //      If there is no free zuc to hold the selected message size, then rather than waiting here,
	    //      return to the message selection state, and select other message source with probably smaller message size
	    if (current_fifo_in_message_ok && ~force_afubypass)
	      begin
		if ((fifo_in_free_regD != 8'h00) &&
	            ((current_fifo_in_message_cmd == MESSAGE_CMD_CONF) || (current_fifo_in_message_cmd == MESSAGE_CMD_INTEG) ||
		     (current_fifo_in_message_cmd == MESSAGE_CMD_MODULEBYPASS)))
		  // There is a fifox_in with sufficient space to hold the current message, and same fifx_in has more free_space than other fifox_in
		  // Current message is a valid message to be loaded to fifox_in
		  // Note: NODULEBYPASS command is handled inside the zuc_module
		  //
		  // TBD: Add remaining prerequisites for delivering a message to ZUC modules: 
		  // AFU_ID, message_size min/max boundaries, ...
		  begin
		    // There is at least one zuc module available to accept the selected message
		    current_fifo_in_id <= next_fifo_in_id[2:0]; // MOD 8

		    // First flit to module_in will be the hmac metadata
		    current_out_hmac_metadata <= 1'b1;
		    module_in_valid     <= 1'b1;

		    message_out_nstate <= FIFO_IN_WRITE_METADATA;
		  end
		
		else if  (current_fifo_in_message_cmd == MESSAGE_CMD_AFUBYPASS)
		  // Bypass the whole zuc modules. Transfer the message to sbu2pci 
		  begin
		    // Signal to Output Control that there is a message pending for bypass
		    // message_afubypass_pending indication is kept asserted thru all the bypass process 
		    // At this point, the current_out_head pointer is already settled, reading the first message line of bypassed message
		    message_afubypass_pending <= 1'b1;
		    message_afubypass_valid  <= 1'b1;
		    message_out_nstate <= CHANNEL_AFUBYPASS;
		  end
	      end

	    else
	      // AFU is bypassed when the message not OK, or an AFU bypass has been forced (afu_ctrl0[19:18] == FORCE_AFU_BYPASS)
	      // A message is not OK, if either of:
	      // 1. Unsupported opcode
	      // 2. Message_size (header[495:480]) do not match actual length
	      // 3. Message size > 9KB
	      begin
		message_afubypass_pending <= 1'b1;
		message_afubypass_valid  <= 1'b1;
		message_out_nstate <= CHANNEL_AFUBYPASS;
	      end
	  end
	
	FIFO_IN_WRITE_METADATA:
	  begin
	    // Dedicated cycle to write hmac metadata to module_in
	    // Writing hma metadata to module_in as the first hmac packet flit
	    current_out_hmac_metadata <= 1'b0;

	    // Preparing for first transfer from input bufefr to module_in*:
	    module_in_valid  <= 1'b1;
	    current_out_head <= (current_out_head & 13'h1e00) | ((current_out_head + 1) & 13'h01ff);
	    current_out_head_incremented <= 1'b1;
	    current_fifo_in_message_size <= current_fifo_in_message_size - FIFO_LINE_SIZE;
	    current_fifo_in_message_flits <=  current_fifo_in_message_flits - 10'h001;

	    message_out_nstate <= CHANNEL_OUT_PROGRESS;
	  end

	CHANNEL_OUT_PROGRESS:
          // One clock per flit write to fifo_in
	  // This option assumes:
	  // 1. current_fifo_in_message_flits already updated with the current packet size (in flits) to be transferred
	  // 2. The target fifo_in free space aleady verified to host the complete transferred packet
	  //    So that fifo_in_ready is not checked during this flow !!!

	  begin
	    current_fifo_in_header <= 1'b0;
	    current_out_hmac_metadata <= 1'b0;

	    if (current_fifo_in_message_flits > 10'h000)
	      // Still more flits to read from input_buffer and to be written to fifo_in
	      begin
		module_in_valid  <= 1'b1;
		current_out_head <= (current_out_head & 13'h1e00) | ((current_out_head + 1) & 13'h01ff);
		current_out_head_incremented <= 1'b1;
		current_fifo_in_message_size <= current_fifo_in_message_size - FIFO_LINE_SIZE;
		current_fifo_in_message_flits <=  current_fifo_in_message_flits - 10'h001;
	      end
	    else
	      begin 
		// end of packet transfer to fif0x_in
		update_channel_out_regs <= 1'b1;
		module_in_valid  <= 1'b0;
		update_fifo_in_regs <= 1'b1;
		current_out_head_incremented <= 1'b0;

		case (current_out_chid)
		  QUEUE0:
		    begin
		      total_hmac_queue0_received_requests <= total_hmac_queue0_received_requests + 1'b1;
		      total_hmac_queue0_received_data <= total_hmac_queue0_received_data + {48'b0, current_out_message_size};
		      if (total_hmac_queue0_received_delta_next[32])
			// When delta counter overflows, both queue0 & queque1 delta's are divide by 2:
			begin
			  total_hmac_queue0_received_delta <= total_hmac_queue0_received_delta >> 1;
			  total_hmac_queue1_received_delta <= total_hmac_queue1_received_delta >> 1;
			end
		      else
			total_hmac_queue0_received_delta <= total_hmac_queue0_received_delta_next;
		    end
		  
		  QUEUE1:
		    begin
		      total_hmac_queue1_received_requests <= total_hmac_queue1_received_requests + 1'b1;
		      total_hmac_queue1_received_data <= total_hmac_queue1_received_data + {48'b0, current_out_message_size};
		      if (total_hmac_queue1_received_delta_next[32])
			// When delta counter overflows, both queue0 & queque1 delta's are divide by 2:
			begin
			  total_hmac_queue0_received_delta <= total_hmac_queue0_received_delta >> 1;
			  total_hmac_queue1_received_delta <= total_hmac_queue1_received_delta >> 1;
			end
		      else
			total_hmac_queue1_received_delta <= total_hmac_queue1_received_delta_next;
		    end	
		  
		  default:
		    begin
		    end
		endcase // case (current_in_chid)
		
		message_out_nstate <= CHANNEL_OUT_EOM;
	      end
	  end

	CHANNEL_AFUBYPASS:
	  // Bypass the selected channel to sbu2pci
	  begin
	    // current_out_head already points to next input_buffer line to be bypassed to sbu2pci
	    // No need to check input_buffer valid: Always Valid one clock after incrementing the input_buffer head pointer

	    if (sbu2pci_axi4stream_rdy && message_afubypass_valid && sbu2pci_afubypass_inprogress)
	      begin
		// sbu2pci has read current input_buffer line, prepare reading next line
		current_fifo_in_header <= 1'b0;
		current_out_head <= (current_out_head & 13'h1e00) | ((current_out_head + 1) & 13'h01ff);
		current_out_head_incremented <= 1'b1;
		// wait at least 1 clock, before incrementing head pointer
		message_afubypass_valid  <= 1'b0;

		if (current_out_last)
		  // To end the bypass, we rely on EOM indication rather than on current_fifo_in_message_size,
		  // since the *size parameter extracted from the message header might not match the actual mesasge size.
		  begin 
		    // Bypass end: Clear bypass indication once the message bypass has completed 
		    update_channel_out_regs <= 1'b1;

		    // hmac: Shortening the SM states round latency:
		    // cancelled EOM state and moved the following cleared signals to the appropriate states
		    message_out_nstate <= CHANNEL_OUT_EOM;
		  end
		else
		  begin
		    // Keep bypassing until end of message
		    // The read pointer is incremented modulo channel_buffer size, to wrap around 9th bit
		    current_fifo_in_message_size <= current_fifo_in_message_size - FIFO_LINE_SIZE;
		  end
	      end
	    else
	      begin
		message_afubypass_valid <= 1'b1;
		current_out_head_incremented <= 1'b0;
	      end
	  end
	
	CHANNEL_OUT_DROP:
	  // Drop current message from selected channel
	  // Message drop scheme:
	  // A message must be fully contained within input buffer
	  // TBD: Drop optimization: 
	  //      Drop directly from pci2sbu port, rather than copying the whole message into input buffer and then be dropped
	  //      Motivation: Better utilization of input buffer space
	  //      To implement this, the dropping mechanism should:
	  //      1. Idenify the message to be dropped, based on an unsupported message_cmd at the message header valid in pci2sbu 
	  //      2. Track the message tuser.context&ID, while receiving packets from pci2sbu
	  //      3. Since interleaved messages between different channels is allowed: 
	  //      3.1. Drop packets belong to same context&ID, while storing the 'good' packets into its designated queue in input buffer
	  //      3.2. Keep in mind that multiple interleaved messages might need to be dropped at the same time
	  begin
	    // The read pointer is incremented modulo channel_buffer size, to wrap around 9th bit
	    current_fifo_in_header <= 1'b0;
	    current_out_head <= (current_out_head & 13'h1e00) | ((current_out_head + 1) & 13'h01ff);
	    current_out_head_incremented <= 1'b1;
	    
	    //if (current_fifo_in_message_size <= FIFO_LINE_SIZE)
	    // 'end_of_message' == Last 64 bytes (or less) have been read
	    // end_of_message indication takes into accout the exact message size being read, as specified in current_fifo_in_message_size
	    // Anyway, full 512b lines are always read, the message_size alignment
	    if (current_out_last)
	      // To end the drop, we rely on EOM indication rather than on current_fifo_in_message_size,
	      // since the *size parameter extracted from the message header might not match the actual mesasge size.
	      begin 
		update_channel_out_regs <= 1'b1;
		// hmac: Shortening the SM states round latency:
		// cancelled EOM state and moved the following cleared signals to the appropriate states
		 message_out_nstate <= CHANNEL_OUT_EOM;
	      end
	    else
	      begin
		// Keep bypassing until end of message
		current_fifo_in_message_size <= current_fifo_in_message_size - FIFO_LINE_SIZE;
	      end
	  end
	
	CHANNEL_OUT_EOM:
	  begin
	    current_out_head_incremented <= 1'b0;
	    current_fifo_in_header <= 1'b0;
	    module_in_valid  <= 0;
	    message_afubypass_valid  <= 1'b0;
	    message_afubypass_pending <= 1'b0;
	    update_channel_out_regs = 1'b0;
	    update_fifo_in_regs = 1'b0;
	    message_out_nstate <= CHANNEL_OUT_IDLE;
	  end
	
	default:
	  begin
	  end
	
      endcase
    end // else: !if(reset || afu_reset)
  end
  


  //zuc modules fifox_out to sbu2pci
  //

  localparam [2:0]
    FIFO0_OUT_TO_SBU2PCI = 3'b000,
    FIFO1_OUT_TO_SBU2PCI = 3'b001,
    FIFO2_OUT_TO_SBU2PCI = 3'b010,
    FIFO3_OUT_TO_SBU2PCI = 3'b011,
    FIFO4_OUT_TO_SBU2PCI = 3'b100,
    FIFO5_OUT_TO_SBU2PCI = 3'b101,
    FIFO6_OUT_TO_SBU2PCI = 3'b110,
    FIFO7_OUT_TO_SBU2PCI = 3'b111;

  //zuc module fifo_out arguments selection
  always @(*) begin
    case (current_fifo_out_id)
      FIFO0_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[0];
	  fifo_out_lastD = fifo_out_last[0];
	  fifo_out_userD = fifo_out_user[0]; // userD is NOT forwarded to sbu2pci. It is used by sbu2pci SM to identify eth headers !! 
	  fifo_out_statusD = fifo_out_status[0];
	end
      FIFO1_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[1];
	  fifo_out_lastD = fifo_out_last[1];
	  fifo_out_userD = fifo_out_user[1];
	  fifo_out_statusD = fifo_out_status[1];
	end
      
      FIFO2_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[2];
	  fifo_out_lastD = fifo_out_last[2];
	  fifo_out_userD = fifo_out_user[2];
	  fifo_out_statusD = fifo_out_status[2];
	end
      
      FIFO3_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[3];
	  fifo_out_lastD = fifo_out_last[3];
	  fifo_out_userD = fifo_out_user[3];
	  fifo_out_statusD = fifo_out_status[3];
	end

      FIFO4_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[4];
	  fifo_out_lastD = fifo_out_last[4];
	  fifo_out_userD = fifo_out_user[4];
	  fifo_out_statusD = fifo_out_status[4];
	end

      FIFO5_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[5];
	  fifo_out_lastD = fifo_out_last[5];
	  fifo_out_userD = fifo_out_user[5];
	  fifo_out_statusD = fifo_out_status[5];
	end

      FIFO6_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[6];
	  fifo_out_lastD = fifo_out_last[6];
	  fifo_out_userD = fifo_out_user[6];
	  fifo_out_statusD = fifo_out_status[6];
	end

      FIFO7_OUT_TO_SBU2PCI:
	begin
	  fifo_out_dataD = fifo_out_data[7];
	  fifo_out_lastD = fifo_out_last[7];
	  fifo_out_userD = fifo_out_user[7];
	  fifo_out_statusD = fifo_out_status[7];
	end

      default: begin
      end
    endcase
  end

  reg [511:0] sbu2pci_ethernet_header;
  reg 	      sbu2pci_ethernet_header_write;
  reg 	      sbu2pci_next_write_is_message_header;
  reg 	      sbu2pci_imessage_header_write;
  reg 	      sbu2pci_cmessage_header_write;

  
  wire [63:0] zuc_out_keep;
  assign zuc_out_keep = (current_fifo_out_message_size >= FIFO_LINE_SIZE) ? FULL_LINE_KEEP : 
			128'hffffffffffffffff0000000000000000 >> current_fifo_out_message_size[5:0];

  assign sbu2pci_last = fifo_out_lastD;

  // fifox_out & input_buffer_bypass to sbu2pci wiring:
  // tkeep is forced to full line in AFUBYPASS
  // hmac module test mode: full lines are written
  assign sbu2pci_axi4stream_tkeep[63:0] = (hmac_test_mode == 3'b100) ? FULL_LINE_KEEP : zuc_out_keep;

  // hmac: sbu2pci_tuser is extracted from packet metadata, first fifo_out_data[] flit
  // hmac: Adding tuser.chnnel_id to sbu2pci: If enabed (in afu_ctrl0[29]), toggle channel_id between successive sbu2pci transactions. See sbu2pci_out SM.
  assign sbu2pci_axi4stream_tuser[71:0] = {current_response_tuser, 55'b0, sbu2pci_channel_id_enable && sbu2pci_channel_id};

  assign sbu2pci_axi4stream_tdata = fifo_out_dataD[511:0];

  assign sbu2pci_axi4stream_vld = sbu2pci_valid;
  assign sbu2pci_axi4stream_tlast = sbu2pci_last;

  // Response message fragmenting:
  // According to Haggai, no need to fragment response messages into 1k packets

  // fif0x_out has a valid message pending if:
  // 1. There is a message pending (message_count > 0)
  // 2. fifo_out_status has a valid output (1 line per each message in fifo_out)
  // 3. The pending message ID for the given chid, is successive to (greater by 1 vs.) previous transferred message for same chid 
  //
  // Notes:
  // 1. fifox_out_message_id is the ID locally generated while assigning the message into the zuc module (added to the message header)
  //    A zero message_id means a non-OK zuc message, for which message ordering is ignored
  // 2. fifox_out_last_message_id is the last written (to sbu2pci) message ID for channel x 
  assign fifo0_out_chid = fifo_out_status[0][7:4];
  assign fifo0_out_message_id = fifo_out_data[0][19:8];
  assign fifo0_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo0_out_chid) & 16'h0001) == 16'h0001) || fifo0_out_message_id == 0) ? 1'b0 : 1'b1;

  // Calculating the next expected message_id:
  // Next message_id is incremented, wrapped around 12th bit count
  // Exception: message_id == 0 is avoided, as it is used to tag non zuc-OK messages
  assign fifo0_out_expected_message_id = (fifo0_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo0_out_last_message_id[11:0] + 1;

  // fifox_last_message_id[] holds the message_id of the last message written to sbu2pci from channel x
  // Notice that the id itself is only 12 bits, while bit 15 is used for last_message_id_valid tagging.
  // The valid tagging is aimed to avoid comparing fifox_out_message_id to a non initialized fifox_out_last_message_id, as happens after reset.
  // The valid bit will be asserted upon first message stored to sbu2pci.
  // message_id == 0 is reserved for tagging non-zucOK messages (bypassed messages, illegal zuc commands, non matching length, length > 9KB) 
  assign fifo0_out_message_id_ok = (fifo0_out_last_message_id[15]) ? (fifo0_out_message_id == fifo0_out_expected_message_id) : 1'b1;
  assign fifo0_out_message_valid = (fifo0_out_message_count > 0) && fifo_out_status_valid[0] && (fifo0_out_message_id_ok || ~fifo0_out_ignored_message_id); 

  assign fifo1_out_chid = fifo_out_status[1][7:4];
  assign fifo1_out_message_id = fifo_out_data[1][19:8];
  assign fifo1_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo1_out_chid) & 16'h0001) == 16'h0001) || fifo1_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo1_out_expected_message_id = (fifo1_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo1_out_last_message_id[11:0] + 1;
  assign fifo1_out_message_id_ok = (fifo1_out_last_message_id[15]) ? (fifo1_out_message_id == fifo1_out_expected_message_id) : 1'b1;
  assign fifo1_out_message_valid = (fifo1_out_message_count > 0) && fifo_out_status_valid[1] && (fifo1_out_message_id_ok || ~fifo1_out_ignored_message_id);

  assign fifo2_out_chid = fifo_out_status[2][7:4];
  assign fifo2_out_message_id = fifo_out_data[2][19:8];
  assign fifo2_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo2_out_chid) & 16'h0001) == 16'h0001) || fifo2_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo2_out_expected_message_id = (fifo2_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo2_out_last_message_id[11:0] + 1;
  assign fifo2_out_message_id_ok = (fifo2_out_last_message_id[15]) ? (fifo2_out_message_id == fifo2_out_expected_message_id) : 1'b1;
  assign fifo2_out_message_valid = (fifo2_out_message_count > 0) && fifo_out_status_valid[2] && (fifo2_out_message_id_ok || ~fifo2_out_ignored_message_id);

  assign fifo3_out_chid = fifo_out_status[3][7:4];
  assign fifo3_out_message_id = fifo_out_data[3][19:8];
  assign fifo3_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo3_out_chid) & 16'h0001) == 16'h0001) || fifo3_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo3_out_expected_message_id = (fifo3_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo3_out_last_message_id[11:0] + 1;
  assign fifo3_out_message_id_ok = (fifo3_out_last_message_id[15]) ? (fifo3_out_message_id == fifo3_out_expected_message_id) : 1'b1;
  assign fifo3_out_message_valid = (fifo3_out_message_count > 0) && fifo_out_status_valid[3] && (fifo3_out_message_id_ok || ~fifo3_out_ignored_message_id);

  assign fifo4_out_chid = fifo_out_status[4][7:4];
  assign fifo4_out_message_id = fifo_out_data[4][19:8];
  assign fifo4_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo4_out_chid) & 16'h0001) == 16'h0001) || fifo4_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo4_out_expected_message_id = (fifo4_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo4_out_last_message_id[11:0] + 1;
  assign fifo4_out_message_id_ok = (fifo4_out_last_message_id[15]) ? (fifo4_out_message_id == fifo4_out_expected_message_id) : 1'b1;
  assign fifo4_out_message_valid = (fifo4_out_message_count > 0) && fifo_out_status_valid[4] && (fifo4_out_message_id_ok || ~fifo4_out_ignored_message_id);

  assign fifo5_out_chid = fifo_out_status[5][7:4];
  assign fifo5_out_message_id = fifo_out_data[5][19:8];
  assign fifo5_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo5_out_chid) & 16'h0001) == 16'h0001) || fifo5_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo5_out_expected_message_id = (fifo5_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo5_out_last_message_id[11:0] + 1;
  assign fifo5_out_message_id_ok = (fifo5_out_last_message_id[15]) ? (fifo5_out_message_id == fifo5_out_expected_message_id) : 1'b1;
  assign fifo5_out_message_valid = (fifo5_out_message_count > 0) && fifo_out_status_valid[5] && (fifo5_out_message_id_ok || ~fifo5_out_ignored_message_id);

  assign fifo6_out_chid = fifo_out_status[6][7:4];
  assign fifo6_out_message_id = fifo_out_data[6][19:8];
  assign fifo6_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo6_out_chid) & 16'h0001) == 16'h0001) || fifo6_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo6_out_expected_message_id = (fifo6_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo6_out_last_message_id[11:0] + 1;
  assign fifo6_out_message_id_ok = (fifo6_out_last_message_id[15]) ? (fifo6_out_message_id == fifo6_out_expected_message_id) : 1'b1;
  assign fifo6_out_message_valid = (fifo6_out_message_count > 0) && fifo_out_status_valid[6] && (fifo6_out_message_id_ok || ~fifo6_out_ignored_message_id);

  assign fifo7_out_chid = fifo_out_status[7][7:4];
  assign fifo7_out_message_id = fifo_out_data[7][19:8];
  assign fifo7_out_ignored_message_id = ((((afu_ctrl2[15:0] >> fifo7_out_chid) & 16'h0001) == 16'h0001) || fifo7_out_message_id == 0) ? 1'b0 : 1'b1;
  assign fifo7_out_expected_message_id = (fifo7_out_last_message_id[11:0] == 12'hfff) ? 12'h001 : fifo7_out_last_message_id[11:0] + 1;
  assign fifo7_out_message_id_ok = (fifo7_out_last_message_id[15]) ? (fifo7_out_message_id == fifo7_out_expected_message_id) : 1'b1;
  assign fifo7_out_message_valid = (fifo7_out_message_count > 0) && fifo_out_status_valid[7] && (fifo7_out_message_id_ok || ~fifo7_out_ignored_message_id);

  // There is at least one valid message pending in either of fifox_out, ready to be transferred to sbu2pci
  //  assign fifo_out_message_validD = fifo7_out_message_valid || fifo6_out_message_valid || fifo5_out_message_valid || fifo4_out_message_valid ||
  //				   fifo3_out_message_valid || fifo2_out_message_valid || fifo1_out_message_valid || fifo0_out_message_valid;
  //  assign fifo_out_message_valid_regD[7:0] = {fifo7_out_message_valid, fifo6_out_message_valid, fifo5_out_message_valid, fifo4_out_message_valid,
  //					     fifo3_out_message_valid, fifo2_out_message_valid, fifo1_out_message_valid, fifo0_out_message_valid};
  //  assign fifo_out_message_valid_doubleregD = {fifo_out_message_valid_regD, fifo_out_message_valid_regD};
  assign fifo_out_message_validD = fifo_out_valid[7] || fifo_out_valid[6] || fifo_out_valid[5] || fifo_out_valid[4] ||
				   fifo_out_valid[3] || fifo_out_valid[2] || fifo_out_valid[1] || fifo_out_valid[0];
  assign fifo_out_message_valid_regD[7:0] = {fifo_out_valid[7], fifo_out_valid[6], fifo_out_valid[5], fifo_out_valid[4],
				             fifo_out_valid[3], fifo_out_valid[2], fifo_out_valid[1], fifo_out_valid[0]};
  assign fifo_out_message_valid_doubleregD = {fifo_out_message_valid_regD, fifo_out_message_valid_regD};
  
  always @(*) begin
    // Find next roun-robin zuc unit with at least one full message, starting from latter fifo_in_id
    if (fifo_out_message_valid_doubleregD[current_fifo_out_id+1])
      fifo_out_id_delta = 1;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+2])
      fifo_out_id_delta = 2;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+3])
      fifo_out_id_delta = 3;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+4])
      fifo_out_id_delta = 4;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+5])
      fifo_out_id_delta = 5;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+6])
      fifo_out_id_delta = 6;
    else if (fifo_out_message_valid_doubleregD[current_fifo_out_id+7])
      fifo_out_id_delta = 7;
    else
      // We are back to same fifo_in_id.
      // Keep same id value
      fifo_out_id_delta = 0;
  end // always @ begin


  // Messages ordering:
  // ================
  // Per each channel, keep track of last message ID which has been transferred to sbu2pci
  //    chidx_last_message_id[9:0], x E {0..15}.
  // If there is a message pending (fifox_out_message_count > 0)
  //    then this info is avaiable:
  //    1. fifox_out_data[15:12] - channel_id[3:0]
  //    2. fifox_out[11:2]       - message_id[9:0]
  //
  // For messages ordering, for the above channel_id[], verify that 
  //    last_message_id[] = lookup(chidx_last_message_id[], channel_id[]) // Return channel_id[] reg of channel x 
  //    if (message_id[] == last_message_id[] + 1)
  //       then fifox_out pending message is valid for transfer to sbu2pci !!
  //    round_robin select among all valid fifox_out     
  //    upon end of transfer:
  //       update chidx_last_message_id[] = message_id[]


  //=================================================================================================================
  // fifox_out to sbu2pci State Machine: Message read from selected zuc output to sbu2pci port
  //=================================================================================================================
  // A zuc output fifo is candidate for being selected only if hosts at least one full message.
  localparam [2:0]
    SBU2PCI_OUT_IDLE        = 3'b000,
    SBU2PCI_OUT_SELECT2     = 3'b010,
    SBU2PCI_OUT_HEADER      = 3'b011,
    SBU2PCI_OUT_NEXT_FLIT   = 3'b100,
    SBU2PCI_OUT_WAIT_READY  = 3'b101,
    SBU2PCI_AFUBYPASS       = 3'b110,
    SBU2PCI_OUT_EOM         = 3'b111;

  always @(posedge clk) begin
    if (reset || afu_reset) begin
      sbu2pci_out_nstate <= SBU2PCI_OUT_IDLE;
      current_fifo_out_id <= 4'h0;
      current_fifo_out_message_size <= 16'b0;
      // current_fifo_out_message_size_progress <= 0; // Used for large message fragmentation into smaller packets
      module_out_ready <= 1'b0;
      module_out_status_ready <= 1'b0;
      sbu2pci_afubypass_inprogress <= 1'b0;
      sbu2pci_ethernet_header_write <= 1'b0;
      sbu2pci_imessage_header_write <= 1'b0;
      sbu2pci_cmessage_header_write <= 1'b0;
      sbu2pci_next_write_is_message_header <= 1'b0;
      sbu2pci_valid <= 1'b0;
      sbu2pci_pushback <= 1'b0;
      update_fifo_out_regs = 1'b0;
      current_fifo_out_chid <= 4'h0;
      total_hmac_forwarded_requests_count <= 48'b0;
      total_afubypass_message_count <= 36'b0;
      hist_sbu2pci_response_event <= 1'b0;
      hist_sbu2pci_response_event_size <= 16'h0000;
      sbu2pci_channel_id <= 1'b0;
    end

    else begin
      if (clear_hmac_message_counters)
	// Cleared via afu_ctrl3
	total_hmac_forwarded_requests_count <= 48'b0;

      case (sbu2pci_out_nstate)
	SBU2PCI_OUT_IDLE:
	  begin
	    // hmac: EOM state merged here
	    hist_sbu2pci_response_event <= 1'b0;
	    module_out_ready  <= 1'b0;
	    module_out_status_ready <= 1'b0;
	    sbu2pci_ethernet_header_write <= 1'b0;
	    sbu2pci_next_write_is_message_header <= 1'b0;
	    sbu2pci_imessage_header_write <= 1'b0;
	    sbu2pci_cmessage_header_write <= 1'b0;
	    sbu2pci_valid <= 1'b0;
	    sbu2pci_pushback <= 1'b0;
	    sbu2pci_afubypass_inprogress <= 1'b0;
	    update_fifo_out_regs = 1'b0;

	    //	    if (fifo_out_message_validD || message_afubypass_pending)
	    // hmac: No bypass
	    if (fifo_out_message_validD)
	      // There is at least 1 valid message in zuc output fifos,
	      // or a message in input_buffer with CMD == 3 (full message bypass)
	      begin
		if (message_afubypass_pending)
		  begin
		    // At this point, message_afubypass_data already valid with first line (header) valid.
		    // Extract the message size 
		    current_fifo_out_message_size <= message_afubypass_data[39:24] + message_afubypass_data[515] ? 'd64 : 'd128; // Adding the message/eth headers length
		    sbu2pci_afubypass_inprogress <= 1'b1;
		    sbu2pci_out_nstate <= SBU2PCI_AFUBYPASS;
		  end

		else
		  begin		
		    current_fifo_out_id <= next_fifo_out_id;
		    
		    
		    // Drop the  metadata line
		    // In hmac_module_test_mode, the metadata line is NOT dropped, but rather written to sbu2pci
		    module_out_ready <= (hmac_test_mode == 3'b100) ? 1'b0 : 1'b1;
		    
		    sbu2pci_out_nstate <= SBU2PCI_OUT_SELECT2;
		  end
	      end
	  end

	SBU2PCI_OUT_SELECT2:
	  begin
	    current_fifo_out_message_size <= fifo_out_dataD[79:64]; // Message size in bytes. NOT including the metadata line !!
	    current_response_tuser <= fifo_out_dataD[95:80]; // Steering tag
	    
	    module_out_ready  <= 1'b0; // metadata line dropped
	    sbu2pci_out_nstate <= SBU2PCI_OUT_HEADER;
	  end
	
	SBU2PCI_OUT_HEADER:
	  begin
	    // First line of a message in fifox_out is always a 512b header
	    // This line is read and updated, before being written to sbu2pci
	    //
	    // Extract message size from header, then read (drop) first line from the selected fifo
	    // In CMD_INTEG, the out message_size is fixed to full 512b line.
	    // In CMD_CONF, the output message_size is the original message size (no need to add the header length since the header is being written in current state)
	    // Notice that fifox_out_valid is not checked, since this transfer is initiated only if the selected fifo hosts at least one full message

	    // sbu2pci_message_size histogram: Set the sbu2pci_message_size event arguments
	    // Sample the respone payload size, : If INTEG response then set size = 0, otherwise deduct the header length.
	    hist_sbu2pci_response_event_size <= (current_response_cmd == MESSAGE_CMD_INTEG) ? 0 : current_fifo_out_message_size - 64; 
	    hist_sbu2pci_response_event_chid <= current_fifo_out_chid;

	    if (sbu2pci_axi4stream_rdy)
	      // Wait here as long as sbu2pci did not capture this line
	      begin
		sbu2pci_valid <= 1'b1;
		sbu2pci_pushback <= 1'b0;
		module_out_ready  <= 1'b1;
		module_out_status_ready <= 1'b1;

		// hmac: Ethernet only messages
		sbu2pci_next_write_is_message_header <= 1'b1;
		sbu2pci_out_nstate <= SBU2PCI_OUT_NEXT_FLIT;
	      end
	    else
	      // An attempt to write to sbu2pci is done here, while sbu2pci is not ready, pushback...
	      sbu2pci_pushback <= 1'b1;
	  end

	SBU2PCI_OUT_NEXT_FLIT:
	  begin
	    sbu2pci_ethernet_header_write <= 1'b0;
	    sbu2pci_imessage_header_write <= 1'b0;
	    sbu2pci_cmessage_header_write <= 1'b0;
	    sbu2pci_valid <= 1'b0;
	    sbu2pci_pushback <= 1'b0;
	    module_out_ready  <= 1'b0;
	    module_out_status_ready <= 1'b0;

	    if (sbu2pci_last)
	      // To terminate, we rely on EOM indication, rather than on *message_size, since the *size might not match the actual message size.
	      begin
		module_out_ready  <= 1'b0;
		update_fifo_out_regs = 1'b1;
		total_hmac_forwarded_requests_count <= total_hmac_forwarded_requests_count + 1;
		hist_sbu2pci_response_event <= 1'b1;
		sbu2pci_channel_id <= ~sbu2pci_channel_id;

		// hmac: To save 1 state, EOM state merged into IDLE
		// sbu2pci_out_nstate <= SBU2PCI_OUT_EOM;
		sbu2pci_out_nstate <= SBU2PCI_OUT_IDLE;
	      end
	    else
	      begin
		current_fifo_out_message_size <= current_fifo_out_message_size - FIFO_LINE_SIZE;
		sbu2pci_out_nstate <= SBU2PCI_OUT_WAIT_READY;
	      end
	  end
	
	SBU2PCI_OUT_WAIT_READY:
	  begin
	    if (sbu2pci_next_write_is_message_header)
	      begin
		sbu2pci_next_write_is_message_header <= 1'b0;
		if (current_response_cmd == MESSAGE_CMD_INTEG)
		  sbu2pci_imessage_header_write <= 1'b1;
		else if (current_response_cmd == MESSAGE_CMD_CONF)
		  sbu2pci_cmessage_header_write <= 1'b1;
		else
		  begin
		    // Module bypass command
		    sbu2pci_imessage_header_write <= 1'b0;
		    sbu2pci_cmessage_header_write <= 1'b0;
		  end
	      end

	    if (sbu2pci_axi4stream_rdy)
	      begin
		// Read from the selected fifox_out and write to sbu2pci, as long as sbu2pci is ready
		// No need to check fifox_out_valid, since we already selected a fifox_out which has at least one full message
		//
		// The read from fifox_out is put here (rather than as random logic outside this block) to avoid potential read glitches
		module_out_ready  <= 1'b1;

		// According to Haggai, no need to fragment response message:
		// if (current_fifo_out_message_size_progress >= MAX_PACKET_SIZE)
		// Message fragmetation to 1K packets.
		// sbu2pci_axi4stream_tlast will be asserted once this size crosses the predefined max_packet size
		// From this state machine point of view, the whole message is transferred as one piece of data.
		// This SM does not care that tlast is asserted at 1K boundaries.
		// Once tlast has been asserted, the uccessive fragment (packet) will immediately follow the one just being marked with tlast
		// tlast is asynchronously generated, outside  block.
		//
		// Keep reading till end of message
		sbu2pci_valid <= 1'b1;
		sbu2pci_pushback <= 1'b0;
		sbu2pci_out_nstate <= SBU2PCI_OUT_NEXT_FLIT;
	      end // if (sbu2pci_axi4stream_rdy)
	    
	    else
	      begin
		// sbu2pci not ready, pushback wait...
		sbu2pci_valid <= 1'b0;

		// An attempt to write to sbu2pci is done here, while sbu2pci is not ready, pushback...
		sbu2pci_pushback <= 1'b1;
		module_out_ready  <= 1'b0;
	      end
	  end

	SBU2PCI_AFUBYPASS:
	  // ZUC modules bypass: Transfer Inpur Steer buffer output directly to pci2sbu output.
	  // First line of a message is always a 512b header
	  // unlike in normal mode, the header flit IS transferred to sbu2pci !!!
	  begin
	    if (sbu2pci_axi4stream_rdy & message_afubypass_valid)
	      begin
		// sbu2pci data, keep, last are handled by external logic 		
		if (message_afubypass_last)
		  // To end the bypass, we rely on EOM indication rather than on *message_size, since the *size might not match the actual size
		  begin
		    total_afubypass_message_count <= total_afubypass_message_count + 1;
		    // hmac: To save 1 state, EOM state merged into IDLE
		    // sbu2pci_out_nstate <= SBU2PCI_OUT_EOM;
		    sbu2pci_out_nstate <= SBU2PCI_OUT_IDLE;
		  end
		else
		  // Keep reading till end of message
		  current_fifo_out_message_size <= current_fifo_out_message_size - FIFO_LINE_SIZE;
	      end
	  end
	
	SBU2PCI_OUT_EOM:
	  begin
	    hist_sbu2pci_response_event <= 1'b0;
	    module_out_ready  <= 1'b0;
	    module_out_status_ready <= 1'b0;
	    sbu2pci_ethernet_header_write <= 1'b0;
	    sbu2pci_next_write_is_message_header <= 1'b0;
	    sbu2pci_imessage_header_write <= 1'b0;
	    sbu2pci_cmessage_header_write <= 1'b0;
	    sbu2pci_valid <= 1'b0;
	    sbu2pci_pushback <= 1'b0;
	    sbu2pci_afubypass_inprogress <= 1'b0;
	    update_fifo_out_regs = 1'b0;
	    sbu2pci_out_nstate <= SBU2PCI_OUT_IDLE;
	  end

  	default: begin
	end
      endcase

    end // else: !if(reset || afu_reset)
  end // always @ (posedge clk)
  
  // Accumulating modules update_regs indications from all modules
  // Required formtotal_hmac_requests_pass and total_hmac_requests_drop counts
  wire [31:0] modules_3_0_pass_s;
  wire [31:0] modules_7_4_pass_s;
  wire [31:0] modules_7_0_pass_s;
  wire [31:0] modules_3_0_pass_c;
  wire [31:0] modules_7_4_pass_c;
  wire [31:0] modules_7_0_pass_c;
  wire [31:0] total_modules_pass_count;
  wire [31:0] modules_3_0_drop_s;
  wire [31:0] modules_7_4_drop_s;
  wire [31:0] modules_7_0_drop_s;
  wire [31:0] modules_3_0_drop_c;
  wire [31:0] modules_7_4_drop_c;
  wire [31:0] modules_7_0_drop_c;
  wire [31:0] total_modules_drop_count;

csa_32x4 modules_3_0_pass_count(
		    .in1({31'b0, update_zuc_module_regs[3] && hmac_match[3]}),
		    .in2({31'b0, update_zuc_module_regs[2] && hmac_match[2]}),
		    .in3({31'b0, update_zuc_module_regs[1] && hmac_match[1]}),
		    .in4({31'b0, update_zuc_module_regs[0] && hmac_match[0]}),
		    .sum(modules_3_0_pass_s),
		    .carry(modules_3_0_pass_c)
		    );
csa_32x4 modules_7_4_pass_count(
		    .in1({31'b0, update_zuc_module_regs[7] && hmac_match[7]}),
		    .in2({31'b0, update_zuc_module_regs[6] && hmac_match[6]}),
		    .in3({31'b0, update_zuc_module_regs[5] && hmac_match[5]}),
		    .in4({31'b0, update_zuc_module_regs[4] && hmac_match[4]}),
		    .sum(modules_7_4_pass_s),
		    .carry(modules_7_4_pass_c)
		    );
csa_32x4 modules_7_0_pass_count(
		    .in1(modules_3_0_pass_s),
		    .in2({modules_3_0_pass_c[31:1], 1'b0}),
		    .in3(modules_7_4_pass_s),
		    .in4({modules_7_4_pass_c[31:1], 1'b0}),
		    .sum(modules_7_0_pass_s),
		    .carry(modules_7_0_pass_c)
		    );
assign total_modules_pass_count = modules_7_0_pass_s + {modules_7_0_pass_c[31:1], 1'b0};

csa_32x4 modules_3_0_drop_count(
		    .in1({31'b0, update_zuc_module_regs[3] && ~hmac_match[3]}),
		    .in2({31'b0, update_zuc_module_regs[2] && ~hmac_match[2]}),
		    .in3({31'b0, update_zuc_module_regs[1] && ~hmac_match[1]}),
		    .in4({31'b0, update_zuc_module_regs[0] && ~hmac_match[0]}),
		    .sum(modules_3_0_drop_s),
		    .carry(modules_3_0_drop_c)
		    );
csa_32x4 modules_7_4_drop_count(
		    .in1({31'b0, update_zuc_module_regs[7] && ~hmac_match[7]}),
		    .in2({31'b0, update_zuc_module_regs[6] && ~hmac_match[6]}),
		    .in3({31'b0, update_zuc_module_regs[5] && ~hmac_match[5]}),
		    .in4({31'b0, update_zuc_module_regs[4] && ~hmac_match[4]}),
		    .sum(modules_7_4_drop_s),
		    .carry(modules_7_4_drop_c)
		    );
csa_32x4 modules_7_0_drop_count(
		    .in1(modules_3_0_drop_s),
		    .in2({modules_3_0_drop_c[31:1], 1'b0}),
		    .in3(modules_7_4_drop_s),
		    .in4({modules_7_4_drop_c[31:1], 1'b0}),
		    .sum(modules_7_0_drop_s),
		    .carry(modules_7_0_drop_c)
		    );
assign total_modules_drop_count = modules_7_0_drop_s + {modules_7_0_drop_c[31:1], 1'b0};
  

//fifo_out to sbu2pci arguments update
  always @(posedge clk) begin
    if (reset || afu_reset) begin
      // fifo_out message_count is a common register to both zuc write to fifox_out & read to sbu2pci operations.
      // Both write&read/to&from fifox_out state machines affect this count register.
      // Unsigned count, max 256 messages/channel: 512 (=8K/16) entries/channel, minimum 1024b (two fifo lines)/message
      fifo0_out_message_count[8:0] <= 0;
      fifo1_out_message_count[8:0] <= 0;
      fifo2_out_message_count[8:0] <= 0;
      fifo3_out_message_count[8:0] <= 0;
      fifo4_out_message_count[8:0] <= 0;
      fifo5_out_message_count[8:0] <= 0;
      fifo6_out_message_count[8:0] <= 0;
      fifo7_out_message_count[8:0] <= 0;

      total_fifo0_out_message_count <= 32'b0;
      total_fifo1_out_message_count <= 32'b0;
      total_fifo2_out_message_count <= 32'b0;
      total_fifo3_out_message_count <= 32'b0;
      total_fifo4_out_message_count <= 32'b0;
      total_fifo5_out_message_count <= 32'b0;
      total_fifo6_out_message_count <= 32'b0;
      total_fifo7_out_message_count <= 32'b0;
      total_hmac_requests_match_count <= 48'b0;
      total_hmac_requests_nomatch_count <= 48'b0;

      // Recording last valid (valid == ordered) message ID read from either of fifox_out, to be written to sbu2pci
      // MSbit is the id valid indication
      chid0_last_message_id[15:0] <= 16'h8000;
      chid1_last_message_id[15:0] <= 16'h8000;
      chid2_last_message_id[15:0] <= 16'h8000;
      chid3_last_message_id[15:0] <= 16'h8000;
      chid4_last_message_id[15:0] <= 16'h8000;
      chid5_last_message_id[15:0] <= 16'h8000;
      chid6_last_message_id[15:0] <= 16'h8000;
      chid7_last_message_id[15:0] <= 16'h8000;
      chid8_last_message_id[15:0] <= 16'h8000;
      chid9_last_message_id[15:0] <= 16'h8000;
      chid10_last_message_id[15:0] <= 16'h8000;
      chid11_last_message_id[15:0] <= 16'h8000;
      chid12_last_message_id[15:0] <= 16'h8000;
      chid13_last_message_id[15:0] <= 16'h8000;
      chid14_last_message_id[15:0] <= 16'h8000;
      chid15_last_message_id[15:0] <= 16'h8000;
    end
    
    else begin
      // Statistics mesasge counts
      total_fifo0_out_message_count <= update_zuc_module_regs[0] ? total_fifo0_out_message_count + 1 : total_fifo0_out_message_count;
      total_fifo1_out_message_count <= update_zuc_module_regs[1] ? total_fifo1_out_message_count + 1 : total_fifo1_out_message_count;
      total_fifo2_out_message_count <= update_zuc_module_regs[2] ? total_fifo2_out_message_count + 1 : total_fifo2_out_message_count;
      total_fifo3_out_message_count <= update_zuc_module_regs[3] ? total_fifo3_out_message_count + 1 : total_fifo3_out_message_count;
      total_fifo4_out_message_count <= update_zuc_module_regs[4] ? total_fifo4_out_message_count + 1 : total_fifo4_out_message_count;
      total_fifo5_out_message_count <= update_zuc_module_regs[5] ? total_fifo5_out_message_count + 1 : total_fifo5_out_message_count;
      total_fifo6_out_message_count <= update_zuc_module_regs[6] ? total_fifo6_out_message_count + 1 : total_fifo6_out_message_count;
      total_fifo7_out_message_count <= update_zuc_module_regs[7] ? total_fifo7_out_message_count + 1 : total_fifo7_out_message_count;
      
      if (clear_hmac_message_counters)
	begin
	  total_hmac_requests_match_count <= 48'b0;
	  total_hmac_requests_nomatch_count <= 48'b0;
	end
      else
	begin
	  // Total out_mesage count: incremented per each of the asserted bits in update_zuc_module_regs[].
	  // Notice that more than one asserted bit in update_zuc_module_regs[] at a time is possible !!!!  
	  // Implementation note:
	  // The following is an adder of 8 single-bit operands. Replace this with csa tree, if timing-wise needed.
	  //					 (update_zuc_module_regs[7] && hmac_match[7]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[6] && hmac_match[6]) ? 1'b1 : 1'b0 +
	  //					 (update_zuc_module_regs[5] && hmac_match[5]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[4] && hmac_match[4]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[3] && hmac_match[3]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[2] && hmac_match[2]) ? 1'b1 : 1'b0 +
	  //					 (update_zuc_module_regs[1] && hmac_match[1]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[0] && hmac_match[0]) ? 1'b1 : 1'b0;
	  total_hmac_requests_match_count <= total_hmac_requests_match_count + {16'b0, total_modules_pass_count};
	  
	  //					 (update_zuc_module_regs[7] && ~hmac_match[7]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[6] && ~hmac_match[6]) ? 1'b1 : 1'b0 +
	  //					 (update_zuc_module_regs[5] && ~hmac_match[5]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[4] && ~hmac_match[4]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[3] && ~hmac_match[3]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[2] && ~hmac_match[2]) ? 1'b1 : 1'b0 +
	  //					 (update_zuc_module_regs[1] && ~hmac_match[1]) ? 1'b1 : 1'b0 + 
	  //					 (update_zuc_module_regs[0] && ~hmac_match[0]) ? 1'b1 : 1'b0;
	  total_hmac_requests_nomatch_count <= total_hmac_requests_nomatch_count + {16'b0, total_modules_drop_count};
	end
      
      // Per fifox_out message count: 
      // The counter is incremented after ZUC module has added a new message into its fifo_out
      // The counter is decremented once a message has been read from fifo_out to sbu2pci
      // Exception: Do nothing if neither or both of inc and dec are asserted:
      // Counter 0:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 0)) && ~update_zuc_module_regs[0])
	fifo0_out_message_count <= fifo0_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 0)) &&  update_zuc_module_regs[0])
	fifo0_out_message_count <= fifo0_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 1:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 1)) && ~update_zuc_module_regs[1])
	fifo1_out_message_count <= fifo1_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 1)) &&  update_zuc_module_regs[1])
	fifo1_out_message_count <= fifo1_out_message_count + 1;
      else 
	// Do nothing
	begin
	end
      
      // Counter 2:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 2)) && ~update_zuc_module_regs[2])
	fifo2_out_message_count <= fifo2_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 2)) &&  update_zuc_module_regs[2])
	fifo2_out_message_count <= fifo2_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 3:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 3)) && ~update_zuc_module_regs[3])
	fifo3_out_message_count <= fifo3_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 3)) &&  update_zuc_module_regs[3])
	fifo3_out_message_count <= fifo3_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 4:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 4)) && ~update_zuc_module_regs[4])
	fifo4_out_message_count <= fifo4_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 4)) &&  update_zuc_module_regs[4])
	fifo4_out_message_count <= fifo4_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 5:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 5)) && ~update_zuc_module_regs[5])
	fifo5_out_message_count <= fifo5_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 5)) &&  update_zuc_module_regs[5])
	fifo5_out_message_count <= fifo5_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 6:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 6)) && ~update_zuc_module_regs[6])
	fifo6_out_message_count <= fifo6_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 6)) &&  update_zuc_module_regs[6])
	fifo6_out_message_count <= fifo6_out_message_count + 1;
      else 
	// Do nothing
	begin
	end

      // Counter 7:
      if      ( (update_fifo_out_regs && (current_fifo_out_id == 7)) && ~update_zuc_module_regs[7])
	fifo7_out_message_count <= fifo7_out_message_count - 1;
      else if (~(update_fifo_out_regs && (current_fifo_out_id == 7)) &&  update_zuc_module_regs[7])
	fifo7_out_message_count <= fifo7_out_message_count + 1;
      else 
	// Do nothing
	begin
	end


      // per channel last_message_id[]
      // message_id is not modified in non zuc commands
      if (update_fifo_out_regs && current_out_zuccmd)
	begin
	  case (current_fifo_out_chid)
	    0:
	      begin
		// message_id valid bit is also set
		chid0_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    1:
	      begin
		chid1_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    2:
	      begin
		chid2_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    3:
	      begin
		chid3_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    4:
	      begin
		chid4_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    5:
	      begin
		chid5_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    6:
	      begin
		chid6_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    7:
	      begin
		chid7_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    8:
	      begin
		chid8_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    9:
	      begin
		chid9_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    10:
	      begin
		chid10_last_message_id <={4'h8,  current_fifo_out_message_id[11:0]};
	      end
	    11:
	      begin
		chid11_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    12:
	      begin
		chid12_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    13:
	      begin
		chid13_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    14:
	      begin
		chid14_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    15:
	      begin
		chid15_last_message_id <= {4'h8, current_fifo_out_message_id[11:0]};
	      end
	    default: begin
	    end
	  endcase

	end
    end
  end  





  // Select last_message_id[] per pending message in fifox_out
  // The selection below will be used only if the correspondoing fifox_out has a valid full message pending
  //
  // fifo0_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[0][7:4]) // select by channel_id
      0:
	begin
	  fifo0_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo0_out_last_message_id = chid1_last_message_id;
	end
      
      2:
	begin
	  fifo0_out_last_message_id = chid2_last_message_id;
	end
      
      3:
	begin
	  fifo0_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo0_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo0_out_last_message_id = chid5_last_message_id;
	end
      
      6:
	begin
	  fifo0_out_last_message_id = chid6_last_message_id;
	end
      
      7:
	begin
	  fifo0_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo0_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo0_out_last_message_id = chid9_last_message_id;
	end
      
      10:
	begin
	  fifo0_out_last_message_id = chid10_last_message_id;
	end
      
      11:
	begin
	  fifo0_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo0_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo0_out_last_message_id = chid13_last_message_id;
	end
      
      14:
	begin
	  fifo0_out_last_message_id = chid14_last_message_id;
	end
      
      15:
	begin
	  fifo0_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo1_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[1][7:4])
      0:
	begin
	  fifo1_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo1_out_last_message_id = chid1_last_message_id;
	end
      
      2:
	begin
	  fifo1_out_last_message_id = chid2_last_message_id;
	end
      
      3:
	begin
	  fifo1_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo1_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo1_out_last_message_id = chid5_last_message_id;
	end
      
      6:
	begin
	  fifo1_out_last_message_id = chid6_last_message_id;
	end
      
      7:
	begin
	  fifo1_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo1_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo1_out_last_message_id = chid9_last_message_id;
	end
      
      10:
	begin
	  fifo1_out_last_message_id = chid10_last_message_id;
	end
      
      11:
	begin
	  fifo1_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo1_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo1_out_last_message_id = chid13_last_message_id;
	end
      
      14:
	begin
	  fifo1_out_last_message_id = chid14_last_message_id;
	end
      
      15:
	begin
	  fifo1_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo2_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[2][7:4])
      0:
	begin
	  fifo2_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo2_out_last_message_id = chid1_last_message_id;
	end
      
      2:
	begin
	  fifo2_out_last_message_id = chid2_last_message_id;
	end
      
      3:
	begin
	  fifo2_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo2_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo2_out_last_message_id = chid5_last_message_id;
	end
      
      6:
	begin
	  fifo2_out_last_message_id = chid6_last_message_id;
	end
      
      7:
	begin
	  fifo2_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo2_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo2_out_last_message_id = chid9_last_message_id;
	end
      
      10:
	begin
	  fifo2_out_last_message_id = chid10_last_message_id;
	end
      
      11:
	begin
	  fifo2_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo2_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo2_out_last_message_id = chid13_last_message_id;
	end
      
      14:
	begin
	  fifo2_out_last_message_id = chid14_last_message_id;
	end
      
      15:
	begin
	  fifo2_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo3_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[3][7:4])
      0:
	begin
	  fifo3_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo3_out_last_message_id = chid1_last_message_id;
	end
      2:
	begin
	  fifo3_out_last_message_id = chid2_last_message_id;
	end
      3:
	begin
	  fifo3_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo3_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo3_out_last_message_id = chid5_last_message_id;
	end
      6:
	begin
	  fifo3_out_last_message_id = chid6_last_message_id;
	end
      7:
	begin
	  fifo3_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo3_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo3_out_last_message_id = chid9_last_message_id;
	end
      10:
	begin
	  fifo3_out_last_message_id = chid10_last_message_id;
	end
      11:
	begin
	  fifo3_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo3_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo3_out_last_message_id = chid13_last_message_id;
	end
      14:
	begin
	  fifo3_out_last_message_id = chid14_last_message_id;
	end
      15:
	begin
	  fifo3_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo4_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[4][7:4])
      0:
	begin
	  fifo4_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo4_out_last_message_id = chid1_last_message_id;
	end
      2:
	begin
	  fifo4_out_last_message_id = chid2_last_message_id;
	end
      3:
	begin
	  fifo4_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo4_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo4_out_last_message_id = chid5_last_message_id;
	end
      6:
	begin
	  fifo4_out_last_message_id = chid6_last_message_id;
	end
      7:
	begin
	  fifo4_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo4_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo4_out_last_message_id = chid9_last_message_id;
	end
      10:
	begin
	  fifo4_out_last_message_id = chid10_last_message_id;
	end
      11:
	begin
	  fifo4_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo4_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo4_out_last_message_id = chid13_last_message_id;
	end
      14:
	begin
	  fifo4_out_last_message_id = chid14_last_message_id;
	end
      15:
	begin
	  fifo4_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo5_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[5][7:4])
      0:
	begin
	  fifo5_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo5_out_last_message_id = chid1_last_message_id;
	end
      2:
	begin
	  fifo5_out_last_message_id = chid2_last_message_id;
	end
      3:
	begin
	  fifo5_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo5_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo5_out_last_message_id = chid5_last_message_id;
	end
      6:
	begin
	  fifo5_out_last_message_id = chid6_last_message_id;
	end
      7:
	begin
	  fifo5_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo5_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo5_out_last_message_id = chid9_last_message_id;
	end
      10:
	begin
	  fifo5_out_last_message_id = chid10_last_message_id;
	end
      11:
	begin
	  fifo5_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo5_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo5_out_last_message_id = chid13_last_message_id;
	end
      14:
	begin
	  fifo5_out_last_message_id = chid14_last_message_id;
	end
      15:
	begin
	  fifo5_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo6_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[6][7:4])
      0:
	begin
	  fifo6_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo6_out_last_message_id = chid1_last_message_id;
	end
      2:
	begin
	  fifo6_out_last_message_id = chid2_last_message_id;
	end
      3:
	begin
	  fifo6_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo6_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo6_out_last_message_id = chid5_last_message_id;
	end
      6:
	begin
	  fifo6_out_last_message_id = chid6_last_message_id;
	end
      7:
	begin
	  fifo6_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo6_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo6_out_last_message_id = chid9_last_message_id;
	end
      10:
	begin
	  fifo6_out_last_message_id = chid10_last_message_id;
	end
      11:
	begin
	  fifo6_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo6_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo6_out_last_message_id = chid13_last_message_id;
	end
      14:
	begin
	  fifo6_out_last_message_id = chid14_last_message_id;
	end
      15:
	begin
	  fifo6_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // fifo7_out_last_message_id[]:
  always @(*) begin
    case (fifo_out_status[7][7:4])
      0:
	begin
	  fifo7_out_last_message_id = chid0_last_message_id;
	end
      1:
	begin
	  fifo7_out_last_message_id = chid1_last_message_id;
	end
      2:
	begin
	  fifo7_out_last_message_id = chid2_last_message_id;
	end
      3:
	begin
	  fifo7_out_last_message_id = chid3_last_message_id;
	end
      4:
	begin
	  fifo7_out_last_message_id = chid4_last_message_id;
	end
      5:
	begin
	  fifo7_out_last_message_id = chid5_last_message_id;
	end
      6:
	begin
	  fifo7_out_last_message_id = chid6_last_message_id;
	end
      7:
	begin
	  fifo7_out_last_message_id = chid7_last_message_id;
	end
      8:
	begin
	  fifo7_out_last_message_id = chid8_last_message_id;
	end
      9:
	begin
	  fifo7_out_last_message_id = chid9_last_message_id;
	end
      10:
	begin
	  fifo7_out_last_message_id = chid10_last_message_id;
	end
      11:
	begin
	  fifo7_out_last_message_id = chid11_last_message_id;
	end
      12:
	begin
	  fifo7_out_last_message_id = chid12_last_message_id;
	end
      13:
	begin
	  fifo7_out_last_message_id = chid13_last_message_id;
	end
      14:
	begin
	  fifo7_out_last_message_id = chid14_last_message_id;
	end
      15:
	begin
	  fifo7_out_last_message_id = chid15_last_message_id;
	end
      
      default: begin
      end
    endcase
  end

  // At the end of an Ethernet message, its first line in input buffer is updated with message related metadata
  assign input_buffer_wadrs = (~current_in_pkt_type && current_in_message_status_update) ? current_in_message_status_adrs : current_in_tail;
  assign input_buffer_radrs = current_out_head;

  // Written data to input buffer.
  // Adding specific implementation info at the message header[31:0]
  assign input_buffer_wdata = packet_in_progress
			      ?

			      (~current_in_pkt_type && current_in_message_status_update)
				? 
			      // At end of message reception: Updating first message line with eth_header and related message metadata :
			      //			      {current_in_pkt_type, 3'h0, current_in_eth_header, 116'b0,
			      //			       pci2sbu_axi4stream_tuser[67:56], 
			      //
			      //                               // [47:0]: Place holder for message metadata. See input_buffer_meta_wdata[]
			      //			       48'b0}
			      // hmac: eth header is fully stored. No masking !!! 
			      {current_in_pkt_type, 3'h0, current_in_eth_header}

			         :
			      // Message payload:
			      {2'h0, current_in_eom & pci2sbu_axi4stream_tlast, 1'b0, pci2sbu_axi4stream_tdata}

			      :
			      
			      // hmac: eth header is fully stored. No masking !!! 
			      // Message header:
			      {current_in_pkt_type, 1'b0, current_in_eom & pci2sbu_axi4stream_tlast, current_in_som,
			       pci2sbu_axi4stream_tdata[511:0]};
  

  
  assign input_buffer_meta_wadrs = current_in_message_status_update ? current_in_message_status_adrs : current_in_tail;
  // Adding the read message id & status into its placeholder in input_buffer_meta_rdata:

// hmac: Updating packet metadata:
  assign input_buffer_meta_wdata = {current_in_tuser_steering_tag[15:0],                     // [47:32]
				    current_in_tuser_message_size[15:0],                     // [31:16]
				    8'h00,                                                   // [15:8] - Reserved
				    current_in_message_status                                // [7:0]
				    }; 
  assign input_buffer_rdata = input_buffer_rd;

// AFU input buffer 8K x 516b (115 x 36kb BRAMs):
blk_mem_SimpleDP_8Kx512b zuc_input_buffer_data (
  .clka(clk),                              // input wire clka
  .ena(input_buffer_wren),                 // input wire ena
  .wea(input_buffer_write),                // input wire [0 : 0] wea
  .addra(input_buffer_wadrs),              // input wire [12 : 0] addra
  .dina(input_buffer_wdata),               // input wire [515 : 0] dina
  .clkb(clk),                              // input wire clkb
  .enb(input_buffer_rden),                 // input wire enb
  .addrb(input_buffer_radrs),              // input wire [12 : 0] addrb
  .doutb(input_buffer_rd)                  // output wire [515 : 0] doutb
  );

// AFU input buffer metadata, 8K x 48b (11 x 36Kb BRAMs):
// Writing: All writes to input_buffer_data are also written here, using same wadrs and write signals.
//          Upon end of message (TUSER[EOM]), the message metadata is written only to this buffer, to its first buffer address
// Reading: Always along with reading the input_buffer_data array, using the same read address.
// Message metadata format:
// [47:40]   Opcode, as captured from "message_opcode" field in message header
// [39:24]   Message size (bytes), as captured from "message_size" field in message header
// [23:20]   Channel ID
// [19:8]    Message ID
// [7:0]     Message status:
//           [7:3] Reserved
//           [2]   Message is too long (> 9KB)
//           [1]   Mismatching message length
//                 The actual message length (in flits) is compared against the reported length (mesasge_header[495:480])
//                 If no match, this message will be dropped (or bypassed) down the road.
//           [0]   Message is too long (> 9KB)
input_buffer_status_simpleDP_8Kx8b zuc_input_buffer_metadata (
  .clka(clk),                              // input wire clka
  .ena(input_buffer_wren),                 // input wire ena
  .wea(input_buffer_meta_write),           // input wire [0 : 0] wea
  .addra(input_buffer_meta_wadrs),         // input wire [12 : 0] addra
  .dina(input_buffer_meta_wdata),          // input wire [47 : 0] dina
  .clkb(clk),                              // input wire clkb
  .enb(input_buffer_rden),                 // input wire enb
  .addrb(input_buffer_radrs),              // input wire [12 : 0] addrb
  .doutb(input_buffer_meta_rdata)          // output wire [47 : 0] doutb
  );
  

  
// hmac modules instances
generate
  genvar i;
  for (i = 0; i < NUM_MODULES ; i = i + 1) begin: hmac_modules
    hmac_module_wrapper hmac_module_wrapper_inst (
        .clk(clk),
        .reset(reset || afu_reset),
        .zmw_module_id(i),                                        // input wire [3:0]
        .zmw_module_in_id(current_fifo_in_id),                    // input wire [2:0]
        .zmw_module_in_valid(module_in_valid),                    // input wire
        .zmw_in_ready(fifo_in_ready[i]),                          // output wire
        .zmw_in_data(module_in_data[511:0]),                      // input wire [511:0]. TBD: Widen fifox_in to 516 bits
        .zmw_in_last(current_out_last),                           // input wire
        .zmw_in_user(current_fifo_in_message_type),               // input wire
        .zmw_in_test_mode(module_in_test_mode),                   // input wire. Common to all modules
        .zmw_in_force_modulebypass(module_in_force_modulebypass), // input wire. Common to all modules
        .zmw_in_force_corebypass(module_in_force_corebypass),     // input wire. Common to all modules
        .zmw_fifo_in_data_count(fifo_in_data_count[i]),           // output wire [9:0]
        .zmw_out_valid(fifo_out_valid[i]),                        // output wire
        .zmw_module_out_id(current_fifo_out_id[2:0]),             // input wire [2:0]
        .zmw_module_out_ready(module_out_ready),                  // input wire
        .zmw_out_data(fifo_out_data[i][511:0]),                   // output wire [511:0]
        .zmw_out_last(fifo_out_last[i]),                          // output wire
        .zmw_out_user(fifo_out_user[i]),                          // output wire
        .zmw_out_status_valid(fifo_out_status_valid[i]),          // output wire
        .zmw_out_status_ready(module_out_status_ready),           // input wire
        .zmw_out_status_data(fifo_out_status[i]),                 // output wire [7:0]
        .zmw_update_hmac_count(update_zuc_module_regs[i]),        // output wire
        .zmw_hmac_match(hmac_match[i]),                           // output wire
        .zmw_hmac_test_mode(hmac_test_mode),                      // input wire [2:0]. Common to all deployed modules
        .zmw_in_watermark(module_fifo_in_watermark[i]),           // input wire [4:0]
        .zmw_in_watermark_met(module_fifo_in_watermark_met[i]),   // output wire
        .zmw_progress(zuc_progress[i]),                           // output wire [15:0]
        .zmw_out_stats(zuc_out_stats[i])                          // output wire [31:0]
    );
    
  end
// Initializing output signals from undeployed modules
  for (i = NUM_MODULES; i < MAX_NUMBER_OF_MODULES ; i = i + 1) begin: hmac_non_deployed_modules
    assign fifo_in_ready[i] = 1'b0;
    assign fifo_in_data_count[i] = 10'h000;
    assign fifo_out_valid[i] = 1'b0;
    assign fifo_out_last[i] = 1'b0;
    assign fifo_out_user[i] = 1'b0;
    assign fifo_out_status_valid[i] = 1'b0;
    assign fifo_out_status[i] = 8'h00;
    assign update_zuc_module_regs[i] = 1'b0;
    assign hmac_match[i] = 1'b0;
    assign module_fifo_in_watermark_met[i] = 1'b0;
    assign zuc_progress[i] = 16'h0000;
    assign zuc_out_stats[i] = 32'h00000000;
  end


endgenerate


//===================================================================================================================================
// pci2sbu sampling buffer
//===================================================================================================================================
//
  wire        unconnected_pci2sbu_sample_arready;
  wire        unconnected_pci2sbu_sample_rvalid;
  wire [1:0]  unconnected_pci2sbu_sample_rresp;
  wire [511:0] pci2sbu_sample_wdata;
  wire [15:0] pci2sbu_sample_steering_tag;
  wire [15:0] pci2sbu_sample_length;
  wire [31:0] pci2sbu_sample_rdata;
  wire sample_metadata_enable;
  
  assign sample_metadata_enable = afu_ctrl2[17];
  assign pci2sbu_sample_steering_tag = pci2sbu_axi4stream_tuser[71:56];
  assign pci2sbu_sample_length = {2'b0, pci2sbu_axi4stream_tuser[29:16]};
  assign pci2sbu_sample_wdata = {pci2sbu_axi4stream_tdata[511:448],
				 // hmac: adding Steering_Tag and Length from TUSER[] to pci2sbu sample metadata
				 sample_metadata_enable
                                 ? 
				   (current_in_tfirst 
                                      ? 
				        {timestamp[47:0], pci2sbu_sample_steering_tag, pci2sbu_sample_length, pci2sbu_axi4stream_tdata[367:0]}
                                      : 
				        {timestamp[47:0], pci2sbu_axi4stream_tdata[399:0]})
				 :
				   pci2sbu_axi4stream_tdata[447:0]};


`ifdef AFU_PCI2SBU_SAMPLE_EN
zuc_sample_buf afu_pci2sbu_sample_buffer
  (
   .sample_clk(clk),
   .sample_reset(reset),
   .sample_sw_reset(afu_pci_sample_soft_reset),
   .sample_enable(afu_pci2sbu_sample_enable),
   .sample_tdata(pci2sbu_sample_wdata),
   .sample_valid(pci2sbu_axi4stream_vld),
   .sample_ready(pci2sbu_axi4stream_rdy),
   .sample_eom(pci2sbu_axi4stream_tuser[39]),
   .sample_tlast(pci2sbu_axi4stream_tlast),
   .axi4lite_araddr_base(AFU_CLK_PCI2SBU),
   .axi4lite_araddr(axi_raddr),
   .axi4lite_arvalid(axilite_ar_vld),
   .axi4lite_arready(unconnected_pci2sbu_sample_arready),
   .axi4lite_rready(axilite_r_rdy),
   .axi4lite_rvalid(unconnected_pci2sbu_sample_rvalid),
   .axi4lite_rresp(unconnected_pci2sbu_sample_rresp),
   .axi4lite_rdata(pci2sbu_sample_rdata)
   );
`endif //  `ifdef AFU_PCI2SBU_SAMPLE_EN
  
`ifndef AFU_PCI2SBU_SAMPLE_EN
  assign pci2sbu_sample_rdata = 32'hdeadf00d;
`endif  


//===================================================================================================================================
// sampling trigger
//===================================================================================================================================
//
localparam
  SAMPLING_TRIGGER_POSITION = 2*1024; // 2K samples from end of the 8K sampling buffer

  reg  sampling_window;
  wire sampling_trigger_match;
  wire sampling_trigger_enabled;
  reg trigger_is_met;
  reg [15:0] sampling_window_end; // Number of clocks from trigger to end sampling

// Trigger: Temporarily looking for a specific pattern at module_in_data[]
  assign sampling_trigger_enabled = afu_ctrl2[19];
  
  assign sampling_trigger_match = module_in_valid && (module_in_data[47:0] == {afu_ctrl9[15:0], afu_ctrl8});
  
  always @(posedge clk) begin
    if (reset || afu_reset)
      begin
	sampling_window <= 1'b1;
	trigger_is_met <= 1'b0;
	sampling_window_end <= 16'b0;
      end
    else
      begin
	if (sampling_trigger_match && sampling_trigger_enabled)
	  trigger_is_met <= 1'b1;

	if (trigger_is_met)
	  sampling_window_end <= sampling_window_end + 1'b1;

	if (sampling_window_end > SAMPLING_TRIGGER_POSITION)
	  begin
	    sampling_window <= 1'b0;
	  end
      end
  end
  
  
//===================================================================================================================================
// input_buffer sampling buffer
//===================================================================================================================================
//
  wire [511:0] input_buffer_sample_wdata;
  wire [511:0] input_buffer_sample_rdata;
  wire 	       input_buffer_sample_vld;
  wire 	       input_buffer_sample_rdy;
  wire 	       input_buffer_sample_eom;
  wire 	       input_buffer_sample_last;
  wire 	       unconnected_input_buffer_sample_arready;
  wire 	       unconnected_input_buffer_sample_rvalid;
  wire [1:0]   unconnected_input_buffer_sample_rresp;
  
  assign input_buffer_sample_vld = afu_ctrl2[18] ? 1'b1 : input_buffer_meta_write;
  assign input_buffer_sample_rdy = 1'b1;
  assign input_buffer_sample_eom = pci2sbu_axi4stream_tuser[39];
  assign input_buffer_sample_last = pci2sbu_axi4stream_tlast;
  
  wire [399:0] input_buffer_sample_wmetadata;
  assign input_buffer_sample_wmetadata = {timestamp[47:0],
					  pci2sbu_axi4stream_tuser[39], pci2sbu_axi4stream_tuser[30], pci2sbu_axi4stream_tlast,                // ...
					  current_in_zuccmd, current_in_eom, current_in_som, chid0_in_som, current_in_buffer_full,             // 8
					  current_in_message_ok, 3'b0, current_in_message_status[3:0],                                         // 8
					  input_buffer_watermark_met[15:0],                                                                    // 16
					  6'b0, current_in_message_lines[9:0], 6'b0, chid0_in_message_lines[9:0], 16'b0,                       // 48
					  current_in_message_size[15:0], chid0_in_message_size[15:0],                                          // 32
					  4'b0, current_in_message_id[11:0], 4'b0, chid0_in_message_id[11:0],                                  // 32
					  3'b0, chid0_in_message_start[12:0], 3'b0, current_in_message_start[12:0],                            // 32
					  3'b0, input_buffer_wadrs[12:0], 3'b0, input_buffer_meta_wadrs[12:0],                                 // 32
					  5'b0, current_in_buffer_data_countD[10:0], 5'b0, chid_in_buffer_data_count[0][10:0],                 // 32
					  3'b0, chid0_out_head[12:0], 3'b0, current_out_head[12:0],                                            // 32
					  8'b0,                                                                                                // 8
					  4'b0, current_out_chid[3:0],                                                                         // 8
					  6'b0, chid_in_message_count[0][9:0],                                                                   // 16
					  3'b0, chid0_in_tail[12:0], 3'b0, current_in_tail[12:0],                                              // 32
  					  4'b0, current_in_chid[3:0],                                                                          // 8
					  8'b0};                                                                                               // 8
  
  assign input_buffer_sample_wdata = {input_buffer_wdata[511:448], 
				      sample_metadata_enable ? input_buffer_sample_wmetadata[399:0] : input_buffer_wdata[447:48],
				      input_buffer_meta_wdata[47:0]};
  
`ifdef INPUT_BUFFER_SAMPLE_EN
zuc_sample_buf input_buffer_sample
  (
   .sample_clk(clk),
   .sample_reset(reset),
   .sample_sw_reset(afu_pci_sample_soft_reset),
   .sample_enable(input_buffer_sample_enable),
   .sample_tdata(input_buffer_sample_wdata),
   .sample_valid(input_buffer_sample_vld),
   .sample_ready(input_buffer_sample_rdy),
   .sample_eom(input_buffer_sample_eom),
   .sample_tlast(input_buffer_sample_last),
   .axi4lite_araddr_base(AFU_CLK_INPUT_BUFFER),
   .axi4lite_araddr(axi_raddr),
   .axi4lite_arvalid(axilite_ar_vld),
   .axi4lite_arready(unconnected_input_buffer_sample_arready),
   .axi4lite_rready(axilite_r_rdy),
   .axi4lite_rvalid(unconnected_input_buffer_sample_rvalid),
   .axi4lite_rresp(unconnected_input_buffer_sample_rresp),
   .axi4lite_rdata(input_buffer_sample_rdata)
   );
`endif  

`ifndef INPUT_BUFFER_SAMPLE_EN
  assign input_buffer_sample_rdata = 32'hdeadf00d;
`endif  

  
//===================================================================================================================================
// module_in sampling buffer
//===================================================================================================================================
//
  wire [511:0] module_in_sample_wdata;
  wire [351:0] module_in_sample_wmetadata;
  wire 	       module_in_sample_eom;
  wire 	       module_in_sample_last;
  wire 	       module_in_sample_valid;
  wire 	       module_in_sample_ready;
  wire [31:0]  module_in_sample_rdata;
  wire 	       unconnected_module_in_sample_arready;
  wire 	       unconnected_module_in_sample_rvalid;
  wire [1:0]   unconnected_module_in_sample_rresp;
  
  // Add (replace) sample metadata to lower sample_data[15:0]
  // hmac: Shortened (by extracting reserved spaces) from sampe_metadata, from 400b to 352b
  assign module_in_sample_wmetadata = {timestamp[47:0],                                                                                           // 48
				       3'b0, module_in_valid, 2'b0, input_buffer_meta_write, input_buffer_write,			          // 8
				       2'b00, update_channel_out_regs, update_channel_in_regs,                                                    // ...
				       1'b0, packet_in_nstate[2:0], message_out_nstate[3:0], sbu2pci_out_nstate[3:0],                             // 16
				       fifo_in_ready[7],fifo_in_ready[6],fifo_in_ready[5],fifo_in_ready[4],                                       // ...
				       fifo_in_ready[3],fifo_in_ready[2],fifo_in_ready[1],fifo_in_ready[0],                                       // 8
				       current_out_last, current_fifo_in_message_ok, current_fifo_in_header, current_fifo_in_eth_header,          // ...
				       1'b0, current_fifo_in_id[2:0],                                                                             // 8 
				       6'b0, fifo_in_data_count[7][9:0], 6'b0, fifo_in_data_count[6][9:0],                                        // 32
				       6'b0, fifo_in_data_count[5][9:0], 6'b0, fifo_in_data_count[4][9:0],                                        // 32
				       6'b0, fifo_in_data_count[3][9:0], 6'b0, fifo_in_data_count[2][9:0],                                        // 32
				       6'b0, fifo_in_data_count[1][9:0], 6'b0, fifo_in_data_count[0][9:0],                                        // 32
  				       fifo_in_free_regD[7:0],                                                                                    // 8
				       messages_validD[15:0],                                                                                     // 16
				       3'b0, chid0_out_head[12:0], 3'b0, current_out_head[12:0],                                                  // 32
				       4'b0, current_out_chid[3:0],                                                                               // 8
				       6'b0, chid_in_message_count[0][9:0],                                                                       // 16
				       3'b0, chid0_in_tail[12:0], 3'b0, current_in_tail[12:0],                                                    // 32
  				       4'b0, current_in_chid[3:0],                                                                                // 8
				       16'b0};                                                                                                    // 16b
  
  
  assign module_in_sample_wdata = {module_in_data[511:448], 
				   sample_metadata_enable ? module_in_sample_wmetadata[351:0] : module_in_data[447:96],
				   module_in_data[95:0]};
  assign module_in_sample_eom = 1'b1;
  assign module_in_sample_last = current_out_last;
  assign module_in_sample_valid = afu_ctrl2[18] ? 1'b1 : module_in_valid;
  assign module_in_sample_ready = fifo_in_readyD;
  
`ifdef MODULE_IN_SAMPLE_EN
zuc_sample_buf module_in_sample_buffer
  (
   .sample_clk(clk),
   .sample_reset(reset),
   .sample_sw_reset(afu_pci_sample_soft_reset),
   .sample_enable(module_in_sample_enable),
   .sample_tdata(module_in_sample_wdata),
   .sample_valid(module_in_sample_valid),
   .sample_ready(module_in_sample_ready),
   .sample_eom(module_in_sample_eom),
   .sample_tlast(module_in_sample_last),
   .axi4lite_araddr_base(AFU_CLK_MODULE_IN),
   .axi4lite_araddr(axi_raddr),
   .axi4lite_arvalid(axilite_ar_vld),
   .axi4lite_arready(unconnected_module_in_sample_arready),
   .axi4lite_rready(axilite_r_rdy),
   .axi4lite_rvalid(unconnected_module_in_sample_rvalid),
   .axi4lite_rresp(unconnected_module_in_sample_rresp),
   .axi4lite_rdata(module_in_sample_rdata)
   );
`endif  

`ifndef MODULE_IN_SAMPLE_EN
  assign module_in_sample_rdata = 32'hdeadf00d;
`endif  

//===================================================================================================================================
// sbu2pci sampling buffer
//===================================================================================================================================
//
  wire        unconnected_sbu2pci_sample_arready;
  wire        unconnected_sbu2pci_sample_rvalid;
  wire [1:0]  unconnected_sbu2pci_sample_rresp;
  wire [31:0] sbu2pci_sample_rdata;
  wire [511:0] sbu2pci_sample_wdata;
  wire [399:0] sbu2pci_sample_wmetadata;

  assign sbu2pci_sample_wmetadata = {timestamp[47:0],                                                                     // 48
				     16'b0,                                                                               // 16
				     fifo7_out_last_message_id[15:0], fifo7_out_message_id[11:0],                         // ...
				     fifo6_out_last_message_id[15:0], fifo6_out_message_id[11:0],                         // ...
				     fifo5_out_last_message_id[15:0], fifo5_out_message_id[11:0],                         // ...
				     fifo4_out_last_message_id[15:0], fifo4_out_message_id[11:0],                         // ...
				     fifo3_out_last_message_id[15:0], fifo3_out_message_id[11:0],                         // .. .
				     fifo2_out_last_message_id[15:0], fifo2_out_message_id[11:0],                         // ...
				     fifo1_out_last_message_id[15:0], fifo1_out_message_id[11:0],                         // ...
				     fifo0_out_last_message_id[15:0], fifo0_out_message_id[11:0],                         // 32x7
				     3'b0, fifo7_out_message_count[8:0], 3'b0, fifo6_out_message_count[8:0],              // ...
				     3'b0, fifo5_out_message_count[8:0], 3'b0, fifo4_out_message_count[8:0],              // ...
				     3'b0, fifo3_out_message_count[8:0], 3'b0, fifo2_out_message_count[8:0],              // ...
				     3'b0, fifo1_out_message_count[8:0], 3'b0, fifo0_out_message_count[8:0],              // 32x3
				     current_fifo_out_id[3:0], fifo_out_id_delta[3:0], fifo_out_message_valid_regD[7:0]}; // 16
  
  assign sbu2pci_sample_wdata = {sbu2pci_axi4stream_tdata[511:448],
				 sample_metadata_enable ? sbu2pci_sample_wmetadata : sbu2pci_axi4stream_tdata[447:48],
				 sbu2pci_axi4stream_tdata[47:0]};

`ifdef AFU_SBU2PCI_SAMPLE_EN
zuc_sample_buf afu_sbu2pci_sample_buffer
  (
   .sample_clk(clk),
   .sample_reset(reset),
   .sample_sw_reset(afu_pci_sample_soft_reset),
   .sample_enable(afu_sbu2pci_sample_enable),
   .sample_tdata(sbu2pci_sample_wdata),
   .sample_valid(sbu2pci_axi4stream_vld),
   .sample_ready(sbu2pci_axi4stream_rdy),
   .sample_eom(sbu2pci_axi4stream_tuser[39]),
   .sample_tlast(sbu2pci_axi4stream_tlast),
   .axi4lite_araddr_base(AFU_CLK_SBU2PCI),
   .axi4lite_araddr(axi_raddr),
   .axi4lite_arvalid(axilite_ar_vld),
   .axi4lite_arready(unconnected_sbu2pci_sample_arready),
   .axi4lite_rready(axilite_r_rdy),
   .axi4lite_rvalid(unconnected_sbu2pci_sample_rvalid),
   .axi4lite_rresp(unconnected_sbu2pci_sample_rresp),
   .axi4lite_rdata(sbu2pci_sample_rdata)
   );
`endif  

`ifndef AFU_SBU2PCI_SAMPLE_EN
  assign sbu2pci_sample_rdata = 32'hdeadf00d;
`endif  


  // ===========================================================================================================
  // hmac K buffer: 32Kb array, 1 BRAM
  // Written via Axilite
  //    Write space: 1024 x 32b
  //    Read space: 512 x 64b
  // ===========================================================================================================
  wire 	       kbuffer_wr;
  wire [9:0]   kbuffer_wadrs;
  wire [31:0]  kbuffer_din;
  wire [8:0]   kbuffer_radrs;
  wire [63:0]  kbuffer_dout;
  wire [511:0] key;
  
  assign kbuffer_wadrs = {axi_waddr[11:2]};
  assign kbuffer_din = axilite_w_data[31:0];
  assign kbuffer_wr = kbuffer_write;
  
  // Steering tag is extracted from previously saved TUSER.steering_tag
  //  assign kbuffer_radrs = current_fifo_in_steering_tag[8:0];
  assign kbuffer_radrs = input_buffer_meta_rdata[40:32];
  
  
  blk_mem_simpleDP_W1Kx32b_R512x64b keys_buffer 
    (
     .clka(clk),    // input wire clka
     .ena(1'b1),      // input wire ena
     .wea(kbuffer_wr),      // input wire [0 : 0] wea
     .addra(kbuffer_wadrs),  // input wire [9 : 0] addra
     .dina(kbuffer_din),    // input wire [31 : 0] dina
     .clkb(clk),    // input wire clkb
     .enb(1'b1),      // input wire enb
     .addrb(kbuffer_radrs),  // input wire [8 : 0] addrb
     .doutb(kbuffer_dout)  // output wire [63 : 0] doutb
     );


endmodule
