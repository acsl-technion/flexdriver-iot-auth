/*
 * Copyright (c) 2021 Gabi Malka.
 * Licensed under the 2-clause BSD license, see LICENSE for details.
 * SPDX-License-Identifier: BSD-2-Clause
 */

`define TWO_SLICES
// AXI4LITE_EN is used in zuc_top.v (image build top)
`define AXI4LITE_EN

// Select which sample buffer to deploy.
// Keep in mind that each buffer consumes 115 x 36Kb_BRAMs
//`define FLD_PCI2SBU_SAMPLE_EN
//`define AFU_PCI2SBU_SAMPLE_EN
//`define INPUT_BUFFER_SAMPLE_EN
//`define MODULE_IN_SAMPLE_EN
//`define AFU_SBU2PCI_SAMPLE_EN
//`define FLD_SBU2PCI_SAMPLE_EN

localparam
  BUFFER_RAM_SIZE           = 8*1024,    // Total input RAM size: 8K lines x 512b/line
  NUM_CHANNELS              = 16,      // Number of implemented channels
  MAX_PACKET_SIZE           = 1024,    // Max packet size transfer on sbu2pci port. Default to 1KB.
  CHANNEL_BUFFER_SIZE       = BUFFER_RAM_SIZE/NUM_CHANNELS, // Total number of 512b lines per channel 
  CHANNEL_BUFFER_SIZE_WATERMARK = 4,  // Minimum number of free 512b lines before 'full' indication 
  CHANNEL_BUFFER_MAX_CAPACITY = CHANNEL_BUFFER_SIZE - CHANNEL_BUFFER_SIZE_WATERMARK,  // Maximum allowd capacity, considering the WATERMARK
  FULL_LINE_KEEP            = 64'hffffffffffffffff,
  MAC_RESPONSE_KEEP         = 64'hffffffffffff0000, // tdata[127:0] should be masked !!
  FIFO_LINE_SIZE            = 64,      // # of bytes per input buffer/fifo_in/fifo_out line 
  MODULE_FIFO_IN_SIZE       = 16'd514, // # Max utilized entries num in fifox_in (actual max size is 515)
  MODULE_FIFO_OUT_SIZE      = 16'd514, // # Max utilized entries num in fifox_out (actual max size is 515)
  ZUC_AFU_FREQ              = 12'h0c8, // == 'd200. Default zuc clock frequency (Mhz). Can be reconfigured in zuc_ctrlTBD
  MESSAGES_HIGH_WATERMARK   = 15,
  MESSAGES_LOW_WATERMARK    = 3,       // Minimum number_of_messages in input queue0/queue1 before serving the queue

  // Used for modules utilization & tpt calc.
  OPAD                      = 512'h5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c,
  IPAD                      = 512'h36363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636363636;

localparam
  // sha256 test vectors:
  // TEST_VECTOR1 = "abc"
  TEST_VECTOR1 = 512'h61626380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000018,

  // TEST_VECTOR2 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  TEST_VECTOR2_BLOCK1 = 512'h6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f70718000000000000000,
  TEST_VECTOR2_BLOCK2 = 512'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c0;


// 512b sampling buffers:
localparam
  SAMPLE_FIFO_SIZE       = 8*1024,
  //  SAMPLE_FIFO_SIZE       = 'd16, // Testing: Experimening with a smaller fifo
  SAMPLE_FIFO_WATERMARK  = SAMPLE_FIFO_SIZE - 'd8;



localparam
  MAX_NUMBER_OF_MODULES     = 'd8,    // Max number of modules
  NUMBER_OF_MODULES         = 'd8;    // Number of deployed modules: between 1 thru MAX_NUMBER_OF_MODULES. Higher values are forced to MAX_NUMBER_OF_MODULES.

localparam [7:0]
  // All opcodes > 3 are treated as illegal opcodes, and the associated message is bypassed (from input_buffer to sbu2pci)
  MESSAGE_CMD_CONF          = 8'h00,
  MESSAGE_CMD_INTEG         = 8'h01,
  MESSAGE_CMD_AFUBYPASS     = 8'h02,
  MESSAGE_CMD_MODULEBYPASS  = 8'h03,
  MESSAGE_CMD_NOP           = 8'h04;

