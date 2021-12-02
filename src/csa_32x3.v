/*
 * Copyright (c) 2021 Gabi Malka.
 * Licensed under the 2-clause BSD license, see LICENSE for details.
 * SPDX-License-Identifier: BSD-2-Clause
 */
module csa_32x3(
                input wire [31:0]  in1,
                input wire [31:0]  in2,
                input wire [31:0]  in3,
                output wire [31:0] sum,
                output wire [31:0] carry
                );

  assign sum = in1 ^ in2 ^ in3;
  assign carry = in1 & in2 | in1 & in3 | in2 & in3;

endmodule // csa_32x3
  
