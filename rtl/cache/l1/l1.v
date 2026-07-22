`timescale 1ns/1ps

// Blocking, physically tagged, write-through L1 cache.  req_addr_i supplies
// the lookup set/beat while req_phys_addr_i supplies the tag and lower-memory
// address.  Supplying the same address on both ports gives an ordinary PIPT
// cache; L1I uses a page-offset virtual index with a physical tag (VIPT).
//
// The requester and memory sides use the OpenRV64 generic memory handshake:
// request fields remain stable while valid is asserted and ready completes the
// request.  Reads refill one DATA_WIDTH beat at a time.  Writes are always
// forwarded and use no-write-allocate; a successful write hit also updates the
// resident copy.
module openrv64_l1_cache #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer CACHE_BYTES = 8 * 1024,
    parameter integer LINE_BYTES = 64,
    parameter integer WAYS = 8,
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
    input  wire [DATA_WIDTH-1:0]     mem_rdata_i,
    input  wire                      mem_error_i
);

    localparam integer DATA_BYTES = DATA_WIDTH / 8;
    localparam integer WORDS_PER_LINE = LINE_BYTES / DATA_BYTES;
    localparam integer SETS = CACHE_BYTES / (LINE_BYTES * WAYS);
    localparam integer TOTAL_LINES = CACHE_BYTES / LINE_BYTES;
    localparam integer TOTAL_WORDS = CACHE_BYTES / DATA_BYTES;
    localparam integer LINE_OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - LINE_OFFSET_BITS - SET_BITS;
    localparam integer SET_INDEX_WIDTH = (SETS > 1) ? $clog2(SETS) : 1;
    localparam integer LINE_INDEX_WIDTH =
        (TOTAL_LINES > 1) ? $clog2(TOTAL_LINES) : 1;
    localparam integer WORD_INDEX_WIDTH =
        (TOTAL_WORDS > 1) ? $clog2(TOTAL_WORDS) : 1;
    localparam integer WAY_INDEX_WIDTH = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam integer BEAT_INDEX_WIDTH =
        (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_LOOKUP = 3'd1;
    localparam [2:0] STATE_REFILL = 3'd2;
    localparam [2:0] STATE_ACCESS = 3'd3;
    localparam [2:0] STATE_RESPONSE = 3'd4;
    localparam [2:0] STATE_HIT_RESPONSE = 3'd5;

    // Reserved coherence metadata.  valid_q remains authoritative until a
    // coherence controller is added; these encodings and the timestamp field
    // establish the per-line storage contract without pretending that the
    // current write-through cache can produce dirty data.
    localparam [1:0] MESI_INVALID = 2'b00;
    localparam [1:0] MESI_SHARED = 2'b01;
    localparam [1:0] MESI_EXCLUSIVE = 2'b10;
    localparam [1:0] MESI_MODIFIED = 2'b11;

    reg [2:0] state_q;

    // Flat arrays avoid turning the data RAM into a multi-dimensional bank of
    // flip-flops in synthesis frontends.  Tags are laid out set-major, then
    // way.  Data byte banks are declared separately below so byte write
    // strobes remain compatible with ordinary byte-wide SRAM inference.
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
    localparam [BEAT_INDEX_WIDTH-1:0] LAST_BEAT =
        BEAT_INDEX_WIDTH'(WORDS_PER_LINE - 1);

    reg [SET_INDEX_WIDTH-1:0] refill_set_q;
    reg [WAY_INDEX_WIDTH-1:0] refill_way_q;
    reg [LINE_INDEX_WIDTH-1:0] refill_line_q;
    reg [TAG_BITS-1:0]       refill_tag_q;
    reg [BEAT_INDEX_WIDTH-1:0] refill_beat_q;
    reg [BEAT_INDEX_WIDTH-1:0] request_beat_q;

    reg                      access_updates_line_q;
    reg [LINE_INDEX_WIDTH-1:0] access_line_q;
    reg [BEAT_INDEX_WIDTH-1:0] access_beat_q;

    reg [DATA_WIDTH-1:0] response_data_q;
    reg                  response_error_q;

    reg [SET_INDEX_WIDTH-1:0] lookup_set;
    reg [BEAT_INDEX_WIDTH-1:0] lookup_beat;
    reg [TAG_BITS-1:0] lookup_tag;
    reg lookup_hit;
    reg [WAY_INDEX_WIDTH-1:0] lookup_way;
    reg [WAY_INDEX_WIDTH-1:0] victim_way;
    reg invalid_way_found;
    reg aged_way_found;
    reg [SET_INDEX_WIDTH-1:0] invalidate_set;
    reg [TAG_BITS-1:0] invalidate_tag;
    reg [LINE_INDEX_WIDTH-1:0] lookup_line;
    reg [WORD_INDEX_WIDTH-1:0] lookup_word;
    reg [WORD_INDEX_WIDTH-1:0] refill_word;
    reg [WORD_INDEX_WIDTH-1:0] access_word;
    integer set_index;
    integer line_index;
    integer way_index;
    integer lookup_way_index;
    integer age_port;
    integer age_way;
    wire [DATA_WIDTH-1:0] lookup_data;

    wire refill_last_beat = (refill_beat_q == LAST_BEAT);
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

    function [WORD_INDEX_WIDTH-1:0] word_index_of;
        input [LINE_INDEX_WIDTH-1:0] line_value;
        input [BEAT_INDEX_WIDTH-1:0] beat_value;
        begin
            word_index_of = WORD_INDEX_WIDTH'(line_value) *
                            WORD_INDEX_WIDTH'(WORDS_PER_LINE) +
                            WORD_INDEX_WIDTH'(beat_value);
        end
    endfunction

    initial begin
        if ((DATA_WIDTH < 8) || ((DATA_WIDTH & (DATA_WIDTH - 1)) != 0))
            $fatal(1, "L1 DATA_WIDTH must be a power of two and at least 8");
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
        lookup_set = set_index_of(request_addr_q);
        lookup_beat = request_addr_q[$clog2(DATA_BYTES) +:
                                     BEAT_INDEX_WIDTH];
        if (WORDS_PER_LINE == 1)
            lookup_beat = 0;
        lookup_tag = request_phys_addr_q[ADDR_WIDTH-1:
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
        lookup_word = word_index_of(lookup_line, lookup_beat);

        invalidate_set = set_index_of(invalidate_addr_i);
        invalidate_tag = invalidate_addr_i[ADDR_WIDTH-1:
                                           LINE_OFFSET_BITS + SET_BITS];
        refill_word = word_index_of(refill_line_q, refill_beat_q);
        access_word = word_index_of(access_line_q, access_beat_q);
    end

    assign invalidate_ready_o = (state_q == STATE_IDLE);

    assign req_ready_o =
        (state_q == STATE_HIT_RESPONSE) || (state_q == STATE_RESPONSE);
    assign req_rdata_o = (state_q == STATE_HIT_RESPONSE) ?
                         lookup_data : response_data_q;
    assign req_error_o = (state_q == STATE_RESPONSE) && response_error_q;

    assign mem_valid_o = (state_q == STATE_REFILL) ||
                         (state_q == STATE_ACCESS);
    assign mem_write_o = (state_q == STATE_ACCESS) && request_write_q;
    assign mem_addr_o = (state_q == STATE_REFILL) ?
        refill_line_addr + (refill_beat_q * DATA_BYTES) :
        request_phys_addr_q;
    assign mem_wdata_o = (state_q == STATE_ACCESS) ?
                         request_wdata_q : {DATA_WIDTH{1'b0}};
    assign mem_wstrb_o = ((state_q == STATE_ACCESS) && request_write_q) ?
                         request_wstrb_q : {DATA_BYTES{1'b0}};

    genvar data_byte;
    generate
        for (data_byte = 0; data_byte < DATA_BYTES;
             data_byte = data_byte + 1) begin : g_data_bytes
            reg [7:0] data_q [0:TOTAL_WORDS-1];
            reg [7:0] read_data_q;

            assign lookup_data[8*data_byte +: 8] = read_data_q;

            always @(posedge clk_i) begin
                read_data_q <= data_q[lookup_word];

                if ((state_q == STATE_REFILL) && mem_ready_i &&
                    !mem_error_i) begin
                    data_q[refill_word] <=
                        mem_rdata_i[8*data_byte +: 8];
                end else if ((state_q == STATE_ACCESS) && mem_ready_i &&
                             request_write_q && !mem_error_i &&
                             access_updates_line_q &&
                             request_wstrb_q[data_byte]) begin
                    data_q[access_word] <=
                        request_wdata_q[8*data_byte +: 8];
                end
            end
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= STATE_IDLE;
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
            refill_beat_q <= 0;
            request_beat_q <= 0;
            access_updates_line_q <= 1'b0;
            access_line_q <= 0;
            access_beat_q <= 0;
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
                STATE_IDLE: begin
                    response_error_q <= 1'b0;
                    if (invalidate_valid_i) begin
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
                    end else if (req_valid_i) begin
                        request_write_q <= req_write_i;
                        request_cacheable_q <= req_cacheable_i;
                        request_prefetch_q <= req_prefetch_i;
                        request_aged_q <= req_aged_i;
                        request_addr_q <= req_addr_i;
                        request_phys_addr_q <= req_phys_addr_i;
                        request_wdata_q <= req_wdata_i;
                        request_wstrb_q <= req_wstrb_i;
                        state_q <= STATE_LOOKUP;
                    end
                end

                STATE_LOOKUP: begin
                    if (!request_cacheable_q) begin
                        access_updates_line_q <= 1'b0;
                        state_q <= STATE_ACCESS;
                    end else if (request_write_q) begin
                        access_updates_line_q <= lookup_hit;
                        access_line_q <= line_index_of(lookup_set,
                                                       lookup_way);
                        access_beat_q <= lookup_beat;
                        if (lookup_hit)
                            replace_q[lookup_set] <=
                                (lookup_way == LAST_WAY) ? 0 :
                                lookup_way + 1'b1;
                        if (lookup_hit)
                            aged_q[line_index_of(lookup_set,
                                                  lookup_way)] <= 1'b0;
                        state_q <= STATE_ACCESS;
                    end else if (lookup_hit) begin
                        replace_q[lookup_set] <=
                            (lookup_way == LAST_WAY) ? 0 :
                            lookup_way + 1'b1;
                        if (!request_prefetch_q)
                            aged_q[line_index_of(lookup_set,
                                                  lookup_way)] <= 1'b0;
                        else if (request_aged_q)
                            aged_q[line_index_of(lookup_set,
                                                  lookup_way)] <= 1'b1;
                        state_q <= STATE_HIT_RESPONSE;
                    end else begin
                        refill_set_q <= lookup_set;
                        refill_way_q <= victim_way;
                        refill_line_q <= line_index_of(lookup_set,
                                                       victim_way);
                        refill_tag_q <= lookup_tag;
                        refill_beat_q <= 0;
                        request_beat_q <= lookup_beat;
                        valid_q[line_index_of(lookup_set, victim_way)] <=
                            1'b0;
                        aged_q[line_index_of(lookup_set, victim_way)] <=
                            1'b0;
                        mesi_q[line_index_of(lookup_set, victim_way)] <=
                            MESI_INVALID;
                        dirty_timestamp_q[line_index_of(
                            lookup_set, victim_way)] <=
                            {DIRTY_TIMESTAMP_WIDTH{1'b0}};
                        state_q <= STATE_REFILL;
                    end
                end

                STATE_REFILL: begin
                    if (mem_ready_i) begin
                        if (mem_error_i) begin
                            response_data_q <= {DATA_WIDTH{1'b0}};
                            response_error_q <= 1'b1;
                            state_q <= STATE_RESPONSE;
                        end else begin
                            if (refill_beat_q == request_beat_q)
                                response_data_q <= mem_rdata_i;
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
                                state_q <= STATE_RESPONSE;
                            end else begin
                                refill_beat_q <= refill_beat_q + 1'b1;
                            end
                        end
                    end
                end

                STATE_ACCESS: begin
                    if (mem_ready_i) begin
                        response_data_q <= mem_rdata_i;
                        response_error_q <= mem_error_i;
                        state_q <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    state_q <= STATE_IDLE;
                end

                STATE_HIT_RESPONSE: begin
                    state_q <= STATE_IDLE;
                end

                default: state_q <= STATE_IDLE;
            endcase
        end
    end

endmodule
