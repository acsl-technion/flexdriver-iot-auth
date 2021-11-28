// hmac module
// A message is read from fifo_in and delivered to a core, then aggregated into fifo_out.
// This scheme is triggered if there is at least one full message in fifo_in, and there is sufficient space in fifo_out to hold the resulting response.
//    incoming message size is extracted from first fifo_in line (message header, see below)
//    fifo_out free count is locally calculated:  == MODULE_FIFO_OUT_SIZE - fifo_out_data_count[]
// The expected space in fifo_out depends on the incoming message size & command:
//
// ==============================================================================
// Internal AFU message header info:
// Generated locally, and transferred between the AFU modules.
// Required for proper and/or simplified implementation  	    
// ==============================================================================
// header[]  | Field         | Description
// ----------+--------------------------------------------------------------------
// [515:511]   TBD: Add these bits to all intermmediate fifos: {2'b00, EOM, SOM}
// [511:160]   pci2sbu_tdata[511:160]
// [31:20]     pci2sbu_axi4stream_tuser[67:56]
// [19:8]      current_in_message_id[11:0]
// [7:4]       current_in_context[3:0]
// [3:0]       current_in_chid[3:0]
//
module hmac_module (
		   input wire 	       zm_clk,
		   input wire 	       zm_reset,
		   input wire 	       zm_in_valid,
		   output wire 	       zm_in_ready,
		   input wire [511:0]  zm_in_data,
		   input wire 	       zm_in_last,
		   input wire 	       zm_in_user,
		   input wire 	       zm_in_test_mode,
		   input wire 	       zm_in_force_modulebypass,
		   input wire 	       zm_in_force_corebypass,
		   input wire [9:0]    fifo_in_data_count,
		   input wire [9:0]    fifo_out_data_count,
		   output reg 	       zm_out_valid,
		   input wire 	       zm_out_ready,
		   output wire [511:0] zm_out_data,
		   output wire [63:0]  zm_out_keep, // generated locally, based on message length 
		   output wire 	       zm_out_last,
		   output reg 	       zm_out_user,
		   output reg 	       zm_out_status_valid,
		   input 	       zm_out_status_ready,
		   output reg [7:0]    zm_out_status_data,
		   output wire 	       zm_update_hmac_count,
		   output wire 	       zm_hmac_match,
		   input wire [2:0]    zm_in_hmac_test_mode,
		   input wire [4:0]    zm_in_watermark,
		   output wire 	       zm_in_watermark_met,
		   output reg [15:0]   zm_progress,
		   output reg [31:0]   zm_out_stats
  );

  
