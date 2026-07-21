`timescale 1ns/1ps

// Shared vector-side read cache. This block sits below address translation and
// above the exclusive vector memory stream. Multiple VLSUs present ordinary
// tagged beats; read misses allocate complete cache lines and hold the
// requesting VLSU until the line is present. Stores bypass the data array and
// invalidate a matching line.
//
// Prefetch commands are descriptors, not fences. One accepted command walks
// COUNT cache lines in the background. A streaming line becomes the preferred
// victim in its set only after its final CLIENT_DATA_WIDTH word has been read.
// then it participates in normal replacement aging.
module openrv64_vec_sram_cache #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer CLIENT_DATA_WIDTH = 256,
    parameter integer MEM_DATA_WIDTH = 64,
    parameter integer CLIENTS = 2,
    parameter integer CLIENT_TAG_WIDTH = 7,
    parameter integer MEM_TAG_WIDTH = 8,
    parameter integer CACHE_BYTES = 256 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 4,
    parameter integer MSHRS = 8,
    parameter integer MEM_MAX_BURST_REQUESTS = 1
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire [CLIENTS-1:0]                client_req_valid_i,
    output reg  [CLIENTS-1:0]                client_req_ready_o,
    input  wire [CLIENTS*CLIENT_TAG_WIDTH-1:0] client_req_tag_i,
    input  wire [CLIENTS-1:0]                client_req_write_i,
    input  wire [CLIENTS*ADDR_WIDTH-1:0]      client_req_addr_i,
    input  wire [CLIENTS*CLIENT_DATA_WIDTH-1:0] client_req_wdata_i,
    input  wire [CLIENTS*(CLIENT_DATA_WIDTH/8)-1:0] client_req_wstrb_i,

    output wire [CLIENTS-1:0]                client_resp_valid_o,
    input  wire [CLIENTS-1:0]                client_resp_ready_i,
    output wire [CLIENTS*CLIENT_TAG_WIDTH-1:0] client_resp_tag_o,
    output wire [CLIENTS*CLIENT_DATA_WIDTH-1:0] client_resp_rdata_o,
    output wire [CLIENTS-1:0]                client_resp_error_o,
    output wire [CLIENTS-1:0]                client_resp_retry_o,

    input  wire                              prefetch_valid_i,
    output wire                              prefetch_ready_o,
    input  wire [ADDR_WIDTH-1:0]             prefetch_addr_i,
    input  wire [3:0]                        prefetch_count_i,
    input  wire                              prefetch_streaming_i,
    output wire                              prefetch_busy_o,

    output wire                              mem_req_valid_o,
    input  wire                              mem_req_ready_i,
    output wire [MEM_TAG_WIDTH-1:0]          mem_req_tag_o,
    output wire                              mem_req_write_o,
    output wire [7:0]                        mem_req_burst_o,
    output wire [ADDR_WIDTH-1:0]             mem_req_addr_o,
    output wire [MEM_DATA_WIDTH-1:0]         mem_req_wdata_o,
    output wire [(MEM_DATA_WIDTH/8)-1:0]     mem_req_wstrb_o,

    input  wire                              mem_resp_valid_i,
    output wire                              mem_resp_ready_o,
    input  wire [MEM_TAG_WIDTH-1:0]          mem_resp_tag_i,
    input  wire [MEM_DATA_WIDTH-1:0]         mem_resp_rdata_i,
    input  wire                              mem_resp_error_i,
    input  wire                              mem_resp_retry_i,

    output wire                              replay_o,
    output wire                              busy_o
);

    localparam integer CLIENT_BYTES = CLIENT_DATA_WIDTH / 8;
    localparam integer MEM_BYTES = MEM_DATA_WIDTH / 8;
    localparam integer ARRAY_DATA_WIDTH =
        (CLIENT_DATA_WIDTH >= MEM_DATA_WIDTH) ?
        CLIENT_DATA_WIDTH : MEM_DATA_WIDTH;
    localparam integer ARRAY_BYTES = ARRAY_DATA_WIDTH / 8;
    localparam integer CLIENT_WORDS_PER_LINE = LINE_BYTES / CLIENT_BYTES;
    localparam integer ARRAY_WORDS_PER_LINE = LINE_BYTES / ARRAY_BYTES;
    localparam integer FILL_BEATS_PER_LINE = LINE_BYTES / MEM_BYTES;
    localparam integer STORE_BEATS_PER_CLIENT =
        (CLIENT_BYTES >= MEM_BYTES) ? (CLIENT_BYTES / MEM_BYTES) : 1;
    localparam integer LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer SETS = LINES / WAYS;
    localparam integer LINE_OFFSET_WIDTH =
        (LINE_BYTES <= 1) ? 1 : $clog2(LINE_BYTES);
    localparam integer WORD_INDEX_WIDTH =
        (CLIENT_WORDS_PER_LINE <= 1) ? 1 :
        $clog2(CLIENT_WORDS_PER_LINE);
    localparam integer FILL_INDEX_WIDTH =
        (FILL_BEATS_PER_LINE <= 1) ? 1 : $clog2(FILL_BEATS_PER_LINE);
    localparam integer SET_INDEX_WIDTH =
        (SETS <= 1) ? 1 : $clog2(SETS);
    localparam integer WAY_INDEX_WIDTH =
        (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer MSHR_INDEX_WIDTH =
        (MSHRS <= 1) ? 1 : $clog2(MSHRS);
    localparam integer CLIENT_INDEX_WIDTH =
        (CLIENTS <= 1) ? 1 : $clog2(CLIENTS);
    localparam integer AGE_WIDTH =
        (WAYS <= 1) ? 1 : $clog2(WAYS);
    localparam integer TAG_BITS =
        ADDR_WIDTH - LINE_OFFSET_WIDTH - SET_INDEX_WIDTH;
    localparam integer TOTAL_WORDS = LINES * ARRAY_WORDS_PER_LINE;

    function automatic [ADDR_WIDTH-1:0] line_address;
        input [ADDR_WIDTH-1:0] address;
        begin
            line_address = (address >> LINE_OFFSET_WIDTH) <<
                           LINE_OFFSET_WIDTH;
        end
    endfunction

    function automatic [SET_INDEX_WIDTH-1:0] address_set;
        input [ADDR_WIDTH-1:0] address;
        begin
            address_set = (address >> LINE_OFFSET_WIDTH) & (SETS - 1);
        end
    endfunction

    function automatic [TAG_BITS-1:0] address_tag;
        input [ADDR_WIDTH-1:0] address;
        begin
            address_tag = address >>
                          (LINE_OFFSET_WIDTH + SET_INDEX_WIDTH);
        end
    endfunction

    function automatic [WORD_INDEX_WIDTH-1:0] address_word;
        input [ADDR_WIDTH-1:0] address;
        begin
            address_word = (address >> $clog2(CLIENT_BYTES)) &
                           (CLIENT_WORDS_PER_LINE - 1);
        end
    endfunction

    function automatic integer address_array_word;
        input [ADDR_WIDTH-1:0] address;
        begin
            address_array_word =
                (address >> $clog2(ARRAY_BYTES)) &
                (ARRAY_WORDS_PER_LINE - 1);
        end
    endfunction

    function automatic integer address_client_lane;
        input [ADDR_WIDTH-1:0] address;
        begin
            address_client_lane =
                (address & (ARRAY_BYTES - 1)) / CLIENT_BYTES;
        end
    endfunction

    function automatic integer line_index;
        input integer set_index;
        input integer way_index;
        begin
            line_index = set_index * WAYS + way_index;
        end
    endfunction

    function automatic integer data_index;
        input integer set_index;
        input integer way_index;
        input integer word_index;
        begin
            data_index = (set_index * WAYS + way_index) *
                         ARRAY_WORDS_PER_LINE + word_index;
        end
    endfunction

    // The data array is deliberately flat and has no reset so synthesis can
    // map it to SRAM macros. Metadata reset controls whether any word is read.
    reg [ARRAY_DATA_WIDTH-1:0] data_q [0:TOTAL_WORDS-1];
    reg [TAG_BITS-1:0] tag_q [0:LINES-1];
    reg valid_q [0:LINES-1];
    reg streaming_q [0:LINES-1];
    reg discard_next_q [0:LINES-1];
    reg [AGE_WIDTH-1:0] age_q [0:LINES-1];

    reg [CLIENTS-1:0] client_resp_valid_q;
    reg [CLIENT_TAG_WIDTH-1:0] client_resp_tag_q [0:CLIENTS-1];
    reg [CLIENT_DATA_WIDTH-1:0] client_resp_rdata_q [0:CLIENTS-1];
    reg client_resp_error_q [0:CLIENTS-1];

    genvar output_client;
    generate
        for (output_client = 0; output_client < CLIENTS;
             output_client = output_client + 1) begin : g_client_outputs
            assign client_resp_tag_o[
                output_client*CLIENT_TAG_WIDTH +: CLIENT_TAG_WIDTH] =
                client_resp_tag_q[output_client];
            assign client_resp_rdata_o[
                output_client*CLIENT_DATA_WIDTH +: CLIENT_DATA_WIDTH] =
                client_resp_rdata_q[output_client];
            assign client_resp_error_o[output_client] =
                client_resp_error_q[output_client];
            assign client_resp_retry_o[output_client] = 1'b0;
        end
    endgenerate
    assign client_resp_valid_o = client_resp_valid_q;

    // A fill MSHR owns one external beat at a time. Tags still allow several
    // independent lines (and stores) to wait on the external fabric together.
    reg mshr_valid_q [0:MSHRS-1];
    reg mshr_store_q [0:MSHRS-1];
    reg mshr_prefetch_q [0:MSHRS-1];
    reg mshr_streaming_q [0:MSHRS-1];
    reg mshr_wait_q [0:MSHRS-1];
    reg mshr_done_q [0:MSHRS-1];
    reg mshr_error_q [0:MSHRS-1];
    reg [ADDR_WIDTH-1:0] mshr_line_addr_q [0:MSHRS-1];
    reg [SET_INDEX_WIDTH-1:0] mshr_set_q [0:MSHRS-1];
    reg [WAY_INDEX_WIDTH-1:0] mshr_way_q [0:MSHRS-1];
    reg [WORD_INDEX_WIDTH-1:0] mshr_word_q [0:MSHRS-1];
    reg [FILL_INDEX_WIDTH-1:0] mshr_fill_word_q [0:MSHRS-1];
    reg [CLIENT_INDEX_WIDTH-1:0] mshr_client_q [0:MSHRS-1];
    reg [CLIENT_TAG_WIDTH-1:0] mshr_client_tag_q [0:MSHRS-1];
    reg [ADDR_WIDTH-1:0] mshr_store_addr_q [0:MSHRS-1];
    reg [CLIENT_DATA_WIDTH-1:0] mshr_store_data_q [0:MSHRS-1];
    reg [CLIENT_BYTES-1:0] mshr_store_strobe_q [0:MSHRS-1];

    reg [CLIENT_INDEX_WIDTH-1:0] client_rr_q;
    reg [MSHR_INDEX_WIDTH-1:0] mem_rr_q;
    reg [7:0] mem_burst_followers_q;
    reg [ADDR_WIDTH-1:0] mem_burst_next_addr_q;
    reg replay_q;

    reg prefetch_active_q;
    reg [ADDR_WIDTH-1:0] prefetch_line_q;
    reg [3:0] prefetch_remaining_q;
    reg prefetch_streaming_q;

    assign prefetch_ready_o = !prefetch_active_q;
    wire prefetch_accept = prefetch_valid_i && prefetch_ready_o;

    reg any_prefetch_mshr;
    reg any_mshr;
    integer busy_scan;
    always @* begin
        any_prefetch_mshr = 1'b0;
        any_mshr = 1'b0;
        for (busy_scan = 0; busy_scan < MSHRS;
             busy_scan = busy_scan + 1) begin
            if (mshr_valid_q[busy_scan]) begin
                any_mshr = 1'b1;
                if (mshr_prefetch_q[busy_scan])
                    any_prefetch_mshr = 1'b1;
            end
        end
    end
    assign prefetch_busy_o = prefetch_active_q || any_prefetch_mshr;
    assign busy_o = any_mshr || prefetch_active_q;
    assign replay_o = replay_q;

    reg free_mshr_found;
    reg [MSHR_INDEX_WIDTH-1:0] free_mshr;
    integer free_scan;
    always @* begin
        free_mshr_found = 1'b0;
        free_mshr = {MSHR_INDEX_WIDTH{1'b0}};
        for (free_scan = 0; free_scan < MSHRS;
             free_scan = free_scan + 1) begin
            if (!free_mshr_found && !mshr_valid_q[free_scan]) begin
                free_mshr_found = 1'b1;
                free_mshr = free_scan[MSHR_INDEX_WIDTH-1:0];
            end
        end
    end

    // A completed demand/store MSHR reserves its client's response slot. This
    // keeps a same-cycle cache hit from overwriting the held completion.
    reg completion_found;
    reg [MSHR_INDEX_WIDTH-1:0] completion_mshr;
    reg [CLIENT_INDEX_WIDTH-1:0] completion_client;
    integer completion_scan;
    always @* begin
        completion_found = 1'b0;
        completion_mshr = {MSHR_INDEX_WIDTH{1'b0}};
        completion_client = {CLIENT_INDEX_WIDTH{1'b0}};
        for (completion_scan = 0; completion_scan < MSHRS;
             completion_scan = completion_scan + 1) begin
            if (!completion_found && mshr_valid_q[completion_scan] &&
                mshr_done_q[completion_scan] &&
                !mshr_prefetch_q[completion_scan] &&
                (!client_resp_valid_q[mshr_client_q[completion_scan]] ||
                 client_resp_ready_i[mshr_client_q[completion_scan]])) begin
                completion_found = 1'b1;
                completion_mshr =
                    completion_scan[MSHR_INDEX_WIDTH-1:0];
                completion_client = mshr_client_q[completion_scan];
            end
        end
    end

    // Per-client tag lookup, in-flight-line check, and victim selection.
    reg client_hit_q [0:CLIENTS-1];
    reg [WAY_INDEX_WIDTH-1:0] client_hit_way_q [0:CLIENTS-1];
    reg client_line_busy_q [0:CLIENTS-1];
    reg client_victim_found_q [0:CLIENTS-1];
    reg [WAY_INDEX_WIDTH-1:0] client_victim_way_q [0:CLIENTS-1];
    integer lookup_client;
    integer lookup_way;
    integer lookup_mshr;
    integer lookup_line;
    integer best_age;
    reg lookup_reserved;
    always @* begin
        for (lookup_client = 0; lookup_client < CLIENTS;
             lookup_client = lookup_client + 1) begin
            client_hit_q[lookup_client] = 1'b0;
            client_hit_way_q[lookup_client] =
                {WAY_INDEX_WIDTH{1'b0}};
            client_line_busy_q[lookup_client] = 1'b0;
            client_victim_found_q[lookup_client] = 1'b0;
            client_victim_way_q[lookup_client] =
                {WAY_INDEX_WIDTH{1'b0}};

            for (lookup_way = 0; lookup_way < WAYS;
                 lookup_way = lookup_way + 1) begin
                lookup_line = line_index(address_set(client_req_addr_i[
                    lookup_client*ADDR_WIDTH +: ADDR_WIDTH]), lookup_way);
                if (valid_q[lookup_line] &&
                    (tag_q[lookup_line] == address_tag(client_req_addr_i[
                        lookup_client*ADDR_WIDTH +: ADDR_WIDTH]))) begin
                    client_hit_q[lookup_client] = 1'b1;
                    client_hit_way_q[lookup_client] =
                        lookup_way[WAY_INDEX_WIDTH-1:0];
                end
            end
            for (lookup_mshr = 0; lookup_mshr < MSHRS;
                 lookup_mshr = lookup_mshr + 1)
                if (mshr_valid_q[lookup_mshr] &&
                    (mshr_line_addr_q[lookup_mshr] ==
                     line_address(client_req_addr_i[
                        lookup_client*ADDR_WIDTH +: ADDR_WIDTH])))
                    client_line_busy_q[lookup_client] = 1'b1;

            // Invalid ways have first priority.
            for (lookup_way = 0; lookup_way < WAYS;
                 lookup_way = lookup_way + 1) begin
                lookup_reserved = 1'b0;
                for (lookup_mshr = 0; lookup_mshr < MSHRS;
                     lookup_mshr = lookup_mshr + 1)
                    if (mshr_valid_q[lookup_mshr] &&
                        !mshr_store_q[lookup_mshr] &&
                        !mshr_done_q[lookup_mshr] &&
                        (mshr_set_q[lookup_mshr] ==
                         address_set(client_req_addr_i[
                            lookup_client*ADDR_WIDTH +: ADDR_WIDTH])) &&
                        (mshr_way_q[lookup_mshr] == lookup_way))
                        lookup_reserved = 1'b1;
                lookup_line = line_index(address_set(client_req_addr_i[
                    lookup_client*ADDR_WIDTH +: ADDR_WIDTH]), lookup_way);
                if (!client_victim_found_q[lookup_client] &&
                    !lookup_reserved && !valid_q[lookup_line]) begin
                    client_victim_found_q[lookup_client] = 1'b1;
                    client_victim_way_q[lookup_client] =
                        lookup_way[WAY_INDEX_WIDTH-1:0];
                end
            end
            // A consumed streaming line is the next victim even if another
            // valid line is older.
            if (!client_victim_found_q[lookup_client]) begin
                for (lookup_way = 0; lookup_way < WAYS;
                     lookup_way = lookup_way + 1) begin
                    lookup_reserved = 1'b0;
                    for (lookup_mshr = 0; lookup_mshr < MSHRS;
                         lookup_mshr = lookup_mshr + 1)
                        if (mshr_valid_q[lookup_mshr] &&
                            !mshr_store_q[lookup_mshr] &&
                            !mshr_done_q[lookup_mshr] &&
                            (mshr_set_q[lookup_mshr] ==
                             address_set(client_req_addr_i[
                                lookup_client*ADDR_WIDTH +: ADDR_WIDTH])) &&
                            (mshr_way_q[lookup_mshr] == lookup_way))
                            lookup_reserved = 1'b1;
                    lookup_line = line_index(address_set(client_req_addr_i[
                        lookup_client*ADDR_WIDTH +: ADDR_WIDTH]), lookup_way);
                    if (!client_victim_found_q[lookup_client] &&
                        !lookup_reserved && valid_q[lookup_line] &&
                        discard_next_q[lookup_line]) begin
                        client_victim_found_q[lookup_client] = 1'b1;
                        client_victim_way_q[lookup_client] =
                            lookup_way[WAY_INDEX_WIDTH-1:0];
                    end
                end
            end
            // Otherwise select the oldest unreserved way.
            if (!client_victim_found_q[lookup_client]) begin
                best_age = 0;
                for (lookup_way = 0; lookup_way < WAYS;
                     lookup_way = lookup_way + 1) begin
                    lookup_reserved = 1'b0;
                    for (lookup_mshr = 0; lookup_mshr < MSHRS;
                         lookup_mshr = lookup_mshr + 1)
                        if (mshr_valid_q[lookup_mshr] &&
                            !mshr_store_q[lookup_mshr] &&
                            !mshr_done_q[lookup_mshr] &&
                            (mshr_set_q[lookup_mshr] ==
                             address_set(client_req_addr_i[
                                lookup_client*ADDR_WIDTH +: ADDR_WIDTH])) &&
                            (mshr_way_q[lookup_mshr] == lookup_way))
                            lookup_reserved = 1'b1;
                    lookup_line = line_index(address_set(client_req_addr_i[
                        lookup_client*ADDR_WIDTH +: ADDR_WIDTH]), lookup_way);
                    if (!lookup_reserved &&
                        (!client_victim_found_q[lookup_client] ||
                         (age_q[lookup_line] >= best_age))) begin
                        best_age = age_q[lookup_line];
                        client_victim_found_q[lookup_client] = 1'b1;
                        client_victim_way_q[lookup_client] =
                            lookup_way[WAY_INDEX_WIDTH-1:0];
                    end
                end
            end
        end
    end

    reg selected_client_found;
    reg [CLIENT_INDEX_WIDTH-1:0] selected_client;
    integer client_scan;
    integer client_candidate;
    reg client_response_available;
    reg client_request_eligible;
    always @* begin
        client_req_ready_o = {CLIENTS{1'b0}};
        selected_client_found = 1'b0;
        selected_client = {CLIENT_INDEX_WIDTH{1'b0}};
        for (client_scan = 0; client_scan < CLIENTS;
             client_scan = client_scan + 1) begin
            client_candidate = client_rr_q + client_scan;
            if (client_candidate >= CLIENTS)
                client_candidate = client_candidate - CLIENTS;
            client_response_available =
                (!client_resp_valid_q[client_candidate] ||
                 client_resp_ready_i[client_candidate]) &&
                (!completion_found ||
                 (completion_client != client_candidate));
            client_request_eligible = client_response_available;
            if (client_req_write_i[client_candidate]) begin
                client_request_eligible = client_request_eligible &&
                    free_mshr_found &&
                    !client_line_busy_q[client_candidate];
            end else if (!client_hit_q[client_candidate]) begin
                client_request_eligible = client_request_eligible &&
                    free_mshr_found &&
                    !client_line_busy_q[client_candidate] &&
                    client_victim_found_q[client_candidate];
            end
            if (!selected_client_found &&
                client_req_valid_i[client_candidate] &&
                client_request_eligible) begin
                selected_client_found = 1'b1;
                selected_client =
                    client_candidate[CLIENT_INDEX_WIDTH-1:0];
                client_req_ready_o[client_candidate] = 1'b1;
            end
        end
    end
    wire client_request_fire = selected_client_found &&
        client_req_valid_i[selected_client] &&
        client_req_ready_o[selected_client];
    wire selected_write = client_req_write_i[selected_client];
    wire selected_hit = client_hit_q[selected_client];
    wire [ADDR_WIDTH-1:0] selected_addr = client_req_addr_i[
        selected_client*ADDR_WIDTH +: ADDR_WIDTH];
    wire [CLIENT_TAG_WIDTH-1:0] selected_tag = client_req_tag_i[
        selected_client*CLIENT_TAG_WIDTH +: CLIENT_TAG_WIDTH];
    wire [CLIENT_DATA_WIDTH-1:0] selected_wdata = client_req_wdata_i[
        selected_client*CLIENT_DATA_WIDTH +: CLIENT_DATA_WIDTH];
    wire [CLIENT_BYTES-1:0] selected_wstrb = client_req_wstrb_i[
        selected_client*CLIENT_BYTES +: CLIENT_BYTES];

    // Prefetch lookup is separate because it has no client response slot.
    reg prefetch_hit;
    reg [WAY_INDEX_WIDTH-1:0] prefetch_hit_way;
    reg prefetch_line_busy;
    reg prefetch_victim_found;
    reg [WAY_INDEX_WIDTH-1:0] prefetch_victim_way;
    integer prefetch_way_scan;
    integer prefetch_mshr_scan;
    integer prefetch_lookup_line;
    integer prefetch_best_age;
    reg prefetch_reserved;
    always @* begin
        prefetch_hit = 1'b0;
        prefetch_hit_way = {WAY_INDEX_WIDTH{1'b0}};
        prefetch_line_busy = 1'b0;
        prefetch_victim_found = 1'b0;
        prefetch_victim_way = {WAY_INDEX_WIDTH{1'b0}};
        for (prefetch_way_scan = 0; prefetch_way_scan < WAYS;
             prefetch_way_scan = prefetch_way_scan + 1) begin
            prefetch_lookup_line = line_index(address_set(prefetch_line_q),
                                              prefetch_way_scan);
            if (valid_q[prefetch_lookup_line] &&
                (tag_q[prefetch_lookup_line] ==
                 address_tag(prefetch_line_q))) begin
                prefetch_hit = 1'b1;
                prefetch_hit_way =
                    prefetch_way_scan[WAY_INDEX_WIDTH-1:0];
            end
        end
        for (prefetch_mshr_scan = 0; prefetch_mshr_scan < MSHRS;
             prefetch_mshr_scan = prefetch_mshr_scan + 1)
            if (mshr_valid_q[prefetch_mshr_scan] &&
                (mshr_line_addr_q[prefetch_mshr_scan] ==
                 prefetch_line_q))
                prefetch_line_busy = 1'b1;

        for (prefetch_way_scan = 0; prefetch_way_scan < WAYS;
             prefetch_way_scan = prefetch_way_scan + 1) begin
            prefetch_reserved = 1'b0;
            for (prefetch_mshr_scan = 0; prefetch_mshr_scan < MSHRS;
                 prefetch_mshr_scan = prefetch_mshr_scan + 1)
                if (mshr_valid_q[prefetch_mshr_scan] &&
                    !mshr_store_q[prefetch_mshr_scan] &&
                    !mshr_done_q[prefetch_mshr_scan] &&
                    (mshr_set_q[prefetch_mshr_scan] ==
                     address_set(prefetch_line_q)) &&
                    (mshr_way_q[prefetch_mshr_scan] == prefetch_way_scan))
                    prefetch_reserved = 1'b1;
            prefetch_lookup_line = line_index(address_set(prefetch_line_q),
                                              prefetch_way_scan);
            if (!prefetch_victim_found && !prefetch_reserved &&
                !valid_q[prefetch_lookup_line]) begin
                prefetch_victim_found = 1'b1;
                prefetch_victim_way =
                    prefetch_way_scan[WAY_INDEX_WIDTH-1:0];
            end
        end
        if (!prefetch_victim_found) begin
            for (prefetch_way_scan = 0; prefetch_way_scan < WAYS;
                 prefetch_way_scan = prefetch_way_scan + 1) begin
                prefetch_reserved = 1'b0;
                for (prefetch_mshr_scan = 0; prefetch_mshr_scan < MSHRS;
                     prefetch_mshr_scan = prefetch_mshr_scan + 1)
                    if (mshr_valid_q[prefetch_mshr_scan] &&
                        !mshr_store_q[prefetch_mshr_scan] &&
                        !mshr_done_q[prefetch_mshr_scan] &&
                        (mshr_set_q[prefetch_mshr_scan] ==
                         address_set(prefetch_line_q)) &&
                        (mshr_way_q[prefetch_mshr_scan] ==
                         prefetch_way_scan))
                        prefetch_reserved = 1'b1;
                prefetch_lookup_line = line_index(
                    address_set(prefetch_line_q), prefetch_way_scan);
                if (!prefetch_victim_found && !prefetch_reserved &&
                    valid_q[prefetch_lookup_line] &&
                    discard_next_q[prefetch_lookup_line]) begin
                    prefetch_victim_found = 1'b1;
                    prefetch_victim_way =
                        prefetch_way_scan[WAY_INDEX_WIDTH-1:0];
                end
            end
        end
        if (!prefetch_victim_found) begin
            prefetch_best_age = 0;
            for (prefetch_way_scan = 0; prefetch_way_scan < WAYS;
                 prefetch_way_scan = prefetch_way_scan + 1) begin
                prefetch_reserved = 1'b0;
                for (prefetch_mshr_scan = 0; prefetch_mshr_scan < MSHRS;
                     prefetch_mshr_scan = prefetch_mshr_scan + 1)
                    if (mshr_valid_q[prefetch_mshr_scan] &&
                        !mshr_store_q[prefetch_mshr_scan] &&
                        !mshr_done_q[prefetch_mshr_scan] &&
                        (mshr_set_q[prefetch_mshr_scan] ==
                         address_set(prefetch_line_q)) &&
                        (mshr_way_q[prefetch_mshr_scan] ==
                         prefetch_way_scan))
                        prefetch_reserved = 1'b1;
                prefetch_lookup_line = line_index(
                    address_set(prefetch_line_q), prefetch_way_scan);
                if (!prefetch_reserved &&
                    (!prefetch_victim_found ||
                     (age_q[prefetch_lookup_line] >=
                      prefetch_best_age))) begin
                    prefetch_best_age = age_q[prefetch_lookup_line];
                    prefetch_victim_found = 1'b1;
                    prefetch_victim_way =
                        prefetch_way_scan[WAY_INDEX_WIDTH-1:0];
                end
            end
        end
    end

    // External request arbitration rotates between MSHRs. Each MSHR keeps at
    // most one request outstanding, making an external retry unambiguous.
    reg mem_request_found;
    reg demand_request_found;
    reg [MSHR_INDEX_WIDTH-1:0] mem_request_mshr;
    integer mem_scan;
    integer mem_candidate;
    integer mem_burst_scan;
    integer mem_burst_candidate;
    integer mem_burst_search;
    integer mem_burst_count;
    integer mem_expected_addr;
    reg mem_burst_scan_active;
    reg mem_burst_candidate_found;
    always @* begin
        mem_request_found = 1'b0;
        demand_request_found = 1'b0;
        mem_request_mshr = {MSHR_INDEX_WIDTH{1'b0}};
        if (mem_burst_followers_q != 0) begin
            for (mem_scan = 0; mem_scan < MSHRS;
                 mem_scan = mem_scan + 1) begin
                if (!mem_request_found && mshr_valid_q[mem_scan] &&
                    !mshr_wait_q[mem_scan] && !mshr_done_q[mem_scan] &&
                    !mshr_store_q[mem_scan] &&
                    ((mshr_line_addr_q[mem_scan] +
                      mshr_fill_word_q[mem_scan] * MEM_BYTES) ==
                     mem_burst_next_addr_q)) begin
                    mem_request_found = 1'b1;
                    mem_request_mshr =
                        mem_scan[MSHR_INDEX_WIDTH-1:0];
                end
            end
        end else begin
            // Demand/store requests take priority. Prefetches are deliberately
            // held while their descriptor is still allocating MSHRs, then the
            // lowest ready address leads the coalesced batch. Choosing a
            // prefetch by the RR pointer can otherwise split one contiguous
            // descriptor at the MSHR-ring wrap point.
            for (mem_scan = 0; mem_scan < MSHRS;
                 mem_scan = mem_scan + 1) begin
                mem_candidate = mem_rr_q + mem_scan;
                if (mem_candidate >= MSHRS)
                    mem_candidate = mem_candidate - MSHRS;
                if (!mem_request_found && mshr_valid_q[mem_candidate] &&
                    !mshr_wait_q[mem_candidate] &&
                    !mshr_done_q[mem_candidate] &&
                    !mshr_prefetch_q[mem_candidate]) begin
                    mem_request_found = 1'b1;
                    demand_request_found = 1'b1;
                    mem_request_mshr =
                        mem_candidate[MSHR_INDEX_WIDTH-1:0];
                end
            end
            for (mem_scan = 0; mem_scan < MSHRS;
                 mem_scan = mem_scan + 1) begin
                if (!demand_request_found && mshr_valid_q[mem_scan] &&
                    !mshr_wait_q[mem_scan] && !mshr_done_q[mem_scan] &&
                    mshr_prefetch_q[mem_scan] &&
                    !(prefetch_active_q && free_mshr_found) &&
                    (!mem_request_found ||
                     ((mshr_line_addr_q[mem_scan] +
                       mshr_fill_word_q[mem_scan] * MEM_BYTES) <
                      (mshr_line_addr_q[mem_request_mshr] +
                       mshr_fill_word_q[mem_request_mshr] * MEM_BYTES)))) begin
                    mem_request_found = 1'b1;
                    mem_request_mshr =
                        mem_scan[MSHR_INDEX_WIDTH-1:0];
                end
            end
        end
    end
    assign mem_req_valid_o = mem_request_found;
    assign mem_req_tag_o = {{(MEM_TAG_WIDTH-MSHR_INDEX_WIDTH){1'b0}},
                            mem_request_mshr};
    assign mem_req_write_o = mem_request_found &&
                             mshr_store_q[mem_request_mshr];
    assign mem_req_addr_o = mshr_store_q[mem_request_mshr] ?
        (mshr_store_addr_q[mem_request_mshr] +
         ((MEM_BYTES < CLIENT_BYTES) ?
          (mshr_fill_word_q[mem_request_mshr] * MEM_BYTES) : 0)) :
        mshr_line_addr_q[mem_request_mshr] +
        mshr_fill_word_q[mem_request_mshr] * MEM_BYTES;
    reg [7:0] mem_request_burst;
    always @* begin
        mem_burst_count = 0;
        mem_expected_addr = mem_req_addr_o + MEM_BYTES;
        mem_burst_scan_active = mem_request_found &&
            (mem_burst_followers_q == 0) &&
            !mshr_store_q[mem_request_mshr] &&
            mshr_prefetch_q[mem_request_mshr] &&
            (MEM_MAX_BURST_REQUESTS > 1);
        for (mem_burst_scan = 1; mem_burst_scan < MSHRS;
             mem_burst_scan = mem_burst_scan + 1) begin
            mem_burst_candidate_found = 1'b0;
            mem_burst_candidate = 0;
            for (mem_burst_search = 0; mem_burst_search < MSHRS;
                 mem_burst_search = mem_burst_search + 1) begin
                if (mem_burst_scan_active &&
                    !mem_burst_candidate_found &&
                    mshr_valid_q[mem_burst_search] &&
                    !mshr_wait_q[mem_burst_search] &&
                    !mshr_done_q[mem_burst_search] &&
                    !mshr_store_q[mem_burst_search] &&
                    mshr_prefetch_q[mem_burst_search] &&
                    ((mshr_line_addr_q[mem_burst_search] +
                      mshr_fill_word_q[mem_burst_search] * MEM_BYTES) ==
                     mem_expected_addr)) begin
                    mem_burst_candidate_found = 1'b1;
                    mem_burst_candidate = mem_burst_search;
                end
            end
            if (mem_burst_scan_active && mem_burst_candidate_found &&
                ((mem_burst_count + 1) < MEM_MAX_BURST_REQUESTS)) begin
                mem_burst_count = mem_burst_count + 1;
                mem_expected_addr = mem_expected_addr + MEM_BYTES;
            end else begin
                mem_burst_scan_active = 1'b0;
            end
        end
        mem_request_burst = mem_burst_count[7:0];
    end
    assign mem_req_burst_o = mem_request_burst;
    reg [MEM_DATA_WIDTH-1:0] mem_request_wdata;
    reg [MEM_BYTES-1:0] mem_request_wstrb;
    integer mem_output_byte;
    integer mem_source_byte;
    integer mem_store_lane;
    always @* begin
        mem_request_wdata = {MEM_DATA_WIDTH{1'b0}};
        mem_request_wstrb = {MEM_BYTES{1'b0}};
        mem_store_lane = mshr_store_addr_q[mem_request_mshr] &
                         (MEM_BYTES - 1);
        for (mem_output_byte = 0; mem_output_byte < MEM_BYTES;
             mem_output_byte = mem_output_byte + 1) begin
            if (MEM_BYTES >= CLIENT_BYTES)
                mem_source_byte = mem_output_byte - mem_store_lane;
            else
                mem_source_byte =
                    mshr_fill_word_q[mem_request_mshr] * MEM_BYTES +
                    mem_output_byte;
            if ((mem_source_byte >= 0) &&
                (mem_source_byte < CLIENT_BYTES)) begin
                mem_request_wdata[8*mem_output_byte +: 8] =
                    mshr_store_data_q[mem_request_mshr][
                        8*mem_source_byte +: 8];
                mem_request_wstrb[mem_output_byte] =
                    mshr_store_strobe_q[mem_request_mshr][mem_source_byte];
            end
        end
    end
    assign mem_req_wdata_o = mem_request_wdata;
    assign mem_req_wstrb_o = mem_request_wstrb;
    assign mem_resp_ready_o = 1'b1;
    wire mem_request_fire = mem_req_valid_o && mem_req_ready_i;
    wire [MSHR_INDEX_WIDTH-1:0] response_mshr =
        mem_resp_tag_i[MSHR_INDEX_WIDTH-1:0];

    integer reset_line;
    integer reset_client;
    integer reset_mshr;
    integer age_way;
    integer active_line;
    integer response_line;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            client_resp_valid_q <= {CLIENTS{1'b0}};
            client_rr_q <= {CLIENT_INDEX_WIDTH{1'b0}};
            mem_rr_q <= {MSHR_INDEX_WIDTH{1'b0}};
            mem_burst_followers_q <= 0;
            mem_burst_next_addr_q <= 0;
            replay_q <= 1'b0;
            prefetch_active_q <= 1'b0;
            prefetch_line_q <= {ADDR_WIDTH{1'b0}};
            prefetch_remaining_q <= 4'd0;
            prefetch_streaming_q <= 1'b0;
            for (reset_client = 0; reset_client < CLIENTS;
                 reset_client = reset_client + 1) begin
                client_resp_tag_q[reset_client] <=
                    {CLIENT_TAG_WIDTH{1'b0}};
                client_resp_rdata_q[reset_client] <=
                    {CLIENT_DATA_WIDTH{1'b0}};
                client_resp_error_q[reset_client] <= 1'b0;
            end
            for (reset_line = 0; reset_line < LINES;
                 reset_line = reset_line + 1) begin
                valid_q[reset_line] <= 1'b0;
                tag_q[reset_line] <= {TAG_BITS{1'b0}};
                streaming_q[reset_line] <= 1'b0;
                discard_next_q[reset_line] <= 1'b0;
                age_q[reset_line] <= {AGE_WIDTH{1'b0}};
            end
            for (reset_mshr = 0; reset_mshr < MSHRS;
                 reset_mshr = reset_mshr + 1) begin
                mshr_valid_q[reset_mshr] <= 1'b0;
                mshr_store_q[reset_mshr] <= 1'b0;
                mshr_prefetch_q[reset_mshr] <= 1'b0;
                mshr_streaming_q[reset_mshr] <= 1'b0;
                mshr_wait_q[reset_mshr] <= 1'b0;
                mshr_done_q[reset_mshr] <= 1'b0;
                mshr_error_q[reset_mshr] <= 1'b0;
                mshr_line_addr_q[reset_mshr] <= {ADDR_WIDTH{1'b0}};
                mshr_set_q[reset_mshr] <= {SET_INDEX_WIDTH{1'b0}};
                mshr_way_q[reset_mshr] <= {WAY_INDEX_WIDTH{1'b0}};
                mshr_word_q[reset_mshr] <= {WORD_INDEX_WIDTH{1'b0}};
                mshr_fill_word_q[reset_mshr] <=
                    {FILL_INDEX_WIDTH{1'b0}};
                mshr_client_q[reset_mshr] <=
                    {CLIENT_INDEX_WIDTH{1'b0}};
                mshr_client_tag_q[reset_mshr] <=
                    {CLIENT_TAG_WIDTH{1'b0}};
                mshr_store_addr_q[reset_mshr] <= {ADDR_WIDTH{1'b0}};
                mshr_store_data_q[reset_mshr] <=
                    {CLIENT_DATA_WIDTH{1'b0}};
                mshr_store_strobe_q[reset_mshr] <=
                    {CLIENT_BYTES{1'b0}};
            end
        end else begin
            replay_q <= 1'b0;
            for (reset_client = 0; reset_client < CLIENTS;
                 reset_client = reset_client + 1)
                if (client_resp_valid_q[reset_client] &&
                    client_resp_ready_i[reset_client])
                    client_resp_valid_q[reset_client] <= 1'b0;

            if (prefetch_accept) begin
                prefetch_line_q <= line_address(prefetch_addr_i);
                prefetch_remaining_q <= prefetch_count_i;
                prefetch_streaming_q <= prefetch_streaming_i;
                prefetch_active_q <= |prefetch_count_i;
            end

            if (completion_found) begin
                client_resp_valid_q[completion_client] <= 1'b1;
                client_resp_tag_q[completion_client] <=
                    mshr_client_tag_q[completion_mshr];
                client_resp_error_q[completion_client] <=
                    mshr_error_q[completion_mshr];
                if (!mshr_store_q[completion_mshr] &&
                    !mshr_error_q[completion_mshr])
                    client_resp_rdata_q[completion_client] <= data_q[
                        data_index(mshr_set_q[completion_mshr],
                                   mshr_way_q[completion_mshr],
                                   (mshr_word_q[completion_mshr] *
                                    CLIENT_BYTES) / ARRAY_BYTES)][
                        ((mshr_word_q[completion_mshr] * CLIENT_BYTES) %
                         ARRAY_BYTES)*8 +: CLIENT_DATA_WIDTH];
                else
                    client_resp_rdata_q[completion_client] <=
                        {CLIENT_DATA_WIDTH{1'b0}};
                mshr_valid_q[completion_mshr] <= 1'b0;
                mshr_done_q[completion_mshr] <= 1'b0;
            end

            if (client_request_fire) begin
                client_rr_q <= (selected_client == CLIENTS - 1) ?
                    {CLIENT_INDEX_WIDTH{1'b0}} : selected_client + 1'b1;
                if (!selected_write && selected_hit) begin
                    active_line = line_index(address_set(selected_addr),
                        client_hit_way_q[selected_client]);
                    client_resp_valid_q[selected_client] <= 1'b1;
                    client_resp_tag_q[selected_client] <= selected_tag;
                    client_resp_rdata_q[selected_client] <= data_q[
                        data_index(address_set(selected_addr),
                            client_hit_way_q[selected_client],
                            address_array_word(selected_addr))][
                        address_client_lane(selected_addr)*
                            CLIENT_DATA_WIDTH +: CLIENT_DATA_WIDTH];
                    client_resp_error_q[selected_client] <= 1'b0;
                    for (age_way = 0; age_way < WAYS;
                         age_way = age_way + 1) begin
                        if (age_way == client_hit_way_q[selected_client])
                            age_q[line_index(address_set(selected_addr),
                                             age_way)] <=
                                {AGE_WIDTH{1'b0}};
                        else if (valid_q[line_index(
                                     address_set(selected_addr), age_way)] &&
                                 (age_q[line_index(
                                     address_set(selected_addr), age_way)] <
                                  WAYS - 1))
                            age_q[line_index(address_set(selected_addr),
                                             age_way)] <=
                                age_q[line_index(address_set(selected_addr),
                                                 age_way)] + 1'b1;
                    end
                    if (streaming_q[active_line] &&
                        (address_word(selected_addr) ==
                         CLIENT_WORDS_PER_LINE - 1))
                        discard_next_q[active_line] <= 1'b1;
                end else begin
                    mshr_valid_q[free_mshr] <= 1'b1;
                    mshr_store_q[free_mshr] <= selected_write;
                    mshr_prefetch_q[free_mshr] <= 1'b0;
                    mshr_streaming_q[free_mshr] <= 1'b0;
                    mshr_wait_q[free_mshr] <= 1'b0;
                    mshr_done_q[free_mshr] <= 1'b0;
                    mshr_error_q[free_mshr] <= 1'b0;
                    mshr_line_addr_q[free_mshr] <=
                        line_address(selected_addr);
                    mshr_set_q[free_mshr] <= address_set(selected_addr);
                    mshr_way_q[free_mshr] <=
                        client_victim_way_q[selected_client];
                    mshr_word_q[free_mshr] <= address_word(selected_addr);
                    mshr_fill_word_q[free_mshr] <=
                        {FILL_INDEX_WIDTH{1'b0}};
                    mshr_client_q[free_mshr] <= selected_client;
                    mshr_client_tag_q[free_mshr] <= selected_tag;
                    mshr_store_addr_q[free_mshr] <= selected_addr;
                    mshr_store_data_q[free_mshr] <= selected_wdata;
                    mshr_store_strobe_q[free_mshr] <= selected_wstrb;
                    if (selected_write && selected_hit) begin
                        active_line = line_index(address_set(selected_addr),
                            client_hit_way_q[selected_client]);
                        valid_q[active_line] <= 1'b0;
                        streaming_q[active_line] <= 1'b0;
                        discard_next_q[active_line] <= 1'b0;
                    end else if (!selected_write) begin
                        active_line = line_index(address_set(selected_addr),
                            client_victim_way_q[selected_client]);
                        valid_q[active_line] <= 1'b0;
                        streaming_q[active_line] <= 1'b0;
                        discard_next_q[active_line] <= 1'b0;
                    end
                end
            end else if (prefetch_active_q) begin
                if (prefetch_hit || prefetch_line_busy) begin
                    if (prefetch_hit && prefetch_streaming_q) begin
                        active_line = line_index(address_set(prefetch_line_q),
                                                 prefetch_hit_way);
                        streaming_q[active_line] <= 1'b1;
                    end
                    prefetch_line_q <= prefetch_line_q + LINE_BYTES;
                    prefetch_remaining_q <= prefetch_remaining_q - 1'b1;
                    if (prefetch_remaining_q == 1)
                        prefetch_active_q <= 1'b0;
                end else if (free_mshr_found && prefetch_victim_found) begin
                    mshr_valid_q[free_mshr] <= 1'b1;
                    mshr_store_q[free_mshr] <= 1'b0;
                    mshr_prefetch_q[free_mshr] <= 1'b1;
                    mshr_streaming_q[free_mshr] <= prefetch_streaming_q;
                    mshr_wait_q[free_mshr] <= 1'b0;
                    mshr_done_q[free_mshr] <= 1'b0;
                    mshr_error_q[free_mshr] <= 1'b0;
                    mshr_line_addr_q[free_mshr] <= prefetch_line_q;
                    mshr_set_q[free_mshr] <= address_set(prefetch_line_q);
                    mshr_way_q[free_mshr] <= prefetch_victim_way;
                    mshr_word_q[free_mshr] <= {WORD_INDEX_WIDTH{1'b0}};
                    mshr_fill_word_q[free_mshr] <=
                        {FILL_INDEX_WIDTH{1'b0}};
                    mshr_client_q[free_mshr] <=
                        {CLIENT_INDEX_WIDTH{1'b0}};
                    mshr_client_tag_q[free_mshr] <=
                        {CLIENT_TAG_WIDTH{1'b0}};
                    mshr_store_addr_q[free_mshr] <= {ADDR_WIDTH{1'b0}};
                    mshr_store_data_q[free_mshr] <=
                        {CLIENT_DATA_WIDTH{1'b0}};
                    mshr_store_strobe_q[free_mshr] <=
                        {CLIENT_BYTES{1'b0}};
                    active_line = line_index(address_set(prefetch_line_q),
                                             prefetch_victim_way);
                    valid_q[active_line] <= 1'b0;
                    streaming_q[active_line] <= 1'b0;
                    discard_next_q[active_line] <= 1'b0;
                    prefetch_line_q <= prefetch_line_q + LINE_BYTES;
                    prefetch_remaining_q <= prefetch_remaining_q - 1'b1;
                    if (prefetch_remaining_q == 1)
                        prefetch_active_q <= 1'b0;
                end
            end

            if (mem_request_fire) begin
                mshr_wait_q[mem_request_mshr] <= 1'b1;
                mem_rr_q <= (mem_request_mshr == MSHRS - 1) ?
                    {MSHR_INDEX_WIDTH{1'b0}} : mem_request_mshr + 1'b1;
                if (mem_burst_followers_q != 0) begin
                    mem_burst_followers_q <=
                        mem_burst_followers_q - 1'b1;
                    mem_burst_next_addr_q <=
                        mem_burst_next_addr_q + MEM_BYTES;
                end else if (mem_request_burst != 0) begin
                    mem_burst_followers_q <= mem_request_burst;
                    mem_burst_next_addr_q <= mem_req_addr_o + MEM_BYTES;
                end
            end

            if (mem_resp_valid_i) begin
                if (mem_resp_retry_i) begin
                    mshr_wait_q[response_mshr] <= 1'b0;
                    replay_q <= 1'b1;
                end else if (mem_resp_error_i) begin
                    mshr_wait_q[response_mshr] <= 1'b0;
                    mshr_error_q[response_mshr] <= 1'b1;
                    if (mshr_prefetch_q[response_mshr]) begin
                        mshr_valid_q[response_mshr] <= 1'b0;
                    end else begin
                        mshr_done_q[response_mshr] <= 1'b1;
                    end
                end else if (mshr_store_q[response_mshr]) begin
                    mshr_wait_q[response_mshr] <= 1'b0;
                    if (mshr_fill_word_q[response_mshr] ==
                        STORE_BEATS_PER_CLIENT - 1) begin
                        mshr_done_q[response_mshr] <= 1'b1;
                    end else begin
                        mshr_fill_word_q[response_mshr] <=
                            mshr_fill_word_q[response_mshr] + 1'b1;
                    end
                end else begin
                    response_line = line_index(mshr_set_q[response_mshr],
                                               mshr_way_q[response_mshr]);
                    data_q[data_index(mshr_set_q[response_mshr],
                        mshr_way_q[response_mshr],
                        (mshr_fill_word_q[response_mshr] * MEM_BYTES) /
                            ARRAY_BYTES)][
                        ((mshr_fill_word_q[response_mshr] * MEM_BYTES) %
                            ARRAY_BYTES)*8 +:
                        MEM_DATA_WIDTH] <= mem_resp_rdata_i;
                    mshr_wait_q[response_mshr] <= 1'b0;
                    if (mshr_fill_word_q[response_mshr] ==
                        FILL_BEATS_PER_LINE - 1) begin
                        valid_q[response_line] <= 1'b1;
                        tag_q[response_line] <=
                            address_tag(mshr_line_addr_q[response_mshr]);
                        streaming_q[response_line] <=
                            mshr_streaming_q[response_mshr];
                        discard_next_q[response_line] <= 1'b0;
                        for (age_way = 0; age_way < WAYS;
                             age_way = age_way + 1) begin
                            if (age_way == mshr_way_q[response_mshr])
                                age_q[line_index(
                                    mshr_set_q[response_mshr], age_way)] <=
                                    {AGE_WIDTH{1'b0}};
                            else if (valid_q[line_index(
                                         mshr_set_q[response_mshr],
                                         age_way)] &&
                                     (age_q[line_index(
                                         mshr_set_q[response_mshr],
                                         age_way)] < WAYS - 1))
                                age_q[line_index(
                                    mshr_set_q[response_mshr], age_way)] <=
                                    age_q[line_index(
                                        mshr_set_q[response_mshr],
                                        age_way)] + 1'b1;
                        end
                        if (mshr_prefetch_q[response_mshr]) begin
                            mshr_valid_q[response_mshr] <= 1'b0;
                        end else begin
                            mshr_done_q[response_mshr] <= 1'b1;
                        end
                    end else begin
                        mshr_fill_word_q[response_mshr] <=
                            mshr_fill_word_q[response_mshr] + 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((CLIENT_DATA_WIDTH < 8) ||
            ((CLIENT_DATA_WIDTH % 8) != 0) ||
            (MEM_DATA_WIDTH < 8) || ((MEM_DATA_WIDTH % 8) != 0))
            $fatal(1, "vector cache widths must be byte aligned");
        if (((CLIENT_DATA_WIDTH & (CLIENT_DATA_WIDTH - 1)) != 0) ||
            ((MEM_DATA_WIDTH & (MEM_DATA_WIDTH - 1)) != 0) ||
            (MEM_DATA_WIDTH < 32) || (MEM_DATA_WIDTH > 512))
            $fatal(1, "vector cache widths must be powers of two through 512 bits");
        if ((LINE_BYTES < ARRAY_BYTES) ||
            ((LINE_BYTES % CLIENT_BYTES) != 0) ||
            ((LINE_BYTES % MEM_BYTES) != 0) ||
            ((LINE_BYTES % ARRAY_BYTES) != 0) ||
            ((LINE_BYTES & (LINE_BYTES - 1)) != 0))
            $fatal(1, "vector cache line size must be a datapath multiple and power of two");
        if ((CACHE_BYTES < 256 * 1024) ||
            (CACHE_BYTES > 2 * 1024 * 1024) ||
            ((CACHE_BYTES & (CACHE_BYTES - 1)) != 0))
            $fatal(1, "vector cache supports power-of-two sizes from 256 KiB to 2 MiB");
        if ((WAYS < 1) || ((WAYS & (WAYS - 1)) != 0) ||
            ((SETS & (SETS - 1)) != 0))
            $fatal(1, "vector cache ways and sets must be powers of two");
        if ((CLIENTS < 1) || (MSHRS < 1))
            $fatal(1, "vector cache requires clients and MSHRs");
        if (MEM_TAG_WIDTH < MSHR_INDEX_WIDTH)
            $fatal(1, "external memory tag is too narrow for cache MSHRs");
        if ((MEM_MAX_BURST_REQUESTS < 1) ||
            (MEM_MAX_BURST_REQUESTS > MSHRS) ||
            (MEM_MAX_BURST_REQUESTS > 256))
            $fatal(1,
                "vector cache memory burst requests must be 1 through MSHRS");
    end

    always @(posedge clk) begin
        if (rst_n && mem_resp_valid_i) begin
            if ((response_mshr >= MSHRS) ||
                !mshr_valid_q[response_mshr] ||
                !mshr_wait_q[response_mshr])
                $fatal(1, "vector cache received an unknown response tag");
            if (mem_resp_error_i && mem_resp_retry_i)
                $fatal(1, "vector cache response cannot be error and retry");
        end
    end
`endif

endmodule
