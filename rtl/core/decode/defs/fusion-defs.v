`ifndef OPENRV64_DECODE_FUSION_DEFS_V
`define OPENRV64_DECODE_FUSION_DEFS_V

// Decode-side macro-fusion roles.  These describe microarchitectural
// opportunities, not architectural instruction encodings.
`define OPENRV64_FUSION_CANDIDATE_WIDTH 2
`define OPENRV64_FUSION_CANDIDATE_NONE 2'd0
`define OPENRV64_FUSION_CANDIDATE_PCREL_CALL 2'd1
`define OPENRV64_FUSION_CANDIDATE_LI_BRANCH 2'd2

`define OPENRV64_FUSION_OP_WIDTH 2
`define OPENRV64_FUSION_OP_NONE 2'd0
`define OPENRV64_FUSION_OP_PCREL_CALL 2'd1
`define OPENRV64_FUSION_OP_LI_BRANCH 2'd2

`endif
