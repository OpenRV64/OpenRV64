`ifndef OPENRV64_TOMASULO_TRACE_DEFS_V
`define OPENRV64_TOMASULO_TRACE_DEFS_V

// Stable numeric ABI for the simulation-only Tomasulo resident-state trace.
// Codes are shared by RTL probes, the SoC testbench writer, and Python tools.

// Components.  An instruction can occupy ROB and one of SCHED/REGREAD/EXEC/
// LSQ at the same time; these are component-residency records, not mutually
// exclusive textbook pipeline stages.
`define OPENRV64_TTRACE_STAGE_FETCH       8'd1
`define OPENRV64_TTRACE_STAGE_DECODE      8'd2
`define OPENRV64_TTRACE_STAGE_SCHED       8'd3
`define OPENRV64_TTRACE_STAGE_REGREAD     8'd4
`define OPENRV64_TTRACE_STAGE_EXEC        8'd5
`define OPENRV64_TTRACE_STAGE_COMPLETE    8'd6
`define OPENRV64_TTRACE_STAGE_LSQ         8'd7
`define OPENRV64_TTRACE_STAGE_ROB         8'd8
`define OPENRV64_TTRACE_STAGE_RETIRE      8'd9
`define OPENRV64_TTRACE_STAGE_DISPATCH    8'd10

// Component-local state.
`define OPENRV64_TTRACE_STATE_PRESENT     8'd1
`define OPENRV64_TTRACE_STATE_WAIT        8'd2
`define OPENRV64_TTRACE_STATE_READY       8'd3
`define OPENRV64_TTRACE_STATE_FIRE        8'd4
`define OPENRV64_TTRACE_STATE_PENDING     8'd5
`define OPENRV64_TTRACE_STATE_ACTIVE      8'd6
`define OPENRV64_TTRACE_STATE_WORKER      8'd7
`define OPENRV64_TTRACE_STATE_LOAD        8'd8
`define OPENRV64_TTRACE_STATE_STORE       8'd9
`define OPENRV64_TTRACE_STATE_INCOMPLETE  8'd10
`define OPENRV64_TTRACE_STATE_COMPLETE    8'd11
`define OPENRV64_TTRACE_STATE_HEAD        8'd12

// Exclusive primary reason.  Flags in each record preserve component-local
// secondary conditions; the primary code says why this record does not make
// its next normal transition in the sampled cycle.
`define OPENRV64_TTRACE_REASON_NONE                   8'd0
`define OPENRV64_TTRACE_REASON_SRC1_PENDING           8'd1
`define OPENRV64_TTRACE_REASON_SRC2_PENDING           8'd2
`define OPENRV64_TTRACE_REASON_BOTH_SOURCES_PENDING   8'd3
`define OPENRV64_TTRACE_REASON_OLDER_HARD             8'd4
`define OPENRV64_TTRACE_REASON_PERSISTENT_BARRIER     8'd5
`define OPENRV64_TTRACE_REASON_RETIRE_HEAD_REQUIRED   8'd6
`define OPENRV64_TTRACE_REASON_OLDER_MEMORY           8'd7
`define OPENRV64_TTRACE_REASON_OLDER_CONTROL          8'd8
`define OPENRV64_TTRACE_REASON_BRANCH_ORDER           8'd9
`define OPENRV64_TTRACE_REASON_PIPE_CONFLICT          8'd10
`define OPENRV64_TTRACE_REASON_ISSUE_WIDTH            8'd11
`define OPENRV64_TTRACE_REASON_PIPE_BUSY              8'd12
`define OPENRV64_TTRACE_REASON_REGREAD_PORT           8'd13
`define OPENRV64_TTRACE_REASON_REGREAD_BUFFER         8'd14
`define OPENRV64_TTRACE_REASON_EXEC_WORKER             8'd15
`define OPENRV64_TTRACE_REASON_COMPLETION_BACKPRESSURE 8'd16
`define OPENRV64_TTRACE_REASON_XLATE_ARBITRATION      8'd17
`define OPENRV64_TTRACE_REASON_XLATE_RESPONSE         8'd18
`define OPENRV64_TTRACE_REASON_STORE_GUARD            8'd19
`define OPENRV64_TTRACE_REASON_MEMORY_ORDER           8'd20
`define OPENRV64_TTRACE_REASON_MEMORY_PORT            8'd21
`define OPENRV64_TTRACE_REASON_MEMORY_RESPONSE        8'd22
`define OPENRV64_TTRACE_REASON_POSTED_STORE_ACK       8'd23
`define OPENRV64_TTRACE_REASON_ROB_INCOMPLETE         8'd24
`define OPENRV64_TTRACE_REASON_ROB_ORDER              8'd25
`define OPENRV64_TTRACE_REASON_RETIRE_BACKPRESSURE    8'd26
`define OPENRV64_TTRACE_REASON_REDIRECT_SQUASH        8'd27
`define OPENRV64_TTRACE_REASON_FRONTEND_CONTROL       8'd28
`define OPENRV64_TTRACE_REASON_BP_STALL               8'd29
`define OPENRV64_TTRACE_REASON_TRANSLATION_BARRIER    8'd30
`define OPENRV64_TTRACE_REASON_RENAME_TAG             8'd31
`define OPENRV64_TTRACE_REASON_ROB_CAPACITY           8'd32
`define OPENRV64_TTRACE_REASON_SCHED_CAPACITY         8'd33
`define OPENRV64_TTRACE_REASON_DECODE_DOWNSTREAM      8'd34
`define OPENRV64_TTRACE_REASON_HALT_OR_WFI             8'd35
`define OPENRV64_TTRACE_REASON_RESULT_ARBITRATION      8'd36
`define OPENRV64_TTRACE_REASON_ATOMIC_UNIT             8'd37
`define OPENRV64_TTRACE_REASON_BP_LOOKUP               8'd38
`define OPENRV64_TTRACE_REASON_BP_CAPACITY             8'd39
`define OPENRV64_TTRACE_REASON_BP_TARGET               8'd40
`define OPENRV64_TTRACE_REASON_LOAD_CONFLICT_RECORD    8'd41
`define OPENRV64_TTRACE_REASON_UNKNOWN                 8'd255

// Physical execution pipe.  NONE is used for records which are not assigned
// to a pipe; values 0..3 match EX0, EX1, MEM0, and MEM1 in backend_3p.
`define OPENRV64_TTRACE_PIPE_NONE 8'hff

`endif