//Ethernet/ip/udp headers fields
`define ETH_DST       511:464     // 6 bytes
`define ETH_SRC       463:416     // 6 bytes
`define ETH_TYPE      415:400     // 2 bytes
`define IP_VERSION    399:384     // 2 bytes
`define IP_LEN        383:368     // 2 bytes
`define IP_FLAGS      367:320     // 6 bytes  
`define IP_CHKSM      319:304     // 2 bytes  
`define IP_DST        303:272     // 4 bytes
`define IP_SRC        271:240     // 4 bytes
`define UDP_DST       239:224     // 2 bytes
`define UDP_SRC       223:208     // 2 bytes
`define UDP_LEN       207:192     // 2 bytes
`define UDP_CHKSM     191:176     // 2 bytes
`define HEADER_TAIL   175:60
`define HEADER_METADATA 59:0

// AFU/Modules bypass mode:
localparam [1:0]
  FORCE_CORE_BYPASS     = 2'b01,
  FORCE_AFU_BYPASS      = 2'b10,
  FORCE_MODULE_BYPASS   = 2'b11;

// Packets payload size buckets:
localparam
  SIZE_BUCKET0  = 'd0,      // payload size == 0 (i.e: Integrity response is header_only)
  SIZE_BUCKET1  = 'd64,     // payload size <= 64
  SIZE_BUCKET2  = 'd128,    // payload size <= 128
  SIZE_BUCKET3  = 'd256,    // payload size <= 256
  SIZE_BUCKET4  = 'd512,    // payload size <= 512
  SIZE_BUCKET5  = 'd1024,   // payload size <= 1024
  SIZE_BUCKET6  = 'd2048,   // payload size <= 2048
  SIZE_BUCKET7  = 'd4096,   // payload size <= 4096
  SIZE_BUCKET8  = 'd8192,   // payload size <= 8192
  SIZE_BUCKET9  = 'd9216,   // payload size <= 9216
  SIZE_BUCKET10 = 'd9216;   // payload size >  9216

localparam [2:0]
  // histogram arrays
  HIST_ARRAY_PCI2SBU_PACKETS     = 3'b000,
  HIST_ARRAY_PCI2SBU_EOMPACKETS  = 3'b001,
  HIST_ARRAY_PCI2SBU_MESSAGES    = 3'b010,
  HIST_ARRAY_SBU2PCI_RESPONSES   = 3'b011;

localparam [1:0]
  // histogram clear operations
  HIST_OP_CLEAR_NOP           = 2'b00,
  HIST_OP_CLEAR_CHID          = 2'b01,
  HIST_OP_CLEAR_ARRAY         = 2'b10,
  HIST_OP_CLEAR_ALL           = 2'b11;

localparam [3:0]
  // Received queues selection
  QUEUE0                      = 4'b0000,
  QUEUE1                      = 4'b0001,
  QUEUE2                      = 4'b0010,
  QUEUE3                      = 4'b0011;

localparam [19:0]
  // axi4stream samplers read_address base
  FLD_CLK_PCI2SBU             = 20'h10000,
  FLD_CLK_SBU2PCI             = 20'h10100,
  AFU_CLK_PCI2SBU             = 20'h08000,
  AFU_CLK_SBU2PCI             = 20'h08100,
  AFU_CLK_MODULE_IN           = 20'h08200,
  AFU_CLK_INPUT_BUFFER        = 20'h08300;

localparam [7:0]
  // Soft reset duration, in zuc_clk ticks
  AFU_SOFT_RESET_WIDTH        = 8'h30,
  PCI_SAMPLE_SOFT_RESET_WIDTH = 8'h20;

localparam
  AXILITE_TIMEOUT = 8'd64;     // Max axilite read/write response latency. After which the axilite_timeout_slave will respond


// Bytes position
`define B47           383:376
`define B46           375:368
`define B45           367:360
`define B44           359:352
`define B43           351:344
`define B42           343:336
`define B41           335:328
`define B40           327:320
`define B39           319:312
`define B38           311:304
`define B37           303:296
`define B36           295:288
`define B35           287:280
`define B34           279:272
`define B33           271:264
`define B32           263:256
`define B31           255:248
`define B30           247:240
`define B29           239:232
`define B28           231:224
`define B27           223:216
`define B26           215:208
`define B25           207:200
`define B24           199:192
`define B23           191:184
`define B22           183:176
`define B21           175:168
`define B20           167:160
`define B19           159:152
`define B18           151:144
`define B17           143:136
`define B16           135:128
`define B15           127:120
`define B14           119:112
`define B13           111:104
`define B12           103:96
`define B11            95:88
`define B10            87:80
`define B9             79:72
`define B8             71:64
`define B7             63:56
`define B6             55:48
`define B5             47:40
`define B4             39:32
`define B3             31:24
`define B2             23:16
`define B1             15:8
`define B0              7:0

// BASE64U bit position
`define U46         281:276
`define U45         275:270
`define U44         269:264
`define U43         263:258
`define U42         257:252
`define U41         251:246
`define U40         245:240
`define U39         239:234
`define U38         233:228
`define U37         227:222
`define U36         221:216
`define U35         215:210
`define U34         209:204
`define U33         203:198
`define U32         197:192
`define U31         191:186
`define U30         185:180
`define U29         179:174
`define U28         173:168
`define U27         167:162
`define U26         161:156
`define U25         155:150
`define U24         149:144
`define U23         143:138
`define U22         137:132
`define U21         131:126
`define U20         125:120
`define U19         119:114
`define U18         113:108
`define U17         107:102
`define U16         101:96
`define U15          95:90
`define U14          89:84
`define U13          83:78
`define U12          77:72
`define U11          71:66
`define U10          65:60
`define U9           59:54
`define U8           53:48
`define U7           47:42
`define U6           41:36
`define U5           35:30
`define U4           29:24
`define U3           23:18
`define U2           17:12
`define U1           11:6
`define U0            5:0
