`ifndef OPENRV64_CMU_DEFS_V
`define OPENRV64_CMU_DEFS_V

// OpenRV64 platform-defined mhpmevent encoding.
//
// The RISC-V privileged architecture defines the counter and selector CSRs,
// but deliberately leaves event encodings to the platform.  OpenRV64 uses the
// low 38 bits of mhpmeventN as an event mask.  A counter increments once for
// each selected event pulse in a cycle, so selecting all issue or retirement
// lane events counts instructions rather than merely active cycles.
`define OPENRV64_CMU_EVENT_COUNT 38

`define OPENRV64_CMU_EVENT_CYCLE                    0
`define OPENRV64_CMU_EVENT_ISSUE_LANE0              1
`define OPENRV64_CMU_EVENT_ISSUE_LANE1              2
`define OPENRV64_CMU_EVENT_ISSUE_LANE2              3
`define OPENRV64_CMU_EVENT_RETIRE_LANE0             4
`define OPENRV64_CMU_EVENT_RETIRE_LANE1             5
`define OPENRV64_CMU_EVENT_RETIRE_LANE2             6
`define OPENRV64_CMU_EVENT_ZERO_ISSUE                7
`define OPENRV64_CMU_EVENT_ZERO_RETIRE               8
`define OPENRV64_CMU_EVENT_FRONTEND_EMPTY            9
`define OPENRV64_CMU_EVENT_DISPATCH_EMPTY           10
`define OPENRV64_CMU_EVENT_RAW_STALL                11
`define OPENRV64_CMU_EVENT_BARRIER_STALL            12
`define OPENRV64_CMU_EVENT_PIPE_BUSY_STALL          13
`define OPENRV64_CMU_EVENT_REDIRECT                 14
`define OPENRV64_CMU_EVENT_REDIRECT_RECOVERY        15
`define OPENRV64_CMU_EVENT_DIRECTION_MISPREDICT     16
`define OPENRV64_CMU_EVENT_TARGET_MISPREDICT        17
`define OPENRV64_CMU_EVENT_FETCH_REQUEST            18
`define OPENRV64_CMU_EVENT_FETCH_RESPONSE           19
`define OPENRV64_CMU_EVENT_FETCH_CANCEL             20
`define OPENRV64_CMU_EVENT_LSU_REQUEST              21
`define OPENRV64_CMU_EVENT_LSU_RESPONSE             22
`define OPENRV64_CMU_EVENT_LSU_REQUEST_WAIT         23
`define OPENRV64_CMU_EVENT_LSU_OUTSTANDING          24
`define OPENRV64_CMU_EVENT_L1I_DEMAND_HIT           25
`define OPENRV64_CMU_EVENT_L1I_DEMAND_MISS          26
`define OPENRV64_CMU_EVENT_L1I_PREFETCH_LAUNCH      27
`define OPENRV64_CMU_EVENT_L1I_PREFETCH_USEFUL      28
`define OPENRV64_CMU_EVENT_L1I_DEMAND_WAIT_PREFETCH 29
`define OPENRV64_CMU_EVENT_L1D_LOAD_HIT             30
`define OPENRV64_CMU_EVENT_L1D_LOAD_MISS            31
`define OPENRV64_CMU_EVENT_STORE_REQUEST            32
`define OPENRV64_CMU_EVENT_L1D_STORE \
    `OPENRV64_CMU_EVENT_STORE_REQUEST
`define OPENRV64_CMU_EVENT_RETIRE_HEAD_INCOMPLETE   33
`define OPENRV64_CMU_EVENT_COMPLETED_BEHIND_HEAD    34
`define OPENRV64_CMU_EVENT_LOST_ISSUE_SLOT0         35
`define OPENRV64_CMU_EVENT_LOST_ISSUE_SLOT1         36
`define OPENRV64_CMU_EVENT_LOST_ISSUE_SLOT2         37

`endif
