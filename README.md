# FlexDriver IoT authentication offload example AFU

This repository contains an example AFU for FlexDriver, demonstrated in the paper *FlexDriver: A Network Driver for Your Accelerator*.
The example accelerator receives CoAP packets, extracts a JSON web token (JWT), and validates the token using SHA-256.

## Build instructions

To build, you will need to acquire FlexDriver IP (`src/flc.dcp`) from NVIDIA
Networking, and use Xilinx Vivado 2019.2 to build.

    vivado -source run_project.tcl

## References

 * [JSON Web Signature (JWS) (RFC 7515)](https://www.rfc-editor.org/rfc/rfc7515.html)
 * [JSON Web Token (RFC 7519)](https://datatracker.ietf.org/doc/html/rfc7519)
 * [Contrainted Application Protocol (CoAP)](https://en.wikipedia.org/wiki/Constrained_Application_Protocol)
 * [NICA](https://github.com/acsl-technion/nica) includes a [similar offload](https://github.com/acsl-technion/nica/blob/master/ikernels/hls/coap.cpp).
