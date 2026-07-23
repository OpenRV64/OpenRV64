`timescale 1ns/1ps

// Pipelined, physically tagged, write-through L1 cache.  req_addr_i supplies
// the lookup set/beat while req_phys_addr_i supplies the tag and lower-memory
// address.  Supplying the same address on both ports gives an ordinary PIPT
// cache; L1I uses a page-offset virtual index with a physical tag (VIPT).
//
// The requester side is decoupled: req_ready_o accepts a request and
// resp_valid_o returns its ordered response.  The hit pipeline accepts and
// completes one resident read hit per cycle when the response is consumed.
// Misses, writes, and uncached accesses serialize behind the blocking memory
// side.  Reads refill one REFILL_DATA_WIDTH beat at a time.  Writes are always
// forwarded and use no-write-allocate; a successful write hit also updates the
// resident copy.
module openrv64_l1_cache #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer REFILL_DATA_WIDTH = DATA_WIDTH,
    parameter integer CACHE_BYTES = 16 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
    // Performance-study hook.  When enabled, a cacheable read miss may be
    // completed from ideal_refill_data_i in the normal hit-response time.
    // No lower-memory request is issued and no line is installed.  Production
    // instances leave this disabled; it is an explicit ideal-memory oracle,
    // not an implementation of a realizable refill path.
    parameter integer IDEAL_REFILLS = 0,
    parameter integer WRITEBACK_TIMEOUT_CYCLES = 128,
    parameter integer DIRTY_TIMESTAMP_WIDTH =
        (WRITEBACK_TIMEOUT_CYCLES < 2) ? 1 :
        $clog2(WRITEBACK_TIMEOUT_CYCLES + 1)
) (
    input  wire                      clk_i,
    input  wire                      rst_ni,

    input  wire                      req_valid_i,
    output wire                      req_ready_o,
    input  wire                      req_write_i,
    input  wire                      req_cacheable_i,
    input  wire [ADDR_WIDTH-1:0]     req_addr_i,
    input  wire [ADDR_WIDTH-1:0]     req_phys_addr_i,
    input  wire                      req_prefetch_i,
    input  wire                      req_aged_i,
    input  wire [DATA_WIDTH-1:0]     req_wdata_i,
    input  wire [DATA_WIDTH/8-1:0]   req_wstrb_i,
    output wire                      resp_valid_o,
    input  wire                      resp_ready_i,
    output wire [DATA_WIDTH-1:0]     req_rdata_o,
    output wire                      req_error_o,

    // Back-invalidation port.  A lower inclusive cache must complete this
    // request before evicting the corresponding line.  invalidate_all_i
    // ignores invalidate_addr_i and clears the entire L1.
    input  wire                      invalidate_valid_i,
    output wire                      invalidate_ready_o,
    input  wire                      invalidate_all_i,
    input  wire [ADDR_WIDTH-1:0]     invalidate_addr_i,

    // Physical line addresses which should become preferred replacement
    // victims.  Aging never invalidates a line.
    input  wire [3:0]                age_valid_i,
    input  wire [4*ADDR_WIDTH-1:0]   age_addr_i,

    output wire                      mem_valid_o,
    input  wire                      mem_ready_i,
    output wire                      mem_write_o,
    output wire [ADDR_WIDTH-1:0]     mem_addr_o,
    output wire [DATA_WIDTH-1:0]     mem_wdata_o,
    output wire [DATA_WIDTH/8-1:0]   mem_wstrb_o,
    input  wire [REFILL_DATA_WIDTH-1:0] mem_rdata_i,
    input  wire                      mem_error_i,

    input  wire                      ideal_refill_valid_i,
    input  wire [DATA_WIDTH-1:0]     ideal_refill_data_i
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer REFILL_BYTES = REFILL_DATA_WIDTH / 8;
    localparam integer WORDS_PER_REFILL =
        REFILL_DATA_WIDTH / DATA_WIDTH;
    localparam integer WORDS_PER_LINE = LINE_BYTES / DATA_BYTES;
    localparam integer REFILLS_PER_LINE = LINE_BYTES / REFILL_BYTES;
    localparam integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam integer TOTAL_LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer REFILLS_PER_WAY = SETS * REFILLS_PER_LINE;
    localparam integer LINE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - LINE_OFFSET_BITS - SET_BITS;
    localparam integer SET_INDEX_WIDTH = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer LINE_INDEX_WIDTH =
        (TOTAL_LINES > 1) ? $clog2(TOTAL_LINES) : 1;
    localparam integer WAY_REFILL_INDEX_WIDTH =
        (REFILLS_PER_WAY > 1) ? $clog2(REFILLS_PER_WAY) : 1;
    localparam integer WAY_INDEX_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer WORD_INDEX_WIDTH =
        (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;
    localparam integer REFILL_INDEX_WIDTH =
        (REFILLS_PER_LINE > 1) ? $clog2(REFILLS_PER_LINE) : 1;
    localparam integer REFILL_WORD_INDEX_WIDTH =
        (WORDS_PER_REFILL > 1) ? $clog2(WORDS_PER_REFILL) : 1;

    localparam [1:0] STATE_RUN = 2'd0;
    localparam [1:0] STATE_REFILL = 2'd1;
    localparam [1:0] STATE_ACCESS = 2'd2;

    // Reserved coherence metadata.  valid_q remains authoritative until a
    // coherence controller is added; these encodings and the timestamp field
    // establish the per-line storage contract without pretending that the
    // current write-through cache can produce dirty data.
    localparam [1:0] MESI_INVALID = 2'b00;
    localparam [1:0] MESI_SHARED = 2'b01;
    localparam [1:0] MESI_EXCLUSIVE = 2'b10;
    localparam [1:0] MESI_MODIFIED = 2'b11;

    reg [1:0] state_q;

    // Tags are laid out set-major, then way.  Each way is split into one
    // DATA_WIDTH bank per word in a refill beat.  A scalar lookup reads only
    // its addressed bank from every way, while a refill writes all banks in
    // parallel.  This permits a full-line refill width without turning every
    // scalar hit into a full-line read.
    reg                      valid_q [0:TOTAL_LINES-1];
    reg [TAG_BITS-1:0]       tag_q [0:TOTAL_LINES-1];
    reg [1:0]                mesi_q [0:TOTAL_LINES-1];
    reg [DIRTY_TIMESTAMP_WIDTH-1:0]
                               dirty_timestamp_q [0:TOTAL_LINES-1];
    reg                      aged_q [0:TOTAL_LINES-1];
    reg [WAY_INDEX_WIDTH-1:0] replace_q [0:SETS-1];

    reg                      request_write_q;
    reg                      request_cacheable_q;
    reg                      request_prefetch_q;
    reg                      request_aged_q;
    reg [ADDR_WIDTH-1:0]     request_addr_q;
    reg [ADDR_WIDTH-1:0]     request_phys_addr_q;
    reg [DATA_WIDTH-1:0]     request_wdata_q;
    reg [DATA_BYTES-1:0]     request_wstrb_q;

    localparam [WAY_INDEX_WIDTH-1:0] LAST_WAY =
        WAY_INDEX_WIDTH'(WAYS - 1);
    localparam [REFILL_INDEX_WIDTH-1:0] LAST_REFILL =
        REFILL_INDEX_WIDTH'(REFILLS_PER_LINE - 1);

    reg [SET_INDEX_WIDTH-1:0] refill_set_q;
    reg [WAY_INDEX_WIDTH-1:0] refill_way_q;
    reg [LINE_INDEX_WIDTH-1:0] refill_line_q;
    reg [TAG_BITS-1:0]       refill_tag_q;
    reg [REFILL_INDEX_WIDTH-1:0] refill_index_q;
    reg [REFILL_INDEX_WIDTH-1:0] request_refill_index_q;
    reg [REFILL_WORD_INDEX_WIDTH-1:0] request_refill_word_q;

    reg                      access_updates_line_q;
    reg [SET_INDEX_WIDTH-1:0] access_set_q;
    reg [WAY_INDEX_WIDTH-1:0] access_way_q;
    reg [REFILL_INDEX_WIDTH-1:0] access_refill_index_q;
    reg [REFILL_WORD_INDEX_WIDTH-1:0] access_refill_word_q;

    reg                  response_valid_q;
    reg                  response_hit_q;
    reg [WAY_INDEX_WIDTH-1:0] response_way_q;
    reg [DATA_WIDTH-1:0] response_data_q;
    reg                  response_error_q;

    reg [SET_INDEX_WIDTH-1:0] lookup_set;
    reg [WORD_INDEX_WIDTH-1:0] lookup_word;
    reg [REFILL_INDEX_WIDTH-1:0] lookup_refill_index;
    reg [REFILL_WORD_INDEX_WIDTH-1:0] lookup_refill_word;
    reg [TAG_BITS-1:0] lookup_tag;
    reg [SET_INDEX_WIDTH-1:0] accept_set;
    reg [WORD_INDEX_WIDTH-1:0] accept_word;
    reg [REFILL_INDEX_WIDTH-1:0] accept_refill_index;
    reg [REFILL_WORD_INDEX_WIDTH-1:0] accept_refill_word;
    reg lookup_hit;
    reg [WAY_INDEX_WIDTH-1:0] lookup_way;
    reg [WAY_INDEX_WIDTH-1:0] victim_way;
    reg invalid_way_found;
    reg aged_way_found;
    reg [SET_INDEX_WIDTH-1:0] invalidate_set;
    reg [TAG_BITS-1:0] invalidate_tag;
    reg [LINE_INDEX_WIDTH-1:0] lookup_line;
    integer set_index;
    integer line_index;
    integer way_index;
    integer lookup_way_index;
    integer age_port;
    integer age_way;
    wire [WAYS*WORDS_PER_REFILL*DATA_WIDTH-1:0] lookup_bank_data;
    wire [DATA_WIDTH-1:0] response_hit_data =
        lookup_bank_data[
            (response_way_q*WORDS_PER_REFILL +
             request_refill_word_q)*DATA_WIDTH +: DATA_WIDTH];
    wire [DATA_WIDTH-1:0] access_resident_data =
        lookup_bank_data[
            (access_way_q*WORDS_PER_REFILL +
             access_refill_word_q)*DATA_WIDTH +: DATA_WIDTH];
    reg [DATA_WIDTH-1:0] access_write_value;
    integer access_write_byte;

    wire refill_last_beat = (refill_index_q == LAST_REFILL);
    wire [ADDR_WIDTH-1:0] refill_line_addr =
        {request_phys_addr_q[ADDR_WIDTH-1:LINE_OFFSET_BITS],
         {LINE_OFFSET_BITS{1'b0}}};

    function [LINE_INDEX_WIDTH-1:0] line_index_of;
        input [SET_INDEX_WIDTH-1:0] set_value;
        input [WAY_INDEX_WIDTH-1:0] way_value;
        begin
            line_index_of = LINE_INDEX_WIDTH'(set_value) *
                            LINE_INDEX_WIDTH'(WAYS) +
                            LINE_INDEX_WIDTH'(way_value);
        end
    endfunction

    function [SET_INDEX_WIDTH-1:0] set_index_of;
        input [ADDR_WIDTH-1:0] address;
        begin
            if (SETS == 1)
                set_index_of = {SET_INDEX_WIDTH{1'b0}};
            else
                set_index_of =
                    address[LINE_OFFSET_BITS +: SET_INDEX_WIDTH];
        end
    endfunction

    function [WAY_REFILL_INDEX_WIDTH-1:0] way_refill_index_of;
        input [SET_INDEX_WIDTH-1:0] set_value;
        input [REFILL_INDEX_WIDTH-1:0] refill_value;
        begin
            way_refill_index_of =
                WAY_REFILL_INDEX_WIDTH'(set_value) *
                WAY_REFILL_INDEX_WIDTH'(REFILLS_PER_LINE) +
                WAY_REFILL_INDEX_WIDTH'(refill_value);
        end
    endfunction

    initial begin
        if ((DATA_WIDTH < 8) || ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "L1 DATA_WIDTH must be a power of two and at least 8");
        if ((REFILL_DATA_WIDTH < DATA_WIDTH) ||
            ((REFILL_DATA_WIDTH & (REFILL_DATA_WIDTH - 1)) != 0) ||
            ((REFILL_DATA_WIDTH % DATA_WIDTH) != 0) ||
            ((LINE_BYTES * 8) % REFILL_DATA_WIDTH) != 0)
            $fatal(1, "L1 refill width must be a power-of-two multiple of DATA_WIDTH which divides the line");
        if ((CACHE_BYTES < 1024) || (CACHE_BYTES > 32768) ||
            ((CACHE_BYTES & (CACHE_BYTES - 1)) != 0))
            $fatal(1, "L1 CACHE_BYTES must be a power of two from 1 KiB to 32 KiB");
        if ((LINE_BYTES < DATA_BYTES) ||
            ((LINE_BYTES & (LINE_BYTES - 1)) != 0))
            $fatal(1, "L1 LINE_BYTES must be a power of two at least one data beat");
        if ((WAYS < 1) || ((WAYS & (WAYS - 1)) != 0))
            $fatal(1, "L1 WAYS must be a power of two");
        if ((CACHE_BYTES % (LINE_BYTES * WAYS)) != 0)
            $fatal(1, "L1 capacity must contain an integer number of sets");
        if ((DIRTY_TIMESTAMP_WIDTH < 1) || (DIRTY_TIMESTAMP_WIDTH > 16))
            $fatal(1, "L1 dirty timestamp width must be from 1 through 16 bits");
        if ((WRITEBACK_TIMEOUT_CYCLES < 1) ||
            (WRITEBACK_TIMEOUT_CYCLES >=
             (1 << DIRTY_TIMESTAMP_WIDTH)))
            $fatal(1, "L1 writeback timeout must fit the dirty timestamp width");
    end

    always @* begin
        // The single hit stage indexes every data way and compares tags in
        // parallel.  The selected way and data-array outputs are registered on
        // the accepting edge, permitting a new resident hit every cycle.
        accept_set = set_index_of(req_addr_i);
        accept_word = req_addr_i[$clog2(DATA_BYTES) +:
                                 WORD_INDEX_WIDTH];
        if (WORDS_PER_LINE == 1)
            accept_word = 0;
        accept_refill_index =
            REFILL_INDEX_WIDTH'(accept_word / WORDS_PER_REFILL);
        accept_refill_word =
            REFILL_WORD_INDEX_WIDTH'(accept_word % WORDS_PER_REFILL);

        lookup_set = accept_set;
        lookup_word = accept_word;
        lookup_refill_index = accept_refill_index;
        lookup_refill_word = accept_refill_word;
        lookup_tag = req_phys_addr_i[ADDR_WIDTH-1:
                                     LINE_OFFSET_BITS + SET_BITS];
        lookup_hit = 1'b0;
        lookup_way = {WAY_INDEX_WIDTH{1'b0}};
        for (lookup_way_index = 0; lookup_way_index < WAYS;
             lookup_way_index = lookup_way_index + 1) begin
            lookup_line = line_index_of(
                lookup_set,
                lookup_way_index[WAY_INDEX_WIDTH-1:0]);
            if (valid_q[lookup_line] &&
                tag_q[lookup_line] == lookup_tag) begin
                lookup_hit = 1'b1;
                lookup_way = lookup_way_index[WAY_INDEX_WIDTH-1:0];
            end
        end

        victim_way = replace_q[lookup_set];
        aged_way_found = 1'b0;
        for (lookup_way_index = 0; lookup_way_index < WAYS;
             lookup_way_index = lookup_way_index + 1) begin
            lookup_line = line_index_of(
                lookup_set,
                lookup_way_index[WAY_INDEX_WIDTH-1:0]);
            if (!aged_way_found && valid_q[lookup_line] &&
                aged_q[lookup_line]) begin
                victim_way = lookup_way_index[WAY_INDEX_WIDTH-1:0];
                aged_way_found = 1'b1;
            end
        end
        invalid_way_found = 1'b0;
        for (lookup_way_index = 0; lookup_way_index < WAYS;
             lookup_way_index = lookup_way_index + 1) begin
            lookup_line = line_index_of(
                lookup_set,
                lookup_way_index[WAY_INDEX_WIDTH-1:0]);
            if (!invalid_way_found && !valid_q[lookup_line]) begin
                victim_way = lookup_way_index[WAY_INDEX_WIDTH-1:0];
                invalid_way_found = 1'b1;
            end
        end
        lookup_line = line_index_of(lookup_set, lookup_way);

        invalidate_set = set_index_of(invalidate_addr_i);
        invalidate_tag = invalidate_addr_i[ADDR_WIDTH-1:
                                           LINE_OFFSET_BITS + SET_BITS];
    end

    wire response_slot_available = !response_valid_q || resp_ready_i;
    wire request_fire = req_valid_i && req_ready_o;
    wire response_fire = response_valid_q && resp_ready_i;
    wire invalidate_quiescent = !response_valid_q || resp_ready_i;

    assign invalidate_ready_o = (state_q == STATE_RUN) &&
                                invalidate_quiescent;
    assign req_ready_o = (state_q == STATE_RUN) &&
                         !invalidate_valid_i && response_slot_available;
    assign resp_valid_o = response_valid_q;
    assign req_rdata_o = response_hit_q ? response_hit_data :
                         response_data_q;
    assign req_error_o = response_error_q;

    assign mem_valid_o = (state_q == STATE_REFILL) ||
                         (state_q == STATE_ACCESS);
    assign mem_write_o = (state_q == STATE_ACCESS) && request_write_q;
    assign mem_addr_o = (state_q == STATE_REFILL) ?
        refill_line_addr + (refill_index_q * REFILL_BYTES) :
        request_phys_addr_q;
    assign mem_wdata_o = (state_q == STATE_ACCESS) ?
                         request_wdata_q : {DATA_WIDTH{1'b0}};
    assign mem_wstrb_o = ((state_q == STATE_ACCESS) && request_write_q) ?
                         request_wstrb_q : {DATA_BYTES{1'b0}};

    // A write hit is serialized behind its lower-memory access, so the
    // selected way's read data still holds the resident word captured when
    // the store was accepted.  Merge once, then present the same full-width
    // write data to every way; only access_way_q receives a write enable.
    always @* begin
        access_write_value = access_resident_data;
        for (access_write_byte = 0; access_write_byte < DATA_BYTES;
             access_write_byte = access_write_byte + 1) begin
            if (request_wstrb_q[access_write_byte])
                access_write_value[8*access_write_byte +: 8] =
                    request_wdata_q[8*access_write_byte +: 8];
        end
    end

    genvar data_way;
    genvar data_bank;
    generate
        for (data_way = 0; data_way < WAYS;
             data_way = data_way + 1) begin : g_data_ways
            for (data_bank = 0; data_bank < WORDS_PER_REFILL;
                 data_bank = data_bank + 1) begin : g_refill_banks
                // Each bank is one-read/one-write.  A full refill broadcasts
                // its independently selected word to every bank.
                (* ram_style = "block", syn_ramstyle = "block_ram" *)
                reg [DATA_WIDTH-1:0] data_q [0:REFILLS_PER_WAY-1];
                reg [DATA_WIDTH-1:0] read_data_q;

                wire refill_write = (state_q == STATE_REFILL) &&
                                    mem_ready_i && !mem_error_i &&
                                    (refill_way_q ==
                                     WAY_INDEX_WIDTH'(data_way));
                wire access_write = (state_q == STATE_ACCESS) &&
                                    mem_ready_i && request_write_q &&
                                    !mem_error_i &&
                                    access_updates_line_q &&
                                    (access_way_q ==
                                     WAY_INDEX_WIDTH'(data_way)) &&
                                    (access_refill_word_q ==
                                     REFILL_WORD_INDEX_WIDTH'(data_bank));
                wire data_write = refill_write || access_write;
                wire [WAY_REFILL_INDEX_WIDTH-1:0] data_write_addr =
                    refill_write ?
                        way_refill_index_of(
                            refill_set_q, refill_index_q) :
                        way_refill_index_of(
                            access_set_q, access_refill_index_q);
                wire [DATA_WIDTH-1:0] data_write_value =
                    refill_write ?
                        mem_rdata_i[data_bank*DATA_WIDTH +: DATA_WIDTH] :
                        access_write_value;

                assign lookup_bank_data[
                    (data_way*WORDS_PER_REFILL + data_bank)*DATA_WIDTH +:
                    DATA_WIDTH] = read_data_q;

                always @(posedge clk_i) begin
                    if (request_fire &&
                        (accept_refill_word ==
                         REFILL_WORD_INDEX_WIDTH'(data_bank)))
                        read_data_q <= data_q[
                            way_refill_index_of(
                                accept_set, accept_refill_index)];

                    if (data_write)
                        data_q[data_write_addr] <= data_write_value;
                end
            end
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_RUN;
            request_write_q <= 1'b0;
            request_cacheable_q <= 1'b0;
            request_prefetch_q <= 1'b0;
            request_aged_q <= 1'b0;
            request_addr_q <= {ADDR_WIDTH{1'b0}};
            request_phys_addr_q <= {ADDR_WIDTH{1'b0}};
            request_wdata_q <= {DATA_WIDTH{1'b0}};
            request_wstrb_q <= {DATA_BYTES{1'b0}};
            refill_set_q <= 0;
            refill_way_q <= 0;
            refill_line_q <= 0;
            refill_tag_q <= 0;
            refill_index_q <= 0;
            request_refill_index_q <= 0;
            request_refill_word_q <= 0;
            access_updates_line_q <= 1'b0;
            access_set_q <= 0;
            access_way_q <= 0;
            access_refill_index_q <= 0;
            access_refill_word_q <= 0;
            response_valid_q <= 1'b0;
            response_hit_q <= 1'b0;
            response_way_q <= 0;
            response_data_q <= {DATA_WIDTH{1'b0}};
            response_error_q <= 1'b0;
            for (set_index = 0; set_index < SETS;
                 set_index = set_index + 1)
                replace_q[set_index] <= 0;
            for (line_index = 0; line_index < TOTAL_LINES;
                 line_index = line_index + 1) begin
                valid_q[line_index] <= 1'b0;
                aged_q[line_index] <= 1'b0;
                mesi_q[line_index] <= MESI_INVALID;
                dirty_timestamp_q[line_index] <=
                    {DIRTY_TIMESTAMP_WIDTH{1'b0}};
            end
        end else begin
            if (response_fire)
                response_valid_q <= 1'b0;

            for (age_port = 0; age_port < 4;
                 age_port = age_port + 1) begin
                if (age_valid_i[age_port]) begin
                    for (age_way = 0; age_way < WAYS;
                         age_way = age_way + 1) begin
                        if (valid_q[line_index_of(
                                set_index_of(age_addr_i[
                                    age_port*ADDR_WIDTH +: ADDR_WIDTH]),
                                age_way[WAY_INDEX_WIDTH-1:0])] &&
                            tag_q[line_index_of(
                                set_index_of(age_addr_i[
                                    age_port*ADDR_WIDTH +: ADDR_WIDTH]),
                                age_way[WAY_INDEX_WIDTH-1:0])] ==
                            age_addr_i[age_port*ADDR_WIDTH +
                                       LINE_OFFSET_BITS + SET_BITS +:
                                       TAG_BITS])
                            aged_q[line_index_of(
                                set_index_of(age_addr_i[
                                    age_port*ADDR_WIDTH +: ADDR_WIDTH]),
                                age_way[WAY_INDEX_WIDTH-1:0])] <= 1'b1;
                    end
                end
            end
            case (state_q)
                STATE_RUN: begin
                    if (invalidate_valid_i && invalidate_ready_o) begin
                        if (invalidate_all_i) begin
                            for (set_index = 0; set_index < SETS;
                                 set_index = set_index + 1)
                                replace_q[set_index] <= 0;
                            for (line_index = 0; line_index < TOTAL_LINES;
                                 line_index = line_index + 1) begin
                                valid_q[line_index] <= 1'b0;
                                aged_q[line_index] <= 1'b0;
                                mesi_q[line_index] <= MESI_INVALID;
                                dirty_timestamp_q[line_index] <=
                                    {DIRTY_TIMESTAMP_WIDTH{1'b0}};
                            end
                        end else begin
                            for (way_index = 0; way_index < WAYS;
                                 way_index = way_index + 1) begin
                                if (valid_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] &&
                                    tag_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] ==
                                    invalidate_tag) begin
                                    valid_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] <=
                                        1'b0;
                                    aged_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] <=
                                        1'b0;
                                    mesi_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] <=
                                        MESI_INVALID;
                                    dirty_timestamp_q[line_index_of(
                                        invalidate_set,
                                        way_index[WAY_INDEX_WIDTH-1:0])] <=
                                        {DIRTY_TIMESTAMP_WIDTH{1'b0}};
                                end
                            end
                        end
                    end else if (request_fire) begin
                        // Capture every field needed if this operation leaves
                        // the one-cycle hit path for refill or lower memory.
                        request_write_q <= req_write_i;
                        request_cacheable_q <= req_cacheable_i;
                        request_prefetch_q <= req_prefetch_i;
                        request_aged_q <= req_aged_i;
                        request_addr_q <= req_addr_i;
                        request_phys_addr_q <= req_phys_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        request_refill_word_q <= lookup_refill_word;
                        if (!req_cacheable_i) begin
                            access_updates_line_q <= 1'b0;
                            response_hit_q <= 1'b0;
                            state_q <= STATE_ACCESS;
                        end else if (req_write_i) begin
                            access_updates_line_q <= lookup_hit;
                            access_set_q <= lookup_set;
                            access_way_q <= lookup_way;
                            access_refill_index_q <=
                                lookup_refill_index;
                            access_refill_word_q <= lookup_refill_word;
                            response_hit_q <= 1'b0;
                            if (lookup_hit)
                                replace_q[lookup_set] <=
                                    (lookup_way == LAST_WAY) ? 0 :
                                    lookup_way + 1'b1;
                            if (lookup_hit)
                                aged_q[line_index_of(
                                    lookup_set, lookup_way)] <= 1'b0;
                            state_q <= STATE_ACCESS;
                        end else if (lookup_hit) begin
                            response_valid_q <= 1'b1;
                            response_hit_q <= 1'b1;
                            response_way_q <= lookup_way;
                            response_error_q <= 1'b0;
                            replace_q[lookup_set] <=
                                (lookup_way == LAST_WAY) ? 0 :
                                lookup_way + 1'b1;
                            if (!req_prefetch_i)
                                aged_q[line_index_of(
                                    lookup_set, lookup_way)] <= 1'b0;
                            else if (req_aged_i)
                                aged_q[line_index_of(
                                    lookup_set, lookup_way)] <= 1'b1;
                        end else if ((IDEAL_REFILLS != 0) &&
                                     ideal_refill_valid_i) begin
                            response_valid_q <= 1'b1;
                            response_hit_q <= 1'b0;
                            response_data_q <= ideal_refill_data_i;
                            response_error_q <= 1'b0;
                        end else begin
                            refill_set_q <= lookup_set;
                            refill_way_q <= victim_way;
                            refill_line_q <= line_index_of(
                                lookup_set, victim_way);
                            refill_tag_q <= lookup_tag;
                            refill_index_q <= 0;
                            request_refill_index_q <=
                                lookup_refill_index;
                            response_hit_q <= 1'b0;
                            valid_q[line_index_of(
                                lookup_set, victim_way)] <= 1'b0;
                            aged_q[line_index_of(
                                lookup_set, victim_way)] <= 1'b0;
                            mesi_q[line_index_of(
                                lookup_set, victim_way)] <= MESI_INVALID;
                            dirty_timestamp_q[line_index_of(
                                lookup_set, victim_way)] <=
                                {DIRTY_TIMESTAMP_WIDTH{1'b0}};
                            state_q <= STATE_REFILL;
                        end
                    end
                end

                STATE_REFILL: begin
                    if (mem_ready_i) begin
                        if (mem_error_i) begin
                            response_data_q <= {DATA_WIDTH{1'b0}};
                            response_error_q <= 1'b1;
                            response_valid_q <= 1'b1;
                            state_q <= STATE_RUN;
                        end else begin
                            if (refill_index_q ==
                                request_refill_index_q)
                                response_data_q <= mem_rdata_i[
                                    request_refill_word_q*DATA_WIDTH +:
                                    DATA_WIDTH];
                            if (refill_last_beat) begin
                                tag_q[refill_line_q] <= refill_tag_q;
                                valid_q[refill_line_q] <= 1'b1;
                                aged_q[refill_line_q] <= request_aged_q;
                                mesi_q[refill_line_q] <= MESI_EXCLUSIVE;
                                dirty_timestamp_q[refill_line_q] <=
                                    {DIRTY_TIMESTAMP_WIDTH{1'b0}};
                                replace_q[refill_set_q] <=
                                    (refill_way_q == LAST_WAY) ? 0 :
                                    refill_way_q + 1'b1;
                                response_error_q <= 1'b0;
                                response_valid_q <= 1'b1;
                                state_q <= STATE_RUN;
                            end else begin
                                refill_index_q <= refill_index_q + 1'b1;
                            end
                        end
                    end
                end

                STATE_ACCESS: begin
                    if (mem_ready_i) begin
                        response_data_q <= mem_rdata_i[
                            DATA_WIDTH-1:0];
                        response_error_q <= mem_error_i;
                        response_valid_q <= 1'b1;
                        state_q <= STATE_RUN;
                    end
                end

                default: begin
                    state_q <= STATE_RUN;
                end
            endcase
        end
    end

endmodule