`include "hmac_params.v"

  reg [63:0]  key_in_data;
  reg [71:0]  tuser_in;
  reg [63:0]  zm_idle;
  reg [7:0]   zm_cmd;
  reg [3:0]   zm_response_status;
  reg [511:0] zm_text_in_reg;
  reg [5:0]   zm_text_32b_index;
  reg [7:0]   zm_core_out_count;
  wire [15:0] fifo_out_free_count;
  wire 	      fifo_out_free;
  reg [31:0]  zm_mac_reg;
  reg [95:0]  zm_keystream96;
  reg [31:0]  zm_keystreamQ;
  reg [15:0]  zm_in_message_size;
  reg [19:0]  zm_in_message_bits;
  reg [15:0]  zm_in_message_csize;
  reg [15:0]  zm_in_message_isize;
  reg [15:0]  zm_in_message_lines;
  reg [15:0]  zm_message_size_inprogress;
  reg 	      zm_in_readyQ;
  reg 	      zm_done;

  // Module test mode: Writing intermmediate lfsr values & keystream words to fifo_out
  reg [511:0] zm_test_mode_keystream;
  reg 	      zm_test_mode_keystream_valid;
  wire [511:0] zm_test_mode_lfsr;
  wire 	       zm_test_mode_lfsr_valid;
  reg	       zm_test_mode_text_in_valid;
  wire [511:0] zm_test_mode_data;
  wire 	       zm_test_mode_data_valid;
 
  reg 	      zm_bypass_or_header_valid;
  reg 	      zm_bypass_or_header;
  reg [1:0]   zm_wait_keystream;
  reg 	      zm_update_hmac_countQ;
  reg 	      zm_hmac_matchQ;
  reg 	      zm_core_valid;
  reg [3:0]   zm_channel_id;
  reg [5:0]   zm_init_count;
  reg 	      zm_core_last;
  reg [63:0]  zm_core_keep; // TBD: Save this register by directly driving sbu2pci_tkeep via wires
  reg [63:0]  zm_core_util; // TBD: Save this register by directly driving sbu2pci_tkeep via wires
  reg [63:0]  zm_core_elapsed_time; // TBD: Save this register by directly driving sbu2pci_tkeep via wires
  reg [47:0]  zm_core_busy_time; // TBD: Save this register by directly driving sbu2pci_tkeep via wires
  reg [31:0]  zm_clc_freq;
  
  reg [4:0]   hmacin_module_nstate;
  reg [4:0]   hmacin_module_return_state;
  reg [2:0]   hmacout_module_nstate;

  reg [511:0] zm_out_accum_reg;
  reg [511:0] zm_in_header;

  reg [31:0] zm_mac0;
  reg [31:0] zm_mac1;
  reg [31:0] zm_mac2;
  reg [31:0] zm_mac3;
  reg [31:0] zm_mac4;
  reg [31:0] zm_mac5;
  reg [31:0] zm_mac6;
  reg [31:0] zm_mac7;
  reg [31:0] zm_mac8;
  reg [31:0] zm_mac9;
  reg [31:0] zm_mac10;
  reg [31:0] zm_mac11;
  reg [31:0] zm_mac12;
  reg [31:0] zm_mac13;
  reg [31:0] zm_mac14;
  reg [31:0] zm_mac15;
  reg [31:0] zm_mac16;
  reg [31:0] zm_mac17;
  reg [31:0] zm_mac18;
  reg [31:0] zm_mac19;
  reg [31:0] zm_mac20;
  reg [31:0] zm_mac21;
  reg [31:0] zm_mac22;
  reg [31:0] zm_mac23;
  reg [31:0] zm_mac24;
  reg [31:0] zm_mac25;
  reg [31:0] zm_mac26;
  reg [31:0] zm_mac27;
  reg [31:0] zm_mac28;
  reg [31:0] zm_mac29;
  reg [31:0] zm_mac30;
  reg [31:0] zm_mac31;
  reg [31:0] zm_mac_0_7;
  reg [31:0] zm_mac_8_15;
  reg [31:0] zm_mac_16_23;
  reg [31:0] zm_mac_24_31;
  reg [31:0] zm_mac_0_31;

  reg [127:0] zm_iv;               // Initializatioin Vector
  reg [127:0] zm_key;              // Initialization Key
  reg 	      zm_go;               // core is triggered to start. Asserted after all inputs (IV, Key, pc_text) are ready
  reg 	      zm_go_asserted;      // core is triggered to start. Asserted after all inputs (IV, Key, pc_text) are ready
  wire [31:0] zm_keystream;        // holding flipped bytes of zm_keystream_out
  wire 	      zm_keystream_valid;  // Output - a valid 32bit output text on zm_keystream. Valid for 1 clock
  wire [63:0] zm_bypass_keep;
  reg [95:0]  zm_keystream96_lastkey; // holding last keystream, from position LENGTH (GET_WORD(keystream[], LENGTH))
  reg [3:0]   mac_bytes;
  reg [31:0]  cipher_bytes;
  reg [511:0] zm_in_flit2;
  
  assign zm_update_hmac_count = zm_update_hmac_countQ;
  assign zm_hmac_match = zm_hmac_matchQ;
  
  // TBD: Verify replacing this 'free_count' scheme
  assign fifo_out_free_count = MODULE_FIFO_OUT_SIZE - {6'h00, fifo_out_data_count};
  // *out_free count should be bigger (rather than GE) than *message_lines, to account for the header line as well 
  assign fifo_out_free = (fifo_out_free_count > zm_in_message_lines) ? 1'b1 : 1'b0;

  // fifo_in watermark
  // Incoming messages are handled (movede to core), once the specified watermark has been exceeded.
  // zm_in_watermark[4:0]:
  //      [4]   - A new watermark is present at zm_in_watermark[3:0]. This indication is valid for 1 clock only !!
  //              
  //    [3:0]   - zm_in_watermark_data
  //              Fifo_in capacity high watermark, 32 fifo lines (2KB) per tick. Default 0
  //              The transfer from fifo_in to core is held until this watermark is exceeded.
  //              This capability is aimed for testing the cores utilization & tpt:
  //              1. To utilize all cores, there is a need to apply the messages to the cores as fast as possible.
  //              2. To eliminate the dependence on pci2sbu incoming messages rate, we accumulate into fifo_in first
  //              3. Once the watermark is exceeded, the messages are fed to the cores at full speed (512b/clock). 
  //              Usage Note: This watermark is effective only once, immediateley after writing afu_ctrl1.
  //                          To reactivate, rewrite to afu_ctrl1 is required 
  reg 	      zm_in_watermark_valid;
  wire 	      zm_in_watermark_hit;
  wire 	      zm_in_message_valid;
  wire [11:0] zm_in_packet_flits;
  wire [11:0] pkts_fwd_data_free;
  reg [287:0] head_baseurl; // HEAD, 36B
  reg [351:0] body_baseurl; // BODY, 44B
  reg [343:0] sig_baseurl;  // SIG, 43B
  reg [47:0]  timestamp;
  reg [2:0]   hmac_test_mode_wait2;
  

  assign zm_in_watermark_hit = (fifo_in_data_count >= {1'b0, zm_in_watermark[3:0], 5'h00}) ? 1'b1 : 1'b0;
  assign zm_in_message_valid = zm_in_valid & zm_in_watermark_valid;
  assign zm_in_watermark_met = zm_in_watermark_valid;

  // incoming packet size is present at first packet flit.
  // first message flit:   zm_in_data[71:0] = TUSER[71:0]
  // CoAP incoming packet TUSER[]:
  // [71:56] - Streering_Tag
  // ...
  // [29:16] - Packet Length (bytes)
  // ...
  //
  assign zm_in_packet_flits = {4'b0, zm_in_data[29:22]} + (zm_in_data[21:16] == 6'h00) ? 12'h000 : 12'h001;
  
// calculating pkts_fwd fifo free space:
  assign pkts_fwd_data_free = 12'h200 - {2'b0, pkts_fwd_data_count};
  

  always @(posedge zm_clk) begin
    if (zm_reset) begin
      zm_in_watermark_valid <= 1; // Default zero watermark is assumed, thus messages are allowed from fifo_in to core following reset 
    end
    else
      begin
      if (zm_in_watermark[4])
	zm_in_watermark_valid <= 1'b0;
      if (zm_in_watermark_hit)
	zm_in_watermark_valid <= 1'b1;
      end
  end

  wire   hmac_module_test_mode;
  assign hmac_module_test_mode = (zm_in_hmac_test_mode == 3'b100) ? 1'b1 : 1'b0;

  // Verify sufficient free space in pkts_fifo, before starting loading next packet:
  // 1. Normnl mode: minimum free space should be: incoming packet size + 1. The extra 1 is to cover for the metadata flit
  // 2. hmac_module_test mode: 10 flits are saved to pkts_fwd fifo per each incoming packet, independent of the packet size.
  wire 	 pkts_fwd_free;
  assign pkts_fwd_free = hmac_module_test_mode ? (pkts_fwd_data_free > 12'h00a) : (pkts_fwd_data_free > (zm_in_packet_flits + 12'h001));
  
  
  // hmac_module input ctrl:
  localparam [4:0]
    HMACIN_IDLE                   = 5'b00000,
    HMACIN_METADATA               = 5'b00001,
    HMACIN_FLIT1                  = 5'b00011,
    HMACIN_FLIT2                  = 5'b00100,
    HMACIN_FLIT3                  = 5'b00101,
    HMACIN_SAMPLE_HEAD_BODY_SIG   = 5'b00110,
    HMACIN_FWD_PACKET_TRAIL       = 5'b00111,
    HMACIN_TEST_MODE_WRITE_WAIT   = 5'b01000,
    HMACIN_TEST_MODE2             = 5'b01001,
    HMACIN_TEST_MODE3             = 5'b01010,
    HMACIN_TEST_MODE4             = 5'b01011,
    HMACIN_TEST_MODE5             = 5'b01100,
    HMACIN_TEST_MODE6             = 5'b01101,
    HMACIN_TEST_MODE7             = 5'b01110,
    HMACIN_TEST_MODE8             = 5'b01111,
    HMACIN_TEST_MODE9             = 5'b10000,
    HMACIN_END                    = 5'b11111;
  
  always @(posedge zm_clk) begin
    if (zm_reset) begin
      hmacin_module_nstate <= HMACIN_IDLE;
      hmacin_module_return_state <= HMACIN_IDLE;
      pkts_fwd_in_data_source <= 4'h0;
      hmac_test_mode_last <= 1'b0;
      timestamp <= 48'h00000000000;
      zm_in_message_size <= 16'h000;
      zm_in_message_bits <= 16'h000;
      zm_message_size_inprogress <= 16'h0000;
      zm_in_readyQ <= 1'b0;
      zm_core_last <= 1'b0;
      zm_core_valid <= 1'b0;
      zm_response_status <= 4'h0; // Default OK status
      zm_go <= 0;
      zm_go_asserted <= 0;
      zm_done <= 1'b0;
      zm_text_32b_index <= 0;
      zm_bypass_or_header_valid <= 1'b0;
      zm_bypass_or_header <= 1'b0;
      zm_wait_keystream <= 2'b11;
      zm_mac_reg <= 32'h00000000;
      zm_keystream96[95:0] <= 96'h0000000000000000;
      zm_out_status_data <= 8'h00;
      zm_out_status_valid <= 1'b0;
      zm_text_in_reg  <= 512'b0;
      zm_out_accum_reg <= 512'b0;
      zm_idle <= 64'h0000000000000000;
      

      // Reporting operation progress.
      // Used by hmac_afu to track the module's total_load.
      // total_load is then used for a load based input_buffer to fifox_in arbitration
      //
      // zm_progress[15:0]:
      // [3:0] - Reporting a micro operation completed: 
      //       0001 - C/I/Bypass operation: overhead is done
      //       0010 - C/I/Bypass operation: another 512b line is done
      //       x1xx - reserved
      //       1xxx - reserved
      // [7:4]  - command
      // [15:8] - last_word index within a 512b line 
      zm_progress <= 16'h00;
      zm_test_mode_keystream_valid <= 1'b0;
      zm_test_mode_text_in_valid <= 1'b0;
      sha1_text_vld <= 1'b0;
      sha2_text_vld <= 1'b0;
      sha3_text_vld <= 1'b0;
      sha4_text_vld <= 1'b0;
      sig_in_vld <= 1'b0;
      zm_in_readyQ <= 1'b0;
      hmac_test_mode_wait2 <= 3'b000;
      pkts_fwd_in_vld <= 1'b0;
    end

    else 
      begin
	// Free running counter, used to timestamp trace samples.
	// Count is started immediately after reset (either hard or soft reset).
	// Count is wrapped around 2^48
	// Max time duration (@ 125 Mhz afu clock): 2^48 / 125 * 10^6 = 2252800 sec = 625 hours 
	timestamp <= timestamp + 1'b1;

	case (hmacin_module_nstate)
	  HMACIN_IDLE:
	    begin
	      pkts_fwd_in_data_source <= 4'h0;
	      hmac_test_mode_last <= 1'b0;
	      zm_idle <= zm_idle +1; // idle duration counter

	      // hmac module is triggered if:
	      // 1. There is at least 1 full coap packet at the input fifo
	      //    fifo_in is configured as a packet_fifo, thus zm_in_message_valid means there is at least one full message in fifo_in
	      //    fifo_in contains 1 or more packets, where 1 packet means 1 message. 
	      // 2. there is sufficient space in the various destination fifos to hold the packet:
	      //    2.1. At least 1 free flit in sha_module1 thru sha_module4 text_in
	      //    2.2. At least 1 free flit in sig_fifo
	      //    2.3. Sufficient free space in pkts_fwd fifo to host the entire incoming packet
	      //         The incoming packet size is extracted from the first packet line, in which the packet TUSER[] is placed.
	      if (zm_in_message_valid && sha1_text_rdy && sha2_text_rdy && sha3_text_rdy && sha4_text_rdy && sig_in_rdy && pkts_fwd_in_rdy && pkts_fwd_free)
		begin
		  zm_in_header <= zm_in_data;
		  
		  zm_in_message_lines <= {4'h0, zm_in_packet_flits}; // Message size in 512b ticks
		  //		  zm_cmd <= zm_in_force_modulebypass ? MESSAGE_CMD_MODULEBYPASS : zm_in_data[511:504];
		  //		  zm_key <= zm_in_data[415:288];
		  //		  zm_iv <= zm_in_data[287:160];
		  //		  zm_channel_id[3:0] <= zm_in_data[23:20]; //  TBD: Verify input buffer CTRL adds channel_id to fifox_in
		  zm_init_count <= 6'h00;
		  //		  zm_mac_reg <= 32'h00000000; // Prior to MAC calculation, initial MAC should be cleared
		  
		  // First line to module is the hmac metadata
		  // The key is already read from keys_buffer
		  // module_in_metadata[63:0] = hmac key
		  // module_in_metadata[79:64] = packet length (TUSER.Length)
		  // module_in_metadata[95:80] = Steering Tag (TUSER.steering_tag)
                  key_in_data  <= zm_in_data[63:0];
		  zm_in_message_size <= zm_in_data[79:64]; // Message size in bytes
		  zm_in_message_bits <= {zm_in_data[79:64] << 3, 3'b0}; // Message size in bits
		  
		  // The packet metadata is also written to pkts_fwd fifo.
		  // First flit (packet metadata is always written to pkts_fwd fifo, independent of hmac_module_test_mode
		  // Write to pkts_fwd fifo and drop the message metadata from zm_in
		  pkts_fwd_in_vld <= 1'b1;

		  zm_in_readyQ <= 1'b1;
		  hmacin_module_nstate <= HMACIN_METADATA;
		end
	    end
	  
	  HMACIN_METADATA:
	    begin
	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;
		  zm_in_readyQ <= 1'b1;
		  //	      zm_bypass_or_header_valid <= 1'b1;

		  if (hmac_module_test_mode)
		    // Select next pkts_fwd data source to  be written
		    pkts_fwd_in_data_source <= pkts_fwd_in_data_source + 4'h1;

		  hmacin_module_nstate <= HMACIN_FLIT1;
		end
	      else
		begin
		  zm_in_readyQ <= 1'b0;
		  pkts_fwd_in_vld <= 1'b0;
		end
	    end
	  
	  HMACIN_FLIT1:
	    begin
	      // CoAP packet format
	      // ETH(14B)/IP(20B/UDP(8B)/CoAP_Header(16B)/CoAP_Payload... 
	      // CoAP header & payload:
	      // packet offset (byte) | Coap header offset
	      // 43                   | 0-15:   coap header
  	      //                      | 16-181: cbor data
	      //                      | 16:     0xa2 (map (2))
	      //                      | 17:     0x65 (text (5))
	      //                      | 18-22:  "token"
	      //                      | 23-24:  78-7D (text (125))
	      // 52                   | 25-149: token bytes. HEAD = 25-60 (36 bytes), BODY = 62-105 (44 bytes), sig = 107-149 (43 bytes)
	      //                      | 150:    0x67 (text (7))
	      //                      | 151-157: "payload"
	      //                      | 158-159: 78-19 (text (25))
	      //                      | 160-181: "containing nothing useful"
	      //
	      // CoAP packet distribution (between various hmac_module fifos)  scheme:
	      // 1. Start loading from zm_in_data to pkts_fwd_fifo
	      // 2. While (1), sample (into local registers) lines containing HEAD, BODY and SIG.
	      //                     {HEAD(36B), ".", BODY_head(27B)},
	      //                     {BODY_trail(17B), sha256_padding(47B)}
	      //
	      // flit (byte)          | Coap header offset
	      // flit1[511:0]         |  { ETH/IP/UDP          (42B), 
	      //                      |    coap header         (16B), 
	      //                      |    0xa2 (map (2))      (1B), 
	      //                      |    0x65 (text (5)),    (1B),
	      //                      |    "toke"              (4B) }
	      //
	      // flit2[511:0]         |  { "n"                 (1B),
	      //                      |    78-7D (text (125))  (2B),
	      //                      |    HEAD = 25-60        (36B), 
	      //                      |    "." = 'h2e          (1B),
              //                      |    BODY = 62-85        (24B) }
	      //
              // flit3[511:0]         |  { BODY = 86-105       (20B), 
	      //                      |    "." = 'h2e          (1B),
	      //                      |    sig = 107-149       (43B),
	      //
	      // flit4[511:0]         |    0x67 (text (7))     (1B)  }
	      //                      |  { "payload"           (7B),
	      //                      |    78-19 (text (25))   (2B),
	      //                      |    "containing nothing useful" (22B),
	      //                      |    NA                  (32B) }
	      //
	      // flit5...             | rest of CoAP packet payload
	      //
	      // CoAP packe split scheme:
	      // sha_module3.text_in = { flit2[487:0], flit3[511:488] }
	      // sha_module4.text_in = { flit3[487:352], padding(47B) }
	      // sig.text_in = { flit3[351:8], 168'b0 }

	      // Read first CoAP packet flit, while writing it to pkts_fwd fifo 
	      // Verify zm_in is valid and that there is suficient space in desination fifo, just in case...
	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  zm_in_readyQ <= 1'b1;
		  pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;
		  hmacin_module_nstate <= HMACIN_FLIT2;
		end	      
	      else
		begin
		  zm_in_readyQ <= 1'b0;
		  pkts_fwd_in_vld <= 1'b0;
		end
	    end
	  
	  HMACIN_FLIT2:
	    begin
	      // Forward second flit, while sampling for future HEAD & BODY extraction
	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  zm_in_readyQ <= 1'b1;
		  pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;

		  // Sample  HEAD for base64url decoder
		  head_baseurl <= zm_in_data[487:200]; // 36B

		  // Sample  HEAD for base64url decoder
		  body_baseurl[351:160] <= zm_in_data[191:0]; // BODY_head, 24B
		  hmacin_module_nstate <= HMACIN_FLIT3;
		end
	      else
		begin
		  zm_in_readyQ <= 1'b0;
		  pkts_fwd_in_vld <= 1'b0;
		end
	      
	    end

	  HMACIN_FLIT3:
	    begin
	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  zm_in_readyQ <= 1'b1;
		  pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;

		  body_baseurl[159:0] <= zm_in_data[511:352]; // BODY trail, 20B
		  sig_baseurl <= zm_in_data[343:0];         // SIG, 43B

		  hmacin_module_nstate <= HMACIN_SAMPLE_HEAD_BODY_SIG;
		end
	      else
		begin
		  zm_in_readyQ <= 1'b0;
		  pkts_fwd_in_vld <= 1'b0;
		  sig_in_vld <= 1'b0;
		end
	    end

	  HMACIN_SAMPLE_HEAD_BODY_SIG:
	    begin
	      // The written data is driven outside this SM
	      // sha1_text and sha2_text are also ready by now.
	      sha1_text_vld <= 1'b1;
	      sha2_text_vld <= 1'b1;
	      sha3_text_vld <= 1'b1;
	      sha4_text_vld <= 1'b1;
	      sig_in_vld <= 1'b1;

	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  if (zm_in_last)
		    begin
		      zm_in_readyQ <= 1'b0;
		      // While in test_mode: writing source=sha1_text
		      pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b1 : 1'b0;
		      hmacin_module_return_state <= HMACIN_TEST_MODE2;
		      hmacin_module_nstate <= hmac_module_test_mode ? HMACIN_TEST_MODE_WRITE_WAIT : HMACIN_END;
		    end
		  else
		    begin
		      // Keep forwarding the packet trail from zm_in to pkts_fwd fifo
		      zm_in_readyQ <= 1'b1;
		      pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;
		      hmacin_module_nstate <= HMACIN_FWD_PACKET_TRAIL;
		    end
		end
	    end
	  
	  HMACIN_FWD_PACKET_TRAIL:
	    begin
	      sha1_text_vld <= 1'b0;
	      sha2_text_vld <= 1'b0;
	      sha3_text_vld <= 1'b0;
	      sha4_text_vld <= 1'b0;
	      sig_in_vld <= 1'b0;

	      if (zm_in_valid && pkts_fwd_in_rdy)
		begin
		  if (~zm_in_last)
		    begin
		      zm_in_readyQ <= 1'b1;
		      pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b0 : 1'b1;
		      hmacin_module_nstate <= HMACIN_FWD_PACKET_TRAIL;
		    end
		  else
		    begin
		      zm_in_readyQ <= 1'b0;

		      // test_mode: Write sha1_text
		      pkts_fwd_in_vld <= hmac_module_test_mode ? 1'b1 : 1'b0;

		      hmacin_module_return_state <= HMACIN_TEST_MODE2;
		      hmacin_module_nstate <= hmac_module_test_mode ? HMACIN_TEST_MODE_WRITE_WAIT : HMACIN_END;
		    end
		end

	      else
		begin
		  zm_in_readyQ <= 1'b0;
		  pkts_fwd_in_vld <= 1'b0;
		end
	    end

	  HMACIN_TEST_MODE_WRITE_WAIT:
	    begin
	      zm_in_readyQ <= 1'b0;
	      pkts_fwd_in_vld <= 1'b0;
	      sha1_text_vld <= 1'b0;
	      sha2_text_vld <= 1'b0;
	      sha3_text_vld <= 1'b0;
	      sha4_text_vld <= 1'b0;
	      sig_in_vld <= 1'b0;

	      // Force *last along with writing sha4_hout, to trigger the HMACOUT_* SM (waiting for a full packet in pkts_fwd fifo to start)
	      hmac_test_mode_last <= (hmacin_module_return_state == HMACIN_TEST_MODE6) ? 1'b1 : 1'b0;

	      // prepare for next test_mode source to be written
	      pkts_fwd_in_data_source <= pkts_fwd_in_data_source + 4'h1;
	      hmacin_module_nstate <= hmacin_module_return_state;
	    end

	  HMACIN_TEST_MODE2:
	    begin
	      // test_mode: writing source=sha2_text
	      pkts_fwd_in_vld <= 1'b1;

	      // Test mode: Keep dropping lines from zm_in* until end of packet
	      // If current rceived packet is ended, continue with test_mode samples capture
	      hmacin_module_return_state <= HMACIN_TEST_MODE3;
	      hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
	    end

	  HMACIN_TEST_MODE3:
	    begin
	      if (sha1_hout_vld && sha1_hout_rdy && pkts_fwd_in_rdy)
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE4;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end

	  HMACIN_TEST_MODE4:
	    begin
	      if (pkts_fwd_in_rdy)
		// Writing sha2_hout. It is already valid, along with sha1_hout
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE5;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end
	  
	  HMACIN_TEST_MODE5:
	    begin
	      if (sha3_hout_vld && sha3_hout_rdy && pkts_fwd_in_rdy)
		// Writing sha3_hout.
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE6;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end
	  
	  HMACIN_TEST_MODE6:
	    begin
	      if (sha4_hout_vld && sha4_hout_vld && pkts_fwd_in_rdy)
		// Writing sha4_hout
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE7;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end
	  
	  HMACIN_TEST_MODE7:
	    begin
	      if (sha5_hout_vld && sha5_hout_rdy && pkts_fwd_in_rdy)
		// Writing sha5_hout
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE8;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end
	  
	  HMACIN_TEST_MODE8:
	    begin
	      if ((hmacout_module_nstate == HMACOUT_PACKET_MATCH1) && pkts_fwd_in_rdy)
		// Writing hmac_out_baseurl at the same time the HMACOUT_* SM examines hmac_match status
		// This write also writes hmac_match to pkts_fwd fifo, along with hmac_out_baseurl
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_return_state <= HMACIN_TEST_MODE9;
		  hmacin_module_nstate <= HMACIN_TEST_MODE_WRITE_WAIT;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end

	  HMACIN_TEST_MODE9:
	    begin
	      if (pkts_fwd_in_rdy)
		// Writing sig_out_baseurl. It is already valid, along with hmac_out_baseurl
		begin
		  pkts_fwd_in_vld <= 1'b1;
		  hmacin_module_nstate <= HMACIN_END;
		  hmac_test_mode_last <= 1'b1;
		end
	      else
		pkts_fwd_in_vld <= 1'b0;
	    end
	  
	  HMACIN_END:
	    begin
	      zm_test_mode_keystream_valid <= 1'b0;
	      zm_core_last <= 1'b0;
	      zm_in_readyQ <= 1'b0;
	      zm_progress <= {8'h00, zm_cmd[3:0], 4'b0000};
	      zm_out_status_valid <= 1'b0;
	      zm_go <= 1'b0;
	      zm_done <= 1'b0;
	      zm_bypass_or_header <= 1'b0;
	      zm_wait_keystream <= 2'b10;
	      zm_in_readyQ <= 1'b0;
	      pkts_fwd_in_vld <= 1'b0;
	      sha1_text_vld <= 1'b0;
	      sha2_text_vld <= 1'b0;
	      sha3_text_vld <= 1'b0;
	      sha4_text_vld <= 1'b0;
	      sig_in_vld <= 1'b0;
	      hmacin_module_nstate <= HMACIN_IDLE;
	    end
	  
	  default:
	    begin
	    end
	endcase
      end
  end
  
  // ???? Verify that zm_out_accum_reg[31:0] (last 32b in a line) is valid at the time of write to fifo_out
  //
  // Bypass cmd: Selecting between bypassed data and core output
  assign zm_bypass_keep = (zm_in_message_size >= FIFO_LINE_SIZE) ? 
			  // TBD: Replace 64'b1 with count_to_keep(zm_in_message_size[5:0]): 
			  FULL_LINE_KEEP : 64'b1; 
  
  assign zm_in_ready = zm_in_readyQ;

  reg hmacout_pass_in_progress;

  // hmac_module output ctrl:
  localparam [2:0]
    HMACOUT_IDLE          = 3'b000,
    HMACOUT_PACKET_MATCH1 = 3'b001,
    HMACOUT_PACKET_MATCH2 = 3'b010,
    HMACOUT_PACKET_PASS   = 3'b011,
    HMACOUT_PACKET_DROP   = 3'b100,
    HMACOUT_PACKET_WAIT   = 3'b101,
    HMACOUT_END           = 3'b111;
  
  always @(posedge zm_clk) begin
    if (zm_reset) begin
      zm_out_valid <= 1'b0;
      hmac_out_rdy <= 1'b0;
      sig_out_rdy <= 1'b0;
      pkts_fwd_out_rdy <= 1'b0;
      pkts_fwd_user <= 72'b0;
      hmacout_pass_in_progress <= 1'b0;
      pkts_fwd_out_second_last <= 1'b0;
      
      zm_update_hmac_countQ <= 1'b0;
      hmac_matchQ <= 1'b0;
      zm_hmac_matchQ <= 1'b0;
      hmacout_module_nstate <= HMACOUT_IDLE;
    end

    else 
      begin
	case (hmacout_module_nstate)
	  HMACOUT_IDLE:
	    begin
	      // hmacout SM is triggered, if:
	      // 1. Both hmac and reference sig are present
	      // 2. pkts_fwd fifo has a valid (complete) packet
	      // 3. The output port, zm_out, is ready.
	      //
	      // Once triggered, this SM will:
	      // 1. If hmac_match, a full packet will be transferred to zm_out
	      // 2. If hmac_no_match, a full packet will be dropped from paclets_fwd fifo, with no write to zm_out
	      pkts_fwd_out_second_last <= 1'b0;
	      hmacout_pass_in_progress <= 1'b0;
	      if (hmac_out_vld && sig_out_vld && pkts_fwd_out_vld && zm_out_ready)
		begin
		  // Allow 1 clock to hmac_match signal to settle
		  // hmac_baseurtl support to be valid by now (a full clock from hmac_text_out fifo through text2baseurl logic): 
		  hmac_out_baseurlQ <= hmac_out_baseurl;
		  hmacout_module_nstate <= HMACOUT_PACKET_MATCH1;
		end
	      else 
		hmacout_module_nstate <= HMACOUT_IDLE;
	    end
	  
	  HMACOUT_PACKET_MATCH1:
	    begin
	      // Let the synthesizer to determine how to implement this 43B comparison:
	      hmac_matchQ <= (hmac_out_baseurlQ == sig_out_baseurl) ? 1'b1 : 1'b0;
	      hmacout_module_nstate <= HMACOUT_PACKET_MATCH2;
	    end

	  HMACOUT_PACKET_MATCH2:
	    begin
	      // hmac_match is settled.
	      // Take the appropriate action and drop hmac & sig fifos

	      // Test Mode:
	      // dropping sig_out and hmac_out fifos is postponed to end of PASS/DROP sequence, to allow HMACIN_* SM more time to sample the sig_out[] and hmac_out
	      //	      hmac_out_rdy <= 1'b1;
	      //	      sig_out_rdy <= 1'b1;
	      if (hmac_matchQ || zm_in_force_corebypass || hmac_module_test_mode)
		// packet is forwarded if sig match, or when core bypass mode or hmac_test_mode has been set
		begin
		  hmacout_module_nstate <= HMACOUT_PACKET_PASS;
		  hmacout_pass_in_progress <= 1'b1;
		end
	      else
		hmacout_module_nstate <= HMACOUT_PACKET_DROP;
	    end

	  HMACOUT_PACKET_PASS:
	    begin
	      // Read a complete packet from pkts_fwd fifo and write to zm_out
	      // pkts_fwd_out_vld is not checked here, since it is a packet fifo, and its out_vld  was already checked.
	      if (zm_out_ready)
		begin
		  zm_out_valid <= 1'b1;
		  pkts_fwd_out_rdy <= 1'b1;

		  hmacout_module_nstate <= HMACOUT_PACKET_WAIT;
		end

	      else
		begin
		  zm_out_valid <= 1'b0;
		  pkts_fwd_out_rdy <= 1'b0;
		  hmacout_module_nstate <= HMACOUT_PACKET_PASS;
		end		
	    end
	  
	  HMACOUT_PACKET_DROP:
	    begin
	      hmac_out_rdy <= 1'b0;
	      sig_out_rdy <= 1'b0;

	      // Drop a complete packet from pkts_fwd fifo.
	      // pkts_fwd_out_vld is not checked here, since it is a packet fifo, and its out_vld  was already checked.
	      pkts_fwd_out_rdy <= 1'b1;
	      
	      hmacout_module_nstate <= HMACOUT_PACKET_WAIT;
	    end
	  
	  HMACOUT_PACKET_WAIT:
	    begin
	      zm_out_valid <= 1'b0;
	      pkts_fwd_out_rdy <= 1'b0;

	      // pass operation is terminated if
	      // 1. end of packet and not in test_mode: a single packet is passed in normal mode.
	      // 2. In test mode, the last flit has been written: the whole pkts_fwd fifo is emptied, independent of tlast

	      // Test mode: Selecting every other pkts_fwd_out_tlast
	      if (pkts_fwd_out_last)
		pkts_fwd_out_second_last <= ~pkts_fwd_out_second_last;
	      
	      if (pkts_fwd_out_last_ok)
		begin
		  // update hmac requests pass/drop counters (the counters are implemented in hmac_afu.v)
		  zm_update_hmac_countQ <= 1'b1;
		  zm_hmac_matchQ <= hmacout_pass_in_progress;
		  hmac_out_rdy <= 1'b1;
		  sig_out_rdy <= 1'b1;
		  hmacout_module_nstate <= HMACOUT_END;		  
		end
	      else
		begin
		  if (hmacout_pass_in_progress)
		    hmacout_module_nstate <= HMACOUT_PACKET_PASS;
		  else
		    hmacout_module_nstate <= HMACOUT_PACKET_DROP;
		end
	    end

	  HMACOUT_END:
	    begin
	      zm_update_hmac_countQ <= 1'b0;
	      hmac_matchQ <= 1'b0;
	      zm_hmac_matchQ <= 1'b0;
	      hmacout_pass_in_progress <= 1'b0;
	      hmac_out_rdy <= 1'b0;
	      sig_out_rdy <= 1'b0;
	      zm_out_valid <= 1'b0;
	      pkts_fwd_out_rdy <= 1'b0;
	      hmacout_module_nstate <= HMACOUT_IDLE;
	    end
	  
	  default:
	    begin
	    end
	endcase
      end
  end


  // ===========================================================================================================
  // sha module1:
  // ===========================================================================================================
  // First pipestage, calculating h(key ^ opad)
  wire [511:0] sha1_text;
  reg 	       sha1_text_vld;
  wire 	       sha1_text_rdy;
  wire [255:0] sha1_hin;
  wire 	       sha1_hin_vld;
  wire 	       sha1_hin_rdy;
  wire [255:0] sha1_hout;
  wire 	       sha1_hout_vld;
  wire 	       sha1_hout_rdy;

  wire   sha_module_test_mode;
 
  assign sha1_text = ((zm_in_hmac_test_mode == 3'b010) || (zm_in_hmac_test_mode == 3'b001))
                        ? 
		     // Testing sha_modules functioanlity, using reference test vectors.
                     // Test vectors borrowed from sha256 spec doc (C:\GabiG\Gabi@ACSL\Papers\sha\sha256-384-512.pdf)
                     // test_vector1 is a 512b block
                     // test_vector2 is a 1024 block
                     (zm_in_hmac_test_mode == 3'b001 ? TEST_VECTOR1 : TEST_VECTOR2_BLOCK1) // Test vectors
                        : 
                     {key_in_data, 448'b0} ^ OPAD ; // key_in_data ia zero padded, to total 512b length
  
  assign sha1_hin = 256'b0;            // First pipestage, no input H    
  assign sha1_hin_vld = 1'b0;          // The sha_module will ignore the hin port.
  assign sha1_hout_rdy = sha5_hin_rdy;
  
  sha_module sha_module1 
    (
     .clk(zm_clk),
     .reset(zm_reset),
     .first(1'b1), // set to either 0 or 1, depending on the sha256_core location along the hmac_core pipeline
     .text_vld(sha1_text_vld),
     .text_rdy(sha1_text_rdy),
     .text_data(sha1_text),
     
     // H input to sha module
     .hin_vld(sha1_hin_vld),
     .hin_rdy(sha1_hin_rdy),
     .hin_data(sha1_hin),
     
     // H output: 
     .hout_vld(sha1_hout_vld),
     .hout_rdy(sha1_hout_rdy),
     .hout_data(sha1_hout)
     );


  // ===========================================================================================================
  // sha module2:
  // ===========================================================================================================
  // First pipestage, calculating h(key ^ ipad)
  wire [511:0] sha2_text;
  reg 	       sha2_text_vld;
  wire 	       sha2_text_rdy;
  wire [255:0] sha2_hin;
  wire 	       sha2_hin_vld;
  wire 	       sha2_hin_rdy;
  wire [255:0] sha2_hout;
  wire 	       sha2_hout_vld;
  wire 	       sha2_hout_rdy;

  assign sha2_text = {key_in_data, 448'b0} ^ IPAD ; // key_in_data ia zero padded, to total 512b length
  assign sha2_hin = 256'b0;            // First pipestage, no input H    
  assign sha2_hin_vld = 1'b0;          // The sha_module will ignore the hin port.
  assign sha2_hout_rdy = sha3_hin_rdy;
  
  sha_module sha_module2 
    (
     .clk(zm_clk),
     .reset(zm_reset),
     .first(1'b1), // set to either 0 or 1, depending on the sha256_core location along the hmac_core pipeline
     .text_vld(sha2_text_vld),
     .text_rdy(sha2_text_rdy),
     .text_data(sha2_text),
     
     // H input to sha module
     .hin_vld(sha2_hin_vld),
     .hin_rdy(sha2_hin_rdy),
     .hin_data(sha2_hin),
     
     // H output: 
     .hout_vld(sha2_hout_vld),
     .hout_rdy(sha2_hout_rdy),
     .hout_data(sha2_hout)
     );


  // ===========================================================================================================
  // sha module3:
  // ===========================================================================================================
  wire [511:0]  sha3_text;
  reg 	       sha3_text_vld;
  wire 	       sha3_text_rdy;
  wire [255:0] sha3_hin;
  wire 	       sha3_hin_vld;
  wire 	       sha3_hin_rdy;
  wire [255:0] sha3_hout;
  wire 	       sha3_hout_vld;
  wire 	       sha3_hout_rdy;

  assign sha3_hin_vld = sha2_hout_vld;
  assign sha3_hin = sha2_hout;
  assign sha3_hout_rdy = sha4_hin_rdy;
 
  assign sha3_text = {head_baseurl, 8'h2e, body_baseurl[351:136]}; // h2e == ascii(".")

  sha_module sha_module3 
    (
     .clk(zm_clk),
     .reset(zm_reset),
     .first(1'b0), // set to either 0 or 1, depending on the sha256_core location along the hmac_core pipeline
     .text_vld(sha3_text_vld),
     .text_rdy(sha3_text_rdy),
     .text_data(sha3_text),
     
     // H input to sha module
     .hin_vld(sha3_hin_vld),
     .hin_rdy(sha3_hin_rdy),
     .hin_data(sha3_hin),
     
     // H output: 
     .hout_vld(sha3_hout_vld),
     .hout_rdy(sha3_hout_rdy),
     .hout_data(sha3_hout)
     );


  // ===========================================================================================================
  // sha module4:
  // ===========================================================================================================
  wire [511:0] sha4_text;
  wire [375:0] sha4_text_padding; // 47B padding !
  reg 	       sha4_text_vld;
  wire 	       sha4_text_rdy;
  wire [255:0] sha4_hin;
  wire 	       sha4_hin_vld;
  wire 	       sha4_hin_rdy;
  wire [255:0] sha4_hout;
  wire 	       sha4_hout_vld;
  wire 	       sha4_hout_rdy;

  // sha_module4 padding:
  // sha_module2 & sha_module3 & sha_module4 calculate the first sha inside the hmac formula.
  // ==> HEAD, BODY length after baseurl decoding: HEAD(27B), BODY(33B)
  //  sha({Key^ipad(64B),                       // calculated in sha_module2
  //      {HEAD(36B), ".", BODY_head(27B)},     // calculated in sha_module3
  //      {BODY_tail(17B), padding(47B}})       // calculated in sha_module4
  //
  // sha_module4 padding:
  // Total text length, l = 64B + 36B + 1B + 44B = 145B = 1160b = 64'h488
  // Zeros padding, k, is calculated from: 
  //   l + 1 + k = 448 mod 512 
  //   k = 311   
  // sha4_text_padding = {1'b1, k'b0, 64'total_text_length} 
  assign sha4_text_padding = {1'b1, 311'b0, 64'h488};
  
  assign sha4_hin_vld = sha3_hout_vld;
  assign sha4_hin = sha3_hout;
  assign sha4_text = {body_baseurl[135:0], sha4_text_padding};
  assign sha4_hout_rdy = sha5_text_rdy;

  sha_module sha_module4 
    (
     .clk(zm_clk),
     .reset(zm_reset),
     .first(1'b0), // set to either 0 or 1, depending on the sha256_core location along the hmac_core pipeline
     .text_vld(sha4_text_vld),
     .text_rdy(sha4_text_rdy),
     .text_data(sha4_text),
     
     // H input to sha module
     .hin_vld(sha4_hin_vld),
     .hin_rdy(sha4_hin_rdy),
     .hin_data(sha4_hin),
     
     // H output: 
     .hout_vld(sha4_hout_vld),
     .hout_rdy(sha4_hout_rdy),
     .hout_data(sha4_hout)
     );


  // ===========================================================================================================
  // sha module5:
  // ===========================================================================================================
  wire [511:0] sha5_text;
  wire 	       sha5_text_vld;
  wire 	       sha5_text_rdy;
  wire [255:0] sha5_hin;
  wire 	       sha5_hin_vld;
  wire 	       sha5_hin_rdy;
  wire [255:0] sha5_hout;
  wire 	       sha5_hout_vld;
  wire 	       sha5_hout_rdy;

  assign sha5_hin_vld = sha1_hout_vld;
  assign sha5_hin = sha1_hout;
  assign sha5_text_vld = sha4_hout_vld;

  // sha_module1 & sha_module5 calculate the second sha inside the hmac formula:
  //    sha({K^opad(64B),                             // sha_module1, 512b 
  //        {sha_module4.hout(32B), padding(32B)});   // sha_module5, 256b + 256b padding
  //
  // Original length == 64B + 32B = 768b
  //
  // Padding the 768b original length to 1024b total length:
  // '1', followed by k zeros, followed by the 64b original length.
  // k is calculated from: l+1+k == 448 mod 512
  //  k = 448 - (768 mod 512) - 1 = 191.
  // l = 768 = 64'h300
  assign sha5_text = ((zm_in_hmac_test_mode == 3'b010) || (zm_in_hmac_test_mode == 3'b001))
                        ? 
		     // Testing sha_modules functioanlity, using reference test vectors.
                     // Test vectors borrowed from sha256 spec doc (C:\GabiG\Gabi@ACSL\Papers\sha\sha256-384-512.pdf)
                     // test_vector1 is a 512b block
                     // test_vector2 is a 1024 block
                     (zm_in_hmac_test_mode == 3'b001 ? TEST_VECTOR1 : TEST_VECTOR2_BLOCK2) // Test vectors
                        : 
                     {sha4_hout, 1'b1, 191'b0, 64'h300}; 


  
  // sha module:
  sha_module sha_module5 
    (
     .clk(zm_clk),
     .reset(zm_reset),
     .first(1'b0), // set to either 0 or 1, depending on the sha256_core location along the hmac_core pipeline
     .text_vld(sha5_text_vld),
     .text_rdy(sha5_text_rdy),
     .text_data(sha5_text),
     
     // H input to sha module
     .hin_vld(sha5_hin_vld),
     .hin_rdy(sha5_hin_rdy),
     .hin_data(sha5_hin),
     
     // H output: 
     .hout_vld(sha5_hout_vld),
     .hout_rdy(sha5_hout_rdy),
     .hout_data(sha5_hout)
     );

  
  // ===========================================================================================================
  // Reference signature fifo
  // distributed ram fifo, 16x256b
  // ===========================================================================================================
  // Reference sig 43B, loaded to sig_in_data[511:168]
  // 
  reg 	       sig_in_vld;
  wire 	       sig_in_rdy;
  wire [511:0]  sig_in_baseurl;
  wire 	       sig_out_vld;
  reg 	       sig_out_rdy;
  wire [511:0] sig_out; 
  wire [343:0] sig_out_baseurl; // 43B reference sig
  wire [167:0] unconnected168;

  assign sig_in_baseurl = {168'b0, sig_baseurl};
  assign sig_out_baseurl = sig_out[343:0];
  
  fifo_distram_16x512 sig_fifo 
    (
     .s_aclk(zm_clk),                // input wire s_aclk
     .s_aresetn(~zm_reset),          // input wire s_aresetn
     .s_axis_tvalid(sig_in_vld),     // input wire s_axis_tvalid
     .s_axis_tready(sig_in_rdy),     // output wire s_axis_tready
     .s_axis_tdata(sig_in_baseurl),  // input wire [511 : 0] s_axis_tdata
     .m_axis_tvalid(sig_out_vld),    // output wire m_axis_tvalid
     .m_axis_tready(sig_out_rdy),    // input wire m_axis_tready
     .m_axis_tdata(sig_out)          // output wire [511 : 0] m_axis_tdata
     );
  

  // ===========================================================================================================
  // HMAC fifo
  // distributed ram fifo, 16x256b
  // ===========================================================================================================
  wire 	       hmac_in_vld;
  wire 	       hmac_in_rdy;
  wire [255:0] hmac_in_data;
  wire 	       hmac_out_vld;
  reg 	       hmac_out_rdy;
  wire [257:0] hmac_out_text; // Extended from 256 to 258 bit, to the nearest multiple of 6 bits
  wire [343:0] hmac_out_baseurl; // 43B long calculated sig, in baseurl
  reg [343:0]  hmac_out_baseurlQ; // 43B long calculated sig, in baseurl

  assign hmac_in_vld = sha5_hout_vld;
  assign sha5_hout_rdy = hmac_in_rdy;
  assign hmac_in_data = sha5_hout;
  assign hmac_out_text[1:0] = 2'b00; // 2 bits padding, making the hma_out_test a multiple of base64 characters (multiple of 6 bits)

  fifo_distram_16x256b hmac_fifo 
    (
     .s_aclk(zm_clk),                      // input wire s_aclk
     .s_aresetn(~zm_reset),                // input wire s_aresetn
     .s_axis_tvalid(hmac_in_vld),          // input wire s_axis_tvalid
     .s_axis_tready(hmac_in_rdy),          // output wire s_axis_tready
     .s_axis_tdata(hmac_in_data),          // input wire [255 : 0] s_axis_tdata
     .m_axis_tvalid(hmac_out_vld),         // output wire m_axis_tvalid
     .m_axis_tready(hmac_out_rdy),         // input wire m_axis_tready
     .m_axis_tdata(hmac_out_text[257:2])   // output wire [255 : 0] m_axis_tdata
     );
  

  // ===========================================================================================================
  // hmac vs sig match logic
  // ===========================================================================================================
  // Asynchronous comparison. CTRLOUT will factor the comparison result against hdmi & sig validity.
  wire [21:0]  h_match;
  wire 	       hmac_match;
  reg 	       hmac_matchQ;

  // sig compare
  assign h_match[21] = (hmac_out_baseurl[343:336] == sig_out_baseurl[343:336] ? 1 : 0);
  assign h_match[20] = (hmac_out_baseurl[335:320] == sig_out_baseurl[335:320] ? 1 : 0);
  assign h_match[19] = (hmac_out_baseurl[319:304] == sig_out_baseurl[319:304] ? 1 : 0);
  assign h_match[18] = (hmac_out_baseurl[303:288] == sig_out_baseurl[303:288] ? 1 : 0);
  assign h_match[17] = (hmac_out_baseurl[287:272] == sig_out_baseurl[287:272] ? 1 : 0);
  assign h_match[16] = (hmac_out_baseurl[271:256] == sig_out_baseurl[271:256] ? 1 : 0);
  assign h_match[15] = (hmac_out_baseurl[255:240] == sig_out_baseurl[255:240] ? 1 : 0);
  assign h_match[14] = (hmac_out_baseurl[239:224] == sig_out_baseurl[239:224] ? 1 : 0);
  assign h_match[13] = (hmac_out_baseurl[223:208] == sig_out_baseurl[223:208] ? 1 : 0);
  assign h_match[12] = (hmac_out_baseurl[207:192] == sig_out_baseurl[207:192] ? 1 : 0);
  assign h_match[11] = (hmac_out_baseurl[191:176] == sig_out_baseurl[191:176] ? 1 : 0);
  assign h_match[10] = (hmac_out_baseurl[175:160] == sig_out_baseurl[175:160] ? 1 : 0);
  assign h_match[9]  = (hmac_out_baseurl[159:144] == sig_out_baseurl[159:144] ? 1 : 0);
  assign h_match[8]  = (hmac_out_baseurl[143:128] == sig_out_baseurl[143:128] ? 1 : 0);
  assign h_match[7]  = (hmac_out_baseurl[127:112] == sig_out_baseurl[127:112] ? 1 : 0);
  assign h_match[6]  = (hmac_out_baseurl[111:96]  == sig_out_baseurl[111:96]  ? 1 : 0);
  assign h_match[5]  = (hmac_out_baseurl[95:80]   == sig_out_baseurl[95:80]   ? 1 : 0);
  assign h_match[4]  = (hmac_out_baseurl[79:64]   == sig_out_baseurl[79:64]   ? 1 : 0);
  assign h_match[3]  = (hmac_out_baseurl[63:48]   == sig_out_baseurl[63:48]   ? 1 : 0);
  assign h_match[2]  = (hmac_out_baseurl[47:32]   == sig_out_baseurl[47:32]   ? 1 : 0);
  assign h_match[1]  = (hmac_out_baseurl[31:16]   == sig_out_baseurl[31:16]   ? 1 : 0);
  assign h_match[0]  = (hmac_out_baseurl[15:0]    == sig_out_baseurl[15:0]    ? 1 : 0);
  assign hmac_match = (h_match == 22'h3fffff ? 1 : 0);


  // ===========================================================================================================
  // ==> Moved to hmac_afu.v !!!
  //
  // K buffer: 32Kb array, 1 BRAM
  // Written via Axilite
  //    Write space: 1024 x 32b
  //    Read space: 512 x 64b
  // ===========================================================================================================
  //  wire kbuffer_wr;
  //  wire [9:0] kbuffer_wadrs;
  //  wire [31:0] kbuffer_din;
  //  wire [8:0]  kbuffer_radrs;
  //  wire [63:0] kbuffer_dout;
  //  wire [511:0] key;
  //
  //  assign key = {kbuffer_dout, 448'b0}; // The read key from keys_buffer, zero_padded to 512b. 
  //  
  //  // TBD: Add axi4lite write ifc
  //  assign kbuffer_wr = 1'b0; //TBD...
  //  assign kbuffer_wadrs = 10'b0; //TBD...
  //  assign kbuffer_din = 32'b0; //TBD...
  //  assign kbuffer_radrs = 9'b0; //TBD...
  //
  //  blk_mem_simpleDP_W1Kx32b_R512x64b keys_buffer 
  //    (
  //     .clka(zm_clk),    // input wire clka
  //     .ena(1'b1),      // input wire ena
  //     .wea(kbuffer_wr),      // input wire [0 : 0] wea
  //     .addra(kbuffer_wadrs),  // input wire [9 : 0] addra
  //     .dina(kbuffer_din),    // input wire [31 : 0] dina
  //     .clkb(zm_clk),    // input wire clkb
  //     .enb(1'b1),      // input wire enb
  //     .addrb(kbuffer_radrs),  // input wire [8 : 0] addrb
  //     .doutb(kbuffer_dout)  // output wire [63 : 0] doutb
  //     );
  
  
  // ===========================================================================================================
  // Packets forwarding fifo
  // 512x512b,
  // Packet fifo
  // No TUSER, no TKEEP
  // BRAM resouces: 1x18Kb, 7x36Kb    
  // ===========================================================================================================
  //
  // Per new packet, the first line writen to the packets fifo will be {TUSER[71:0], 440'b0}, followed by the rest of the packet.
  // This scheme increases number of fifo lines per packet, but it shouldn't be a problem, since the fifo is configured as 512x512b
  // (lowering to 256x512b do not save BRAMs), which can hold 20 max_length (1500B) packets.
  // Upon a packet forwarding, the packet length will be extracted from the saved TUSER[] (first packet flit),
  // with which to restore the proper TKEEP[].

  reg 	      pkts_fwd_in_vld;
  wire 	      pkts_fwd_in_rdy;
  reg [511:0] pkts_fwd_in_data;
  wire 	       pkts_fwd_in_last;
  wire 	       pkts_fwd_out_vld;
  reg 	       pkts_fwd_out_rdy;
  wire [511:0] pkts_fwd_out_data;
  wire 	       pkts_fwd_out_last;
  wire [9:0]   pkts_fwd_data_count;
  reg [15:0]   pkts_fwd_size;
  reg [63:0]   pkts_fwd_keep; // Generated locally, based on the received TUSER.total_length
  reg [71:0]   pkts_fwd_user; // Generated locally, based on the received TUSER
  reg 	       hmac_test_mode_last;
  
  assign    pkts_fwd_in_last = hmac_module_test_mode ? hmac_test_mode_last : zm_in_last;
  assign    zm_out_data = pkts_fwd_out_data;
  assign    zm_out_keep = pkts_fwd_keep;

  // modue test mode:
  // Each test_mode packet is a 10 flit packet, hosted in two (7 flits followed by 3 flits) successive packets in pkts_fwd fifo.
  // The first pkts_fwd_out_last in this pair of packets is ignored, such that a single, 10 flit packet is sent to zm_out_
  reg 	       pkts_fwd_out_second_last;
  wire 	       pkts_fwd_out_last_ok;
  assign    pkts_fwd_out_last_ok = hmac_module_test_mode ? pkts_fwd_out_last && pkts_fwd_out_second_last : pkts_fwd_out_last;
  assign    zm_out_last = pkts_fwd_out_last_ok;

  // pkts_fwd_in_data: Select the desired data to be written between normal_mode input and the various inputs during hmac_module_test_mode
  // In hmac_module_test mode, selecting the written data out of 10 various sources
  reg [3:0]    pkts_fwd_in_data_source;

  always @(*) begin
    if (hmac_module_test_mode)
      begin
	// TBD: add SM state to each ample
	// 3'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[4:0]
	
	case (pkts_fwd_in_data_source)
	  9:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   88'b0, 
				   sig_out_baseurl[343:0]};
	    end
	  
	  8:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0],                                                                                           // 48b
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0], // 32b
				   15'b0, hmac_match, 15'b0, hmac_matchQ,                                                                     // 32b
				   56'b0,                                                                                                     // 48b
				   hmac_out_baseurl[343:0]};                                                                                  // 344b
	                                                                                                                                      // Total: 
	    end
	  
	  7:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   176'b0, 
				   sha5_hout};
	    end
	  
	  6:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   176'b0, 
				   sha4_hout};
	    end
	  
	  5:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   176'b0, 
				   sha3_hout};
	    end
	  
	  4:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   176'b0, 
				   sha2_hout};
	    end
	  
	  3:
	    begin
	      pkts_fwd_in_data <= {timestamp[47:0], 
				   11'b0, hmacin_module_nstate[4:0], 3'b0, hmacin_module_return_state[4:0], 5'b0, hmacout_module_nstate[2:0],
				   176'b0, 
				   sha1_hout};
	    end
	  
	  2:
	    begin
	      pkts_fwd_in_data <= sha2_text;
	    end
	  
	  1:
	    begin
	      pkts_fwd_in_data <= sha1_text;
	    end
	  
	  0:
	    begin
	      pkts_fwd_in_data <= zm_in_data;
	    end
	  
	  default:
	    begin
	      pkts_fwd_in_data <= zm_in_data;
	    end
	endcase
      end
    else 
      pkts_fwd_in_data <= zm_in_data;
  end
  
  fifo_bram_512x512b pkts_fwd_fifo
    (
     .s_aclk(zm_clk),                    // input wire s_aclk
     .s_aresetn(~zm_reset),              // input wire s_aresetn
     .s_axis_tvalid(pkts_fwd_in_vld),      // input wire s_axis_tvalid
     .s_axis_tready(pkts_fwd_in_rdy),      // output wire s_axis_tready
     .s_axis_tdata(pkts_fwd_in_data),        // input wire [511 : 0] s_axis_tdata
     .s_axis_tlast(pkts_fwd_in_last),        // input wire s_axis_tlast
     .m_axis_tvalid(pkts_fwd_out_vld),      // output wire m_axis_tvalid
     .m_axis_tready(pkts_fwd_out_rdy),      // input wire m_axis_tready
     .m_axis_tdata(pkts_fwd_out_data),        // output wire [511 : 0] m_axis_tdata
     .m_axis_tlast(pkts_fwd_out_last),        // output wire m_axis_tlast
     .axis_data_count(pkts_fwd_data_count)  // output wire [9 : 0] axis_data_count
     );



  // hmac text to base64url:
  text2base64url sigtext2url_42(hmac_out_text[`U42], hmac_out_baseurl[`B42]);
  text2base64url sigtext2url_41(hmac_out_text[`U41], hmac_out_baseurl[`B41]);
  text2base64url sigtext2url_40(hmac_out_text[`U40], hmac_out_baseurl[`B40]);
  text2base64url sigtext2url_39(hmac_out_text[`U39], hmac_out_baseurl[`B39]);
  text2base64url sigtext2url_38(hmac_out_text[`U38], hmac_out_baseurl[`B38]);
  text2base64url sigtext2url_37(hmac_out_text[`U37], hmac_out_baseurl[`B37]);
  text2base64url sigtext2url_36(hmac_out_text[`U36], hmac_out_baseurl[`B36]);
  text2base64url sigtext2url_35(hmac_out_text[`U35], hmac_out_baseurl[`B35]);
  text2base64url sigtext2url_34(hmac_out_text[`U34], hmac_out_baseurl[`B34]);
  text2base64url sigtext2url_33(hmac_out_text[`U33], hmac_out_baseurl[`B33]);
  text2base64url sigtext2url_32(hmac_out_text[`U32], hmac_out_baseurl[`B32]);
  text2base64url sigtext2url_31(hmac_out_text[`U31], hmac_out_baseurl[`B31]);
  text2base64url sigtext2url_30(hmac_out_text[`U30], hmac_out_baseurl[`B30]);
  text2base64url sigtext2url_29(hmac_out_text[`U29], hmac_out_baseurl[`B29]);
  text2base64url sigtext2url_28(hmac_out_text[`U28], hmac_out_baseurl[`B28]);
  text2base64url sigtext2url_27(hmac_out_text[`U27], hmac_out_baseurl[`B27]);
  text2base64url sigtext2url_26(hmac_out_text[`U26], hmac_out_baseurl[`B26]);
  text2base64url sigtext2url_25(hmac_out_text[`U25], hmac_out_baseurl[`B25]);
  text2base64url sigtext2url_24(hmac_out_text[`U24], hmac_out_baseurl[`B24]);
  text2base64url sigtext2url_23(hmac_out_text[`U23], hmac_out_baseurl[`B23]);
  text2base64url sigtext2url_22(hmac_out_text[`U22], hmac_out_baseurl[`B22]);
  text2base64url sigtext2url_21(hmac_out_text[`U21], hmac_out_baseurl[`B21]);
  text2base64url sigtext2url_20(hmac_out_text[`U20], hmac_out_baseurl[`B20]);
  text2base64url sigtext2url_19(hmac_out_text[`U19], hmac_out_baseurl[`B19]);
  text2base64url sigtext2url_18(hmac_out_text[`U18], hmac_out_baseurl[`B18]);
  text2base64url sigtext2url_17(hmac_out_text[`U17], hmac_out_baseurl[`B17]);
  text2base64url sigtext2url_16(hmac_out_text[`U16], hmac_out_baseurl[`B16]);
  text2base64url sigtext2url_15(hmac_out_text[`U15], hmac_out_baseurl[`B15]);
  text2base64url sigtext2url_14(hmac_out_text[`U14], hmac_out_baseurl[`B14]);
  text2base64url sigtext2url_13(hmac_out_text[`U13], hmac_out_baseurl[`B13]);
  text2base64url sigtext2url_12(hmac_out_text[`U12], hmac_out_baseurl[`B12]);
  text2base64url sigtext2url_11(hmac_out_text[`U11], hmac_out_baseurl[`B11]);
  text2base64url sigtext2url_10(hmac_out_text[`U10], hmac_out_baseurl[`B10]);
  text2base64url  sigtext2url_9(hmac_out_text[`U9],  hmac_out_baseurl[`B9]);
  text2base64url  sigtext2url_8(hmac_out_text[`U8],  hmac_out_baseurl[`B8]);
  text2base64url  sigtext2url_7(hmac_out_text[`U7],  hmac_out_baseurl[`B7]);
  text2base64url  sigtext2url_6(hmac_out_text[`U6],  hmac_out_baseurl[`B6]);
  text2base64url  sigtext2url_5(hmac_out_text[`U5],  hmac_out_baseurl[`B5]);
  text2base64url  sigtext2url_4(hmac_out_text[`U4],  hmac_out_baseurl[`B4]);
  text2base64url  sigtext2url_3(hmac_out_text[`U3],  hmac_out_baseurl[`B3]);
  text2base64url  sigtext2url_2(hmac_out_text[`U2],  hmac_out_baseurl[`B2]);
  text2base64url  sigtext2url_1(hmac_out_text[`U1],  hmac_out_baseurl[`B1]);
  text2base64url  sigtext2url_0(hmac_out_text[`U0],  hmac_out_baseurl[`B0]);


/*
  // HEAD, 36 bytes decoding:
  base64url2text url2text_head35(head_baseurl[`B35], head_text[`U35]);
  base64url2text url2text_head34(head_baseurl[`B34], head_text[`U34]);
  base64url2text url2text_head33(head_baseurl[`B33], head_text[`U33]);
  base64url2text url2text_head32(head_baseurl[`B32], head_text[`U32]);
  base64url2text url2text_head31(head_baseurl[`B31], head_text[`U31]);
  base64url2text url2text_head30(head_baseurl[`B30], head_text[`U30]);
  base64url2text url2text_head29(head_baseurl[`B29], head_text[`U29]);
  base64url2text url2text_head28(head_baseurl[`B28], head_text[`U28]);
  base64url2text url2text_head27(head_baseurl[`B27], head_text[`U27]);
  base64url2text url2text_head26(head_baseurl[`B26], head_text[`U26]);
  base64url2text url2text_head25(head_baseurl[`B25], head_text[`U25]);
  base64url2text url2text_head24(head_baseurl[`B24], head_text[`U24]);
  base64url2text url2text_head23(head_baseurl[`B23], head_text[`U23]);
  base64url2text url2text_head22(head_baseurl[`B22], head_text[`U22]);
  base64url2text url2text_head21(head_baseurl[`B21], head_text[`U21]);
  base64url2text url2text_head20(head_baseurl[`B20], head_text[`U20]);
  base64url2text url2text_head19(head_baseurl[`B19], head_text[`U19]);
  base64url2text url2text_head18(head_baseurl[`B18], head_text[`U18]);
  base64url2text url2text_head17(head_baseurl[`B17], head_text[`U17]);
  base64url2text url2text_head16(head_baseurl[`B16], head_text[`U16]);
  base64url2text url2text_head15(head_baseurl[`B15], head_text[`U15]);
  base64url2text url2text_head14(head_baseurl[`B14], head_text[`U14]);
  base64url2text url2text_head13(head_baseurl[`B13], head_text[`U13]);
  base64url2text url2text_head12(head_baseurl[`B12], head_text[`U12]);
  base64url2text url2text_head11(head_baseurl[`B11], head_text[`U11]);
  base64url2text url2text_head10(head_baseurl[`B10], head_text[`U10]);
  base64url2text url2text_head9(head_baseurl[`B9], head_text[`U9]);
  base64url2text url2text_head8(head_baseurl[`B8], head_text[`U8]);
  base64url2text url2text_head7(head_baseurl[`B7], head_text[`U7]);
  base64url2text url2text_head6(head_baseurl[`B6], head_text[`U6]);
  base64url2text url2text_head5(head_baseurl[`B5], head_text[`U5]);
  base64url2text url2text_head4(head_baseurl[`B4], head_text[`U4]);
  base64url2text url2text_head3(head_baseurl[`B3], head_text[`U3]);
  base64url2text url2text_head2(head_baseurl[`B2], head_text[`U2]);
  base64url2text url2text_head1(head_baseurl[`B1], head_text[`U1]);
  base64url2text url2text_head0(head_baseurl[`B0], head_text[`U0]);
  
  // BODY, 44 bytes decoding:
  base64url2text url2text_body43(body_baseurl[`B43], body_text[`U43]);
  base64url2text url2text_body42(body_baseurl[`B42], body_text[`U42]);
  base64url2text url2text_body41(body_baseurl[`B41], body_text[`U41]);
  base64url2text url2text_body40(body_baseurl[`B40], body_text[`U40]);
  base64url2text url2text_body39(body_baseurl[`B39], body_text[`U39]);
  base64url2text url2text_body38(body_baseurl[`B38], body_text[`U38]);
  base64url2text url2text_body37(body_baseurl[`B37], body_text[`U37]);
  base64url2text url2text_body36(body_baseurl[`B36], body_text[`U36]);
  base64url2text url2text_body35(body_baseurl[`B35], body_text[`U35]);
  base64url2text url2text_body34(body_baseurl[`B34], body_text[`U34]);
  base64url2text url2text_body33(body_baseurl[`B33], body_text[`U33]);
  base64url2text url2text_body32(body_baseurl[`B32], body_text[`U32]);
  base64url2text url2text_body31(body_baseurl[`B31], body_text[`U31]);
  base64url2text url2text_body30(body_baseurl[`B30], body_text[`U30]);
  base64url2text url2text_body29(body_baseurl[`B29], body_text[`U29]);
  base64url2text url2text_body28(body_baseurl[`B28], body_text[`U28]);
  base64url2text url2text_body27(body_baseurl[`B27], body_text[`U27]);
  base64url2text url2text_body26(body_baseurl[`B26], body_text[`U26]);
  base64url2text url2text_body25(body_baseurl[`B25], body_text[`U25]);
  base64url2text url2text_body24(body_baseurl[`B24], body_text[`U24]);
  base64url2text url2text_body23(body_baseurl[`B23], body_text[`U23]);
  base64url2text url2text_body22(body_baseurl[`B22], body_text[`U22]);
  base64url2text url2text_body21(body_baseurl[`B21], body_text[`U21]);
  base64url2text url2text_body20(body_baseurl[`B20], body_text[`U20]);
  base64url2text url2text_body19(body_baseurl[`B19], body_text[`U19]);
  base64url2text url2text_body18(body_baseurl[`B18], body_text[`U18]);
  base64url2text url2text_body17(body_baseurl[`B17], body_text[`U17]);
  base64url2text url2text_body16(body_baseurl[`B16], body_text[`U16]);
  base64url2text url2text_body15(body_baseurl[`B15], body_text[`U15]);
  base64url2text url2text_body14(body_baseurl[`B14], body_text[`U14]);
  base64url2text url2text_body13(body_baseurl[`B13], body_text[`U13]);
  base64url2text url2text_body12(body_baseurl[`B12], body_text[`U12]);
  base64url2text url2text_body11(body_baseurl[`B11], body_text[`U11]);
  base64url2text url2text_body10(body_baseurl[`B10], body_text[`U10]);
  base64url2text url2text_body9(body_baseurl[`B9], body_text[`U9]);
  base64url2text url2text_body8(body_baseurl[`B8], body_text[`U8]);
  base64url2text url2text_body7(body_baseurl[`B7], body_text[`U7]);
  base64url2text url2text_body6(body_baseurl[`B6], body_text[`U6]);
  base64url2text url2text_body5(body_baseurl[`B5], body_text[`U5]);
  base64url2text url2text_body4(body_baseurl[`B4], body_text[`U4]);
  base64url2text url2text_body3(body_baseurl[`B3], body_text[`U3]);
  base64url2text url2text_body2(body_baseurl[`B2], body_text[`U2]);
  base64url2text url2text_body1(body_baseurl[`B1], body_text[`U1]);
  base64url2text url2text_body0(body_baseurl[`B0], body_text[`U0]);

  // SIG, 43 bytes decoding:
  base64url2text url2text_sig42(sig_baseurl[`B42], sig_text[`U42]);
  base64url2text url2text_sig41(sig_baseurl[`B41], sig_text[`U41]);
  base64url2text url2text_sig40(sig_baseurl[`B40], sig_text[`U40]);
  base64url2text url2text_sig39(sig_baseurl[`B39], sig_text[`U39]);
  base64url2text url2text_sig38(sig_baseurl[`B38], sig_text[`U38]);
  base64url2text url2text_sig37(sig_baseurl[`B37], sig_text[`U37]);
  base64url2text url2text_sig36(sig_baseurl[`B36], sig_text[`U36]);
  base64url2text url2text_sig35(sig_baseurl[`B35], sig_text[`U35]);
  base64url2text url2text_sig34(sig_baseurl[`B34], sig_text[`U34]);
  base64url2text url2text_sig33(sig_baseurl[`B33], sig_text[`U33]);
  base64url2text url2text_sig32(sig_baseurl[`B32], sig_text[`U32]);
  base64url2text url2text_sig31(sig_baseurl[`B31], sig_text[`U31]);
  base64url2text url2text_sig30(sig_baseurl[`B30], sig_text[`U30]);
  base64url2text url2text_sig29(sig_baseurl[`B29], sig_text[`U29]);
  base64url2text url2text_sig28(sig_baseurl[`B28], sig_text[`U28]);
  base64url2text url2text_sig27(sig_baseurl[`B27], sig_text[`U27]);
  base64url2text url2text_sig26(sig_baseurl[`B26], sig_text[`U26]);
  base64url2text url2text_sig25(sig_baseurl[`B25], sig_text[`U25]);
  base64url2text url2text_sig24(sig_baseurl[`B24], sig_text[`U24]);
  base64url2text url2text_sig23(sig_baseurl[`B23], sig_text[`U23]);
  base64url2text url2text_sig22(sig_baseurl[`B22], sig_text[`U22]);
  base64url2text url2text_sig21(sig_baseurl[`B21], sig_text[`U21]);
  base64url2text url2text_sig20(sig_baseurl[`B20], sig_text[`U20]);
  base64url2text url2text_sig19(sig_baseurl[`B19], sig_text[`U19]);
  base64url2text url2text_sig18(sig_baseurl[`B18], sig_text[`U18]);
  base64url2text url2text_sig17(sig_baseurl[`B17], sig_text[`U17]);
  base64url2text url2text_sig16(sig_baseurl[`B16], sig_text[`U16]);
  base64url2text url2text_sig15(sig_baseurl[`B15], sig_text[`U15]);
  base64url2text url2text_sig14(sig_baseurl[`B14], sig_text[`U14]);
  base64url2text url2text_sig13(sig_baseurl[`B13], sig_text[`U13]);
  base64url2text url2text_sig12(sig_baseurl[`B12], sig_text[`U12]);
  base64url2text url2text_sig11(sig_baseurl[`B11], sig_text[`U11]);
  base64url2text url2text_sig10(sig_baseurl[`B10], sig_text[`U10]);
  base64url2text url2text_sig9(sig_baseurl[`B9], sig_text[`U9]);
  base64url2text url2text_sig8(sig_baseurl[`B8], sig_text[`U8]);
  base64url2text url2text_sig7(sig_baseurl[`B7], sig_text[`U7]);
  base64url2text url2text_sig6(sig_baseurl[`B6], sig_text[`U6]);
  base64url2text url2text_sig5(sig_baseurl[`B5], sig_text[`U5]);
  base64url2text url2text_sig4(sig_baseurl[`B4], sig_text[`U4]);
  base64url2text url2text_sig3(sig_baseurl[`B3], sig_text[`U3]);
  base64url2text url2text_sig2(sig_baseurl[`B2], sig_text[`U2]);
  base64url2text url2text_sig1(sig_baseurl[`B1], sig_text[`U1]);
  base64url2text url2text_sig0(sig_baseurl[`B0], sig_text[`U0]);
*/


  
endmodule


// base64url encoder:
module text2base64url
  (
   input wire [5:0]  in,
   output wire [7:0] out 
   );
  
  reg [8:0] 	     baseurl;
  wire [8:0] 	     text;

  assign text = {3'b000, in};
  assign out = baseurl[7:0];
  
  always @(*) begin
    if (text <= 9'd25)
      // [A-Z]
      baseurl = text + 9'd65;
    
    else if (text >= 9'd26 && text <= 9'd51)
      // [a-z]
      baseurl = text - 9'd26 + 9'd97;
    
    else if (text >= 9'd52 && text <= 9'd61)
      // [0-9]
      baseurl = text - 9'd52 + 9'd48;
    
    else if (text == 9'd62)
      // [-]
      baseurl = 9'd45;

    else if (text == 9'd63)
      // [_]
      baseurl = 9'd95;
    
    else
      // Impossible case: return '0:
      baseurl = 9'b0;
  end
  
endmodule



// base64url decoder:
module base64url2text
  (
   input wire [7:0]  in,
   output wire [5:0] out 
   );
  
  wire [8:0] 	     baseurl;
  reg [8:0] 	     text;

  assign baseurl = {1'b0, in};
  assign out = text[5:0];
  
  always @(*) begin
    if (baseurl >= 9'd52 && baseurl <= 9'd61)
      // [0-9]
      text = baseurl - 9'd48 + 9'd52;
    
    else if (baseurl >= 9'd65 && baseurl <= 9'd90)
      // [A-Z]
      text = baseurl - 9'd65;
    
    else if (baseurl >= 9'd97 && baseurl <= 9'd122)
      // [a-z])
      text = baseurl - 9'd97 + 9'd26;
    
    else if (baseurl == 9'd45)
      // [-]
      text = 9'd62;

    else if (baseurl == 9'd95)
      // [_]
      text = 9'd63;
    
    else
      // Impossible case: return '0:
      text = 9'b0;
  end
  
endmodule



