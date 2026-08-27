# SPDX-License-Identifier: CERN-OHL-P-2.0

set scan_bits 960
set command_key 0x4f525636
set mask64 0xffffffffffffffff
set stub_words 2048
set stub_payload_bytes 0x3ff0
set stub_magic_word 2046
set stub_meta_word 2047
set stub_magic 0x4f52563653545542
set stub_abi_version 1
set uart_trace_words 2048
set uart_trace_bytes 16384
set retire_trace_depth 8192
set load_trace_depth 4096
set store_trace_depth 4096
set fetch_trace_depth 2048
set retire_trace_meta_base 16384
set load_trace_base 16386
set load_trace_meta_base 24578
set store_trace_base 24580
set store_trace_meta_base 32772
set fetch_trace_base 32774
set fetch_trace_meta_base 36870
set wave_trace_depth 1024
set wave_trace_base 36872
set wave_trace_meta_base 40968

proc usage {} {
    puts stderr "usage: fpga-jtag-snoop <status|wait-hit|reset|resume|resume-pc|resume-mem|arm-trace-window|resume-trace-window|walk-trace-windows|walk-pc-add-range|walk-pc-reg-ne|walk-pc-reg-eq|walk-pc-reg-value-ne|clear|arm-mem|arm-pc|arm-pc-delay|sample-pc-delay|arm-cycle|trigger-cycle|read-cache|read-snapshot|dump-snapshot|read-stub|write-stub|dump-stub|read-instr-trace|read-load-trace|read-store-trace|read-fetch-trace|read-wave-trace|wave-status|dump-wave-trace|dump-instr-trace|dump-load-trace|dump-store-trace|dump-fetch-trace|dump-retire-trace|load-stub|clear-stub|read-uart|read-uart-lane|dump-uart|follow-uart> ?arguments?"
    puts stderr "  status"
    puts stderr "  wait-hit ?timeout-seconds?"
    puts stderr "  reset"
    puts stderr "  resume"
    puts stderr "  resume-pc <pc> ?mask?"
    puts stderr "  resume-mem <address> ?mask? ?read|write|rw? ?scalar|ptw|all?"
    puts stderr "  arm-trace-window <retire-records>"
    puts stderr "  resume-trace-window <retire-records>"
    puts stderr "  walk-trace-windows <windows> <retire-records> ?timeout-seconds?"
    puts stderr "  walk-pc-add-range <pc> <start> <end> <max-hits> ?timeout-seconds?"
    puts stderr "  walk-pc-reg-ne <pc> <reg-a> <reg-b> <max-hits> ?timeout-seconds?"
    puts stderr "  walk-pc-reg-eq <pc> <reg> <value> <max-hits> ?timeout-seconds?"
    puts stderr "  walk-pc-reg-value-ne <pc> <reg> <value> <max-hits> ?timeout-seconds?"
    puts stderr "  clear"
    puts stderr "  arm-mem <address> ?mask? ?read|write|rw? ?scalar|ptw|all?"
    puts stderr "  arm-pc <pc> ?mask?"
    puts stderr "  arm-pc-delay <pc> <delay-cycles> ?mask?"
    puts stderr "  sample-pc-delay <pc> <delay-cycles> ?timeout-seconds?"
    puts stderr "  arm-cycle <absolute-core-cycle>"
    puts stderr "  trigger-cycle ?delta-cycles?"
    puts stderr "  read-cache <0..1023> ?0|1|2|3|tag?"
    puts stderr "  read-snapshot <0..511>"
    puts stderr "  dump-snapshot"
    puts stderr "  read-stub <0..2047>"
    puts stderr "  write-stub <0..2047> <64-bit-value>"
    puts stderr "  dump-stub ?start-word? ?word-count?"
    puts stderr "  dump-instr-trace ?max-records?"
    puts stderr "  dump-load-trace ?max-records?"
    puts stderr "  dump-store-trace ?max-records?"
    puts stderr "  dump-fetch-trace ?max-records?"
    puts stderr "  read-instr-trace RECORD"
    puts stderr "  read-load-trace RECORD"
    puts stderr "  read-store-trace RECORD"
    puts stderr "  read-fetch-trace RECORD"
    puts stderr "  read-wave-trace RECORD"
    puts stderr "  wave-status"
    puts stderr "  dump-wave-trace <output.csv> ?start-sample sample-count?"
    puts stderr "  dump-retire-trace ?max-records?  (legacy alias)"
    puts stderr "  load-stub <raw-binary> ?entry-byte-offset?"
    puts stderr "  clear-stub"
    puts stderr "  read-uart <0..2044, multiple of 4>"
    puts stderr "  read-uart-lane <0..2044, multiple of 4> <0..3>"
    puts stderr "  dump-uart <raw-output-file>"
    puts stderr "  follow-uart ?--from retained|new|absolute-byte? ?--until text? ?--timeout-seconds n? ?--poll-ms n?"
    exit 2
}

proc parse_int {text name} {
    if {[catch {expr {$text + 0}} value]} {
        error "$name is not an integer: $text"
    }
    if {$value < 0} {
        error "$name must be non-negative: $text"
    }
    return $value
}

proc bit {value index} {
    return [expr {($value >> $index) & 1}]
}

proc field {value low width} {
    return [expr {($value >> $low) & ((1 << $width) - 1)}]
}

proc yesno {value} {
    return [expr {$value ? "yes" : "no"}]
}

proc scan_user1 {tdi capture} {
    global scan_bits
    set sequence [jtag sequence]
    # XSDB's register-name table uses lowercase names. Uppercase USER1 is
    # treated as an ambiguous prefix rather than a case-insensitive match.
    $sequence irshift -register user1 -state IDLE
    if {$capture} {
        $sequence drshift -integer -capture -state IDLE $scan_bits $tdi
        set result [$sequence run -integer -single]
    } else {
        $sequence drshift -integer -state IDLE $scan_bits $tdi
        $sequence run
        set result 0
    }
    $sequence delete
    return $result
}

proc scan_user1_hex {} {
    global scan_bits
    set sequence [jtag sequence]
    $sequence irshift -register user1 -state IDLE
    $sequence drshift -tdi 0 -capture -state IDLE $scan_bits
    set result [$sequence run -hex -single]
    $sequence delete
    return [string tolower $result]
}

proc hex_byte {value byte_index} {
    set text [string range $value [expr {2 * $byte_index}] \
              [expr {2 * $byte_index + 1}]]
    return [expr 0x$text]
}

proc hex_u64_le {value byte_index} {
    set text ""
    for {set lane 7} {$lane >= 0} {incr lane -1} {
        append text [string range $value \
            [expr {2 * ($byte_index + $lane)}] \
            [expr {2 * ($byte_index + $lane) + 1}]]
    }
    return [expr 0x$text]
}

proc reverse_hex_bytes {value} {
    set result ""
    for {set index [expr {[string length $value] - 2}]} \
        {$index >= 0} {incr index -2} {
        append result [string range $value $index [expr {$index + 1}]]
    }
    return $result
}

proc write_command {args} {
    global command_key mask64
    array set options {
        arm 0 read 0 write 0 scalar 0 ptw 0 pc 0 cycle 0 reset 0
        trace_window 0
        resume 0 clear 0 cache_read 0 snapshot_read 0
        stub_read 0 stub_write 0 uart_read 0 retire_trace_read 0 wave_burst 0
        mem_addr 0 mem_mask 0 pc_addr 0 pc_mask 0 cycle_target 0
        cache_index 0 cache_word 0 cache_tag 0 snapshot_index 0
        stub_index 0 stub_wdata 0 uart_index 0
    }
    if {[llength $args] % 2} {
        error "write_command requires name/value pairs"
    }
    foreach {name value} $args {
        if {![info exists options($name)]} {
            error "unknown command field: $name"
        }
        set options($name) $value
    }

    set value $command_key
    foreach {name index} {
        arm 32 read 33 write 34 scalar 35 ptw 36 pc 37 cycle 38
        resume 39 clear 40 cache_read 41 snapshot_read 42
        stub_read 43 stub_write 44 uart_read 45 reset 46
        retire_trace_read 47 wave_burst 48
        trace_window 58
    } {
        if {$options($name)} {
            set value [expr {$value | (1 << $index)}]
        }
    }
    set value [expr {$value |
        (($options(mem_addr) & $mask64) << 64) |
        (($options(mem_mask) & $mask64) << 128) |
        (($options(pc_addr) & $mask64) << 192) |
        (($options(pc_mask) & $mask64) << 256) |
        (($options(cycle_target) & $mask64) << 320) |
        (($options(cache_index) & 0x3ff) << 400) |
        (($options(cache_word) & 0x3) << 410) |
        (($options(cache_tag) & 0x1) << 412) |
        (($options(snapshot_index) & 0x1ff) << 416) |
        (($options(stub_index) & 0xffff) << 416) |
        (($options(uart_index) & 0x7ff) << 416) |
        (($options(stub_wdata) & $mask64) << 448)}]
    scan_user1 $value 0
}

proc capture_status {} {
    global command_key
    set value [scan_user1 0 1]
    set signature [field $value 0 32]
    if {$signature != $command_key} {
        error [format "USER1 signature mismatch: got 0x%08x expected 0x%08x" \
               $signature $command_key]
    }
    return $value
}

proc wait_for_hit {timeout_seconds} {
    if {$timeout_seconds < 1} {
        error "wait-hit timeout must be positive"
    }
    set deadline [expr {[clock milliseconds] + 1000 * $timeout_seconds}]
    while {[clock milliseconds] < $deadline} {
        set value [capture_status]
        if {[bit $value 42]} {
            return $value
        }
        after 100
    }
    error [format "USER1 trigger did not hit within %d seconds" \
           $timeout_seconds]
}

proc wait_readback {source expected_index} {
    after 2
    set value [capture_status]
    validate_readback $value $source $expected_index
    return $value
}

proc validate_readback {value source expected_index} {
    global command_key
    if {[field $value 0 32] != $command_key} {
        error "USER1 signature mismatch during indexed read"
    }
    if {[field $value 816 2] != $source} {
        error "USER1 returned the wrong indexed-read source"
    }
    set observed_index [expr {[field $value 821 11] |
                              ([field $value 712 5] << 11)}]
    if {$observed_index != $expected_index} {
        error [format "USER1 indexed-read mismatch: got %d expected %d" \
               $observed_index $expected_index]
    }
    if {[bit $value 818] != [bit $value 819]} {
        error "USER1 indexed read did not acknowledge"
    }
}

proc read_snapshot_word {index} {
    write_command snapshot_read 1 snapshot_index $index
    return [field [wait_readback 1 $index] 832 64]
}

proc read_snapshot_word_stable {index} {
    # The requested index crosses into the core clock domain separately from
    # the BRAM response.  A single acknowledged USER1 read can therefore see
    # the prior word during the transition.  Require two identical reads when
    # snapshot freshness, rather than a diagnostic dump, controls execution.
    for {set attempt 0} {$attempt < 8} {incr attempt} {
        set first [read_snapshot_word $index]
        set second [read_snapshot_word $index]
        if {$first == $second} {
            return $first
        }
        after 2
    }
    error [format "snapshot word %d did not produce a stable read" $index]
}

proc read_stub_word {index} {
    write_command stub_read 1 stub_index $index
    return [field [wait_readback 2 $index] 832 64]
}

proc read_retire_trace_word_raw {index} {
    write_command stub_read 1 retire_trace_read 1 stub_index $index
    return [field [wait_readback 2 $index] 832 64]
}

proc read_retire_trace_word {index} {
    # Trace storage is synchronous BRAM.  The USER1 acknowledgement can reach
    # the host while the first result still reflects the preceding BRAM
    # address, especially when consecutive requests select different words.
    # Frozen trace data is immutable, so require a repeated value before using
    # it.  Equal adjacent records are harmless: the value is still correct.
    for {set attempt 0} {$attempt < 8} {incr attempt} {
        set first [read_retire_trace_word_raw $index]
        set second [read_retire_trace_word_raw $index]
        if {$first == $second} {
            return $first
        }
        after 2
    }
    error [format "trace word %d did not produce a stable read" $index]
}

proc read_load_trace_word {record word} {
    global load_trace_base
    return [read_retire_trace_word \
        [expr {$load_trace_base + 2 * $record + $word}]]
}

proc read_store_trace_word {record word} {
    global store_trace_base
    return [read_retire_trace_word \
        [expr {$store_trace_base + 2 * $record + $word}]]
}

proc read_fetch_trace_word {record word} {
    global fetch_trace_base
    return [read_retire_trace_word \
        [expr {$fetch_trace_base + 2 * $record + $word}]]
}

proc read_wave_trace_raw {record} {
    write_command stub_read 1 retire_trace_read 1 wave_burst 1 \
        stub_index $record
    set status [wait_readback 2 $record]
    return [list \
        [field $status 384 64] [field $status 448 64] \
        [field $status 512 64] [field $status 576 64]]
}

proc read_wave_trace {record} {
    # The four banks are synchronous BRAMs in the core clock domain.  Require
    # two identical burst reads so the first cross-domain sample cannot expose
    # the preceding address.
    for {set attempt 0} {$attempt < 8} {incr attempt} {
        set first [read_wave_trace_raw $record]
        set second [read_wave_trace_raw $record]
        if {$first eq $second} {
            return $first
        }
        after 2
    }
    error [format "wave trace record %d did not produce a stable read" $record]
}

proc read_wave_status {} {
    global wave_trace_depth wave_trace_meta_base
    set total [read_retire_trace_word $wave_trace_meta_base]
    set meta [read_retire_trace_word [expr {$wave_trace_meta_base + 1}]]
    set write_index [field $meta 0 10]
    set trigger_index [field $meta 10 10]
    set triggered [bit $meta 20]
    set frozen [bit $meta 21]
    set post_count [field $meta 22 10]
    set retained [expr {$total < $wave_trace_depth ?
                        $total : $wave_trace_depth}]
    return [list $total $retained $write_index $trigger_index \
                 $triggered $frozen $post_count]
}

proc print_wave_status {} {
    lassign [read_wave_status] total retained write_index trigger_index \
        triggered frozen post_count
    puts [format "wave_trace total=%d retained=%d write_index=%d trigger_index=%d triggered=%s frozen=%s post_count=%d" \
          $total $retained $write_index $trigger_index \
          [yesno $triggered] [yesno $frozen] $post_count]
}

proc dump_wave_trace_csv {path {start_sample 0} {sample_count -1}} {
    global wave_trace_depth
    lassign [read_wave_status] total retained write_index trigger_index \
        triggered frozen post_count
    if {!$triggered} {
        error "wave trace has not triggered"
    }
    if {!$frozen} {
        error [format "wave trace is still capturing post-trigger samples (%d)" \
               $post_count]
    }
    set oldest [expr {$total >= $wave_trace_depth ? $write_index : 0}]
    set trigger_sample [expr {($trigger_index - $oldest) &
                              ($wave_trace_depth - 1)}]
    if {$start_sample < 0 || $start_sample >= $retained} {
        error [format "wave trace start sample must be in 0..%d" \
               [expr {$retained - 1}]]
    }
    if {$sample_count < 0} {
        set sample_count [expr {$retained - $start_sample}]
    }
    if {$sample_count < 1 || $start_sample + $sample_count > $retained} {
        error [format "wave trace range start=%d count=%d exceeds %d retained samples" \
               $start_sample $sample_count $retained]
    }
    set end_sample [expr {$start_sample + $sample_count}]

    set output [open $path w]
    puts $output "sample,physical,relative,pc,instr,fetch_valid,fetch_meta,fetch_data,mem_addr,mem_valid,mem_ready,mem_write,trace_valid,trace_stall,trace_flush,trace_advance,trace_events"
    for {set sample $start_sample} {$sample < $end_sample} {incr sample} {
        set physical [expr {($oldest + $sample) & ($wave_trace_depth - 1)}]
        lassign [read_wave_trace $physical] word0 word1 word2 word3
        puts $output [format "%d,%d,%d,0x%08x,0x%08x,%d,0x%016x,0x%016x,0x%08x,%d,%d,%d,0x%02x,0x%02x,0x%02x,0x%02x,0x%02x" \
            $sample $physical [expr {$sample - $trigger_sample}] \
            [field $word0 32 32] [field $word0 0 32] \
            [bit $word3 32] $word1 $word2 [field $word3 0 32] \
            [bit $word3 33] [bit $word3 34] [bit $word3 35] \
            [field $word3 36 5] [field $word3 41 5] \
            [field $word3 46 5] [field $word3 51 5] \
            [field $word3 56 8]]
        set range_progress [expr {$sample - $start_sample + 1}]
        if {($range_progress & 0xff) == 0} {
            puts [format "read %d/%d waveform samples (range start=%d)" \
                  $range_progress $sample_count $start_sample]
        }
    }
    close $output
    puts [format "OPENRV64 FPGA WAVE TRACE PASS path=%s samples=%d start=%d trigger_sample=%d pre=%d post=%d" \
          [file normalize $path] $sample_count $start_sample $trigger_sample \
          $trigger_sample [expr {$retained - $trigger_sample - 1}]]
}

proc write_stub_word {index value} {
    write_command stub_write 1 stub_index $index stub_wdata $value
    wait_readback 2 $index
}

proc print_retire_record {sequence} {
    global retire_trace_depth
    set index [expr {$sequence & ($retire_trace_depth - 1)}]
    set record [read_retire_trace_word [expr {2 * $index}]]
    set wdata [read_retire_trace_word [expr {2 * $index + 1}]]
    set stored_pc [field $record 32 32]
    set instr [field $record 0 32]
    set pc_low [expr {$stored_pc & 0xfffffffc}]
    set predicted [expr {($stored_pc >> 1) & 1}]
    set taken [expr {$stored_pc & 1}]
    set rd [field $instr 7 5]
    puts [format "RETIRE seq=%d slot=%04x pc_low=0x%08x instr=0x%08x rd=x%d wdata=0x%016x pred=%d taken=%d" \
          $sequence $index $pc_low $instr $rd $wdata $predicted $taken]
}

proc print_load_record {sequence} {
    global load_trace_depth protocol_version
    set index [expr {$sequence & ($load_trace_depth - 1)}]
    set meta [read_load_trace_word $index 0]
    set data [read_load_trace_word $index 1]
    if {$protocol_version >= 21} {
        puts [format "LOAD seq=%d slot=%04x vaddr_low=0x%08x paddr_low=0x%08x data=0x%016x" \
              $sequence $index [field $meta 0 32] [field $meta 32 32] \
              $data]
    } else {
        set addr_low [field $meta 0 32]
        set rd [field $meta 32 5]
        set pc_low [expr {[field $meta 37 24] << 2}]
        puts [format "LOAD seq=%d slot=%04x pc_low=0x%08x addr_low=0x%08x rd=x%d data=0x%016x" \
              $sequence $index $pc_low $addr_low $rd $data]
    }
}

proc print_store_record {sequence} {
    global store_trace_depth protocol_version
    set index [expr {$sequence & ($store_trace_depth - 1)}]
    set meta [read_store_trace_word $index 0]
    set data [read_store_trace_word $index 1]
    if {$protocol_version >= 21} {
        puts [format "STORE seq=%d slot=%04x vaddr_low=0x%08x paddr_low=0x%08x data=0x%016x" \
              $sequence $index [field $meta 0 32] [field $meta 32 32] \
              $data]
    } else {
        set addr_low [field $meta 0 32]
        set wstrb [field $meta 32 8]
        set pc_low [expr {[field $meta 40 24] << 2}]
        puts [format "STORE seq=%d slot=%04x pc_low=0x%08x addr_low=0x%08x wstrb=0x%02x data=0x%016x" \
              $sequence $index $pc_low $addr_low $wstrb $data]
    }
}

proc print_fetch_record {sequence} {
    global fetch_trace_depth
    set index [expr {$sequence & ($fetch_trace_depth - 1)}]
    set pc [read_fetch_trace_word $index 0]
    set data [read_fetch_trace_word $index 1]
    if {[field $pc 48 16] == 0xb057} {
        set state [field $pc 46 2]
        set owner_fetch [bit $pc 45]
        set cancelled [bit $pc 44]
        set vaddr [field $pc 0 44]
        set state_name [lindex {idle translate access tlb-result} $state]
        puts [format "FETCH_CANCEL seq=%d slot=%04x state=%d/%s owner_fetch=%d cancelled=%d gen_vaddr=0x%011x frontend_addr=0x%016x" \
              $sequence $index $state $state_name $owner_fetch $cancelled \
              $vaddr $data]
    } elseif {[field $pc 48 16] == 0xb055} {
        set stage [field $pc 44 2]
        set cancel_now [bit $pc 47]
        set cancelled [bit $pc 46]
        set addr [field $pc 0 44]
        set stage_name [lindex {capture response completion resume} $stage]
        set addr_name [expr {$stage == 3 ? "vaddr" : "paddr"}]
        puts [format "FETCH_PIPE seq=%d slot=%04x stage=%d/%s %s=0x%011x cancel_now=%d cancelled=%d data=0x%016x" \
              $sequence $index $stage $stage_name $addr_name $addr \
              $cancel_now $cancelled $data]
    } else {
        puts [format "FETCH seq=%d slot=%04x pc=0x%016x data=0x%016x" \
              $sequence $index $pc $data]
    }
}

proc read_trace_totals {} {
    global retire_trace_meta_base load_trace_meta_base store_trace_meta_base
    return [list \
        [read_retire_trace_word $retire_trace_meta_base] \
        [read_retire_trace_word $load_trace_meta_base] \
        [read_retire_trace_word $store_trace_meta_base]]
}

proc read_uart_burst {index} {
    if {($index & 3) != 0} {
        error "UART burst index must be a multiple of four words"
    }
    # One request triggers four sequential BRAM reads. Capture the result as a
    # raw hexadecimal bit vector: XSDB integer expressions are only 64 bits and
    # silently truncate the otherwise valid 256-bit UART field.
    write_command uart_read 1 uart_index $index
    after 2
    set value [scan_user1_hex]
    if {[string length $value] != 240} {
        error [format "USER1 hex capture length mismatch: got %d expected 240" \
               [string length $value]]
    }
    if {[string range $value 0 7] ne "3656524f"} {
        error "USER1 signature mismatch during UART burst read"
    }
    if {[hex_byte $value 4] < 14} {
        error "32-byte UART reads require USER1 protocol version 14"
    }
    set source_control [expr {[hex_byte $value 102] |
                              ([hex_byte $value 103] << 8)}]
    if {($source_control & 3) != 3} {
        error "USER1 returned the wrong UART readback source"
    }
    if {(($source_control >> 2) & 1) != (($source_control >> 3) & 1)} {
        error "USER1 UART read did not acknowledge"
    }
    if {(($source_control >> 5) & 0x7ff) != $index} {
        error "USER1 UART read returned the wrong index"
    }
    return $value
}

proc read_uart_lane {index lane} {
    if {($index & 3) != 0} {
        error "UART burst index must be a multiple of four words"
    }
    if {$lane < 0 || $lane > 3} {
        error "UART lane must be in the range 0..3"
    }
    write_command uart_read 1 uart_index $index cache_word $lane
    set value [wait_readback 3 $index]
    if {[field $value 32 8] < 14} {
        error "UART lane reads require USER1 protocol version 14"
    }
    return $value
}

proc dump_uart_image {path} {
    global uart_trace_words uart_trace_bytes

    set initial [read_uart_burst 0]
    set total [hex_u64_le $initial 112]
    set valid [expr {min($total, $uart_trace_bytes)}]
    set oldest [expr {$total - $valid}]
    array set bursts {}
    set bursts(0) [string range $initial 96 159]
    set bursts_read 1

    if {$valid != 0} {
        set first_absolute_burst [expr {$oldest >> 5}]
        set last_absolute_burst [expr {($total - 1) >> 5}]
        for {set absolute_burst $first_absolute_burst} \
            {$absolute_burst <= $last_absolute_burst} \
            {incr absolute_burst} {
            set index [expr {(4 * $absolute_burst) &
                             ($uart_trace_words - 1)}]
            if {[info exists bursts($index)]} {
                continue
            }
            set result [read_uart_burst $index]
            set observed_total [hex_u64_le $result 112]
            if {$observed_total != $total} {
                error [format "UART trace changed during dump: start=%d observed=%d; stop console output or enter the debug interrupt and retry" \
                       $total $observed_total]
            }
            set bursts($index) [string range $result 96 159]
            incr bursts_read
            if {($bursts_read & 0x3f) == 0} {
                puts [format "read %d 32-byte bursts from UART trace" \
                      $bursts_read]
            }
        }
    }

    set final [read_uart_burst 0]
    set final_total [hex_u64_le $final 112]
    if {$final_total != $total} {
        error [format "UART trace changed during dump: start=%d end=%d; stop console output or enter the debug interrupt and retry" \
               $total $final_total]
    }

    set octets {}
    for {set absolute_byte $oldest} {$absolute_byte < $total} \
        {incr absolute_byte} {
        set physical_byte [expr {$absolute_byte & ($uart_trace_bytes - 1)}]
        set index [expr {(($physical_byte >> 5) << 2) &
                         ($uart_trace_words - 1)}]
        set byte [hex_byte $bursts($index) [expr {$physical_byte & 31}]]
        lappend octets [expr {$byte >= 128 ? $byte - 256 : $byte}]
    }

    set output [open $path wb]
    fconfigure $output -translation binary -encoding binary
    puts -nonewline $output [binary format c* $octets]
    close $output
    puts [format "UART trace dumped path=%s total_bytes=%d retained_bytes=%d oldest_byte=%d" \
          [file normalize $path] $total $valid $oldest]
}

proc follow_uart {start_mode until_text timeout_seconds poll_ms} {
    global uart_trace_words uart_trace_bytes

    if {$timeout_seconds < 0} {
        error "--timeout-seconds must be non-negative"
    }
    if {$poll_ms < 1 || $poll_ms > 60000} {
        error "--poll-ms must be in the range 1..60000"
    }

    set initial [read_uart_burst 0]
    set initial_total [hex_u64_le $initial 112]
    set initial_oldest [expr {max(0, $initial_total - $uart_trace_bytes)}]
    if {$start_mode eq "new"} {
        set next_byte $initial_total
    } elseif {$start_mode eq "retained"} {
        set next_byte $initial_oldest
    } else {
        set next_byte [parse_int $start_mode start-byte]
        if {$next_byte > $initial_total} {
            error [format \
                "start byte %d is beyond current producer count %d" \
                $next_byte $initial_total]
        }
    }
    set deadline [expr {$timeout_seconds == 0 ? 0 :
        [clock milliseconds] + 1000 * $timeout_seconds}]
    set match_window ""
    set match_keep [expr {max(256, [string length $until_text])}]
    set dropped_bytes 0

    puts stderr [format \
        "UART JTAG follow start counter=%d retained=%d next=%d mode=%s" \
        $initial_total [expr {$initial_total - $initial_oldest}] \
        $next_byte $start_mode]
    fconfigure stdout -translation binary -encoding binary -buffering none

    while {1} {
        if {$deadline != 0 && [clock milliseconds] >= $deadline} {
            error [format \
                "UART JTAG follow timed out after %d seconds at byte %d" \
                $timeout_seconds $next_byte]
        }

        set index [expr {(($next_byte >> 5) << 2) &
                         ($uart_trace_words - 1)}]
        set result [read_uart_burst $index]
        set observed_total [hex_u64_le $result 112]

        if {$observed_total < $next_byte} {
            puts stderr [format \
                "\nUART JTAG follow: counter reset from at least %d to %d" \
                $next_byte $observed_total]
            set next_byte [expr {$start_mode eq "new" ?
                $observed_total : max(0, $observed_total -
                                      $uart_trace_bytes)}]
            set match_window ""
            continue
        }

        set oldest_available [expr {max(0, $observed_total -
                                       $uart_trace_bytes)}]
        if {$next_byte < $oldest_available} {
            set lost [expr {$oldest_available - $next_byte}]
            incr dropped_bytes $lost
            puts stderr [format \
                "\nUART JTAG follow: overrun, dropped %d bytes (total dropped %d)" \
                $lost $dropped_bytes]
            set next_byte $oldest_available
            set match_window ""
            continue
        }

        if {$next_byte == $observed_total} {
            after $poll_ms
            continue
        }

        set end_byte [expr {min($observed_total,
                                (($next_byte >> 5) + 1) << 5)}]
        set chunk ""
        for {set absolute_byte $next_byte} {$absolute_byte < $end_byte} \
            {incr absolute_byte} {
            set lane [expr {$absolute_byte & 31}]
            set byte [hex_byte $result [expr {48 + $lane}]]
            append chunk [binary format c [expr {$byte >= 128 ?
                                                  $byte - 256 : $byte}]]
        }
        puts -nonewline stdout $chunk
        set next_byte $end_byte

        if {$until_text ne ""} {
            append match_window $chunk
            if {[string first $until_text $match_window] >= 0} {
                puts stderr [format \
                    "\nOPENRV64 FPGA JTAG UART FOLLOW PASS cursor=%d producer=%d dropped=%d marker=%s" \
                    $next_byte $observed_total $dropped_bytes $until_text]
                return
            }
            if {[string length $match_window] > 2 * $match_keep} {
                set match_window [string range $match_window end-$match_keep end]
            }
        }
    }
}

proc load_stub_image {path entry_offset} {
    global stub_payload_bytes stub_magic_word stub_meta_word
    global stub_magic stub_abi_version

    set input [open $path rb]
    fconfigure $input -translation binary -encoding binary
    set image [read $input]
    close $input

    set byte_count [string length $image]
    if {$byte_count == 0 || $byte_count > $stub_payload_bytes} {
        error [format "stub image must contain 1..%d bytes, got %d" \
               $stub_payload_bytes $byte_count]
    }
    if {$entry_offset < 0 || $entry_offset >= $byte_count ||
        ($entry_offset & 3) != 0} {
        error "entry offset must be 4-byte aligned and inside the image"
    }

    # Invalidate first. Metadata is written after the payload, and magic is
    # the final commit operation observed by the OpenSBI handler.
    write_stub_word $stub_magic_word 0
    set word_count [expr {($byte_count + 7) / 8}]
    for {set word_index 0} {$word_index < $word_count} {incr word_index} {
        set first [expr {$word_index * 8}]
        set last [expr {min($first + 7, $byte_count - 1)}]
        binary scan [string range $image $first $last] c* octets
        set word 0
        set lane 0
        foreach octet $octets {
            set word [expr {$word | (($octet & 0xff) << (8 * $lane))}]
            incr lane
        }
        write_stub_word $word_index $word
        if {($word_index & 0xff) == 0xff} {
            puts [format "uploaded %d/%d words" \
                  [expr {$word_index + 1}] $word_count]
        }
    }

    set metadata [expr {($byte_count << 32) |
                        ($stub_abi_version << 16) | $entry_offset}]
    write_stub_word $stub_meta_word $metadata
    write_stub_word $stub_magic_word $stub_magic
    set observed_metadata [read_stub_word $stub_meta_word]
    set observed_magic [read_stub_word $stub_magic_word]
    if {$observed_metadata != $metadata || $observed_magic != $stub_magic} {
        error [format "stub descriptor verification failed: metadata=0x%016x magic=0x%016x" \
               $observed_metadata $observed_magic]
    }
    puts [format "stub committed path=%s bytes=%d words=%d entry=0x%x abi=%d" \
          [file normalize $path] $byte_count $word_count $entry_offset \
          $stub_abi_version]
}

proc print_status {value} {
    set signature [field $value 0 32]
    set hit_valid [bit $value 42]
    set reasons {}
    foreach {label index} {scalar 43 ptw 44 pc 45 cycle 46 trace 60} {
        if {[bit $value $index]} {
            lappend reasons $label
        }
    }
    if {[llength $reasons] == 0} {
        set reason none
    } else {
        set reason [join $reasons ,]
    }

    puts [format "signature=0x%08x version=%d" \
          $signature [field $value 32 8]]
    puts [format "armed=%s resume_pending=%s hit_valid=%s reason=%s" \
          [yesno [bit $value 40]] [yesno [bit $value 41]] \
          [yesno $hit_valid] $reason]
    puts [format "match read=%s write=%s scalar=%s ptw=%s pc=%s cycle=%s" \
          [yesno [bit $value 49]] [yesno [bit $value 50]] \
          [yesno [bit $value 51]] [yesno [bit $value 52]] \
          [yesno [bit $value 53]] [yesno [bit $value 54]]]
    puts [format "pc_delay_started=%s trace_window=%s" \
          [yesno [bit $value 59]] [yesno [bit $value 58]]]
    puts [format "mem_target=0x%016x mem_mask=0x%016x" \
          [field $value 64 64] [field $value 128 64]]
    puts [format "pc_target=0x%016x pc_mask=0x%016x" \
          [field $value 192 64] [field $value 256 64]]
    puts [format "cycle_target=%d live_cycle=%d" \
          [field $value 320 64] [field $value 720 64]]
    if {$hit_valid} {
        puts [format "hit_cycle=%d hit_pc=0x%016x hit_instr=0x%08x" \
              [field $value 384 64] [field $value 448 64] \
              [field $value 784 32]]
        puts [format "hit_addr=0x%016x hit_write=%s hit_error=%s" \
              [field $value 512 64] [yesno [bit $value 47]] \
              [yesno [bit $value 48]]]
        if {[bit $value 45]} {
            if {[field $value 32 8] >= 18} {
                puts [format "hit_retire_write=%s hit_retire_rd=%d hit_retire_wdata=0x%016x" \
                      [yesno [bit $value 47]] [field $value 512 5] \
                      [field $value 576 64]]
            } else {
                puts [format "hit_rs1_data=0x%016x hit_rs2_data=0x%016x" \
                      [field $value 576 64] [field $value 640 64]]
            }
        } else {
            puts [format "hit_rdata=0x%016x hit_wdata=0x%016x hit_wstrb=0x%02x" \
                  [field $value 576 64] [field $value 640 64] \
                  [field $value 704 8]]
        }
        if {[bit $value 46] && [bit $value 53] && [bit $value 54]} {
            puts [format "hit_delay_start=%d hit_delay_cycles=%d" \
                  [expr {[field $value 384 64] - [field $value 320 64]}] \
                  [field $value 320 64]]
        }
    }

    set source_id [field $value 816 2]
    switch -- $source_id {
        0 { set source cache }
        1 { set source snapshot }
        2 { set source stub }
        3 { set source uart }
    }
    set index [expr {[field $value 821 11] |
                     ([field $value 712 5] << 11)}]
    puts [format "readback source=%s request_toggle=%d ack_toggle=%d index=%d data=0x%016x" \
          $source [bit $value 818] [bit $value 819] $index \
          [field $value 832 64]]
    if {$source eq "cache"} {
        set selector [expr {[bit $value 55] ? "tag" :
                           [format "word%d" [field $value 56 2]]}]
        puts [format "cache valid=%s selector=%s" \
              [yesno [bit $value 820]] $selector]
        if {$selector eq "tag"} {
            set tag [field $value 832 64]
            set line_addr [expr {0x80000000 + ($tag << 15) +
                                 ($index << 5)}]
            puts [format "cache_line_addr=0x%016x" $line_addr]
        }
    } elseif {$source eq "uart"} {
        set total [field $value 896 64]
        puts [format "uart_total_bytes=%d uart_retained_bytes=%d uart_next_byte=0x%04x" \
              $total [expr {min($total, 16384)}] [expr {$total & 0x3fff}]]
    }
}

if {$argc < 1} {
    usage
}

set server_url [expr {[info exists ::env(FPGA_HW_SERVER_URL)] ?
    $::env(FPGA_HW_SERVER_URL) : "tcp:10.1.6.21:3121"}]
connect -url $server_url
jtag targets -set -filter {name =~ "*xc7a100t*"}
set protocol_version [field [capture_status] 32 8]
set jtag_frequency [expr {[info exists ::env(FPGA_JTAG_FREQUENCY)] ?
    $::env(FPGA_JTAG_FREQUENCY) : 1000000}]
if {$jtag_frequency <= 0 || $jtag_frequency > 10000000} {
    error "FPGA_JTAG_FREQUENCY must be in the range 1..10000000 Hz"
}
jtag frequency $jtag_frequency

set command [lindex $argv 0]
set status_value ""
switch -- $command {
    status {
        if {$argc != 1} { usage }
        set status_value [capture_status]
    }
    wait-hit {
        if {$argc > 2} { usage }
        set timeout [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] timeout] : 300}]
        set status_value [wait_for_hit $timeout]
    }
    reset {
        if {$argc != 1} { usage }
        write_command reset 1
        puts "OPENRV64 FPGA JTAG RESET SENT"
    }
    resume {
        if {$argc != 1} { usage }
        write_command resume 1
        after 20
        set status_value [capture_status]
    }
    resume-pc {
        if {$argc < 2 || $argc > 3} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set mask [expr {$argc == 3 ?
            [parse_int [lindex $argv 2] mask] : 0xfffffffffffffffc}]
        # Arm and resume in one Update-DR. A plain resume deliberately clears
        # cfg_armed_jtag_q, so two separate commands cannot chain a breakpoint
        # after the M-mode snapshot handler releases the hart.
        write_command arm 1 pc 1 resume 1 \
            pc_addr $address pc_mask $mask
        after 20
        set status_value [capture_status]
    }
    resume-mem {
        if {$argc < 2 || $argc > 5} { usage }
        set address [parse_int [lindex $argv 1] address]
        set mask [expr {$argc >= 3 ?
            [parse_int [lindex $argv 2] mask] : 0xfffffffffffffff8}]
        set access [expr {$argc >= 4 ? [lindex $argv 3] : "read"}]
        set source [expr {$argc >= 5 ? [lindex $argv 4] : "all"}]
        set match_read [expr {$access eq "read" || $access eq "rw"}]
        set match_write [expr {$access eq "write" || $access eq "rw"}]
        if {!$match_read && !$match_write} {
            error "access must be read, write, or rw"
        }
        set match_scalar [expr {$source eq "scalar" || $source eq "all"}]
        set match_ptw [expr {$source eq "ptw" || $source eq "all"}]
        if {!$match_scalar && !$match_ptw} {
            error "source must be scalar, ptw, or all"
        }
        # Preserve the new memory trigger across release in one Update-DR.
        write_command arm 1 read $match_read write $match_write \
            scalar $match_scalar ptw $match_ptw clear 1 resume 1 \
            mem_addr $address mem_mask $mask
        after 20
        set status_value [capture_status]
    }
    arm-trace-window {
        if {$argc != 2} { usage }
        set records [parse_int [lindex $argv 1] retire-records]
        if {$records < 1 || $records > 4000} {
            error "trace window must contain 1..4000 retire records"
        }
        set before [capture_status]
        if {[field $before 32 8] < 20} {
            error "trace record watermarks require USER1 version 20 or newer"
        }
        write_command arm 1 trace_window 1 clear 1 \
            cycle_target $records
        after 20
        set status_value [capture_status]
    }
    resume-trace-window {
        if {$argc != 2} { usage }
        set records [parse_int [lindex $argv 1] retire-records]
        if {$records < 1 || $records > 4000} {
            error "trace window must contain 1..4000 retire records"
        }
        set before [capture_status]
        if {[field $before 32 8] < 20} {
            error "trace record watermarks require USER1 version 20 or newer"
        }
        write_command arm 1 trace_window 1 clear 1 resume 1 \
            cycle_target $records
        after 20
        set status_value [capture_status]
    }
    walk-trace-windows {
        if {$argc < 3 || $argc > 4} { usage }
        set windows [parse_int [lindex $argv 1] windows]
        set records [parse_int [lindex $argv 2] retire-records]
        set timeout [expr {$argc == 4 ?
            [parse_int [lindex $argv 3] timeout] : 300}]
        if {$windows < 1} {
            error "trace window count must be positive"
        }
        if {$records < 1 || $records > 4000} {
            error "trace window must contain 1..4000 retire records"
        }
        set status_value [capture_status]
        if {[field $status_value 32 8] < 20} {
            error "trace record watermarks require USER1 version 20 or newer"
        }
        if {![bit $status_value 42]} {
            error "walk-trace-windows must start from a frozen debug hit"
        }
        lassign [read_trace_totals] retire_start load_start store_start
        puts [format "TRACE_WALK_START windows=%d records=%d retire=%d load=%d store=%d" \
              $windows $records $retire_start $load_start $store_start]
        for {set window 0} {$window < $windows} {incr window} {
            write_command arm 1 trace_window 1 clear 1 resume 1 \
                cycle_target $records
            set status_value [wait_for_hit $timeout]
            if {![bit $status_value 60]} {
                error [format "window %d stopped for a non-trace trigger" \
                       $window]
            }
            lassign [read_trace_totals] retire_end load_end store_end
            set retire_delta [expr {$retire_end - $retire_start}]
            set load_delta [expr {$load_end - $load_start}]
            set store_delta [expr {$store_end - $store_start}]
            if {$retire_delta < $records || $retire_delta > 8192 ||
                $load_delta < 0 || $load_delta > 4096 ||
                $store_delta < 0 || $store_delta > 4096} {
                error [format "window %d trace discontinuity retire=%d load=%d store=%d" \
                       $window $retire_delta $load_delta $store_delta]
            }
            puts [format "TRACE_WINDOW_BEGIN window=%d hit_cycle=%d retire=%d..%d load=%d..%d store=%d..%d" \
                  $window [field $status_value 384 64] \
                  $retire_start $retire_end $load_start $load_end \
                  $store_start $store_end]
            for {set sequence $retire_start} {$sequence < $retire_end} \
                {incr sequence} {
                print_retire_record $sequence
            }
            for {set sequence $load_start} {$sequence < $load_end} \
                {incr sequence} {
                print_load_record $sequence
            }
            for {set sequence $store_start} {$sequence < $store_end} \
                {incr sequence} {
                print_store_record $sequence
            }
            puts [format "TRACE_WINDOW_END window=%d retire_delta=%d load_delta=%d store_delta=%d" \
                  $window $retire_delta $load_delta $store_delta]
            set retire_start $retire_end
            set load_start $load_end
            set store_start $store_end
        }
        puts [format "TRACE_WALK_PASS windows=%d retire=%d load=%d store=%d" \
              $windows $retire_start $load_start $store_start]
    }
    walk-pc-add-range {
        if {$argc < 5 || $argc > 6} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set expected [parse_int [lindex $argv 2] start]
        set range_end [parse_int [lindex $argv 3] end]
        set max_hits [parse_int [lindex $argv 4] max-hits]
        set timeout [expr {$argc == 6 ?
            [parse_int [lindex $argv 5] timeout] : 300}]
        if {$expected >= $range_end} {
            error "walk-pc-add-range start must be below end"
        }
        if {$max_hits < 1} {
            error "walk-pc-add-range max-hits must be positive"
        }

        # Consume the existing hit first. Each subsequent Update-DR both
        # releases the OpenSBI debug handler and rearms the same WB PC, so the
        # exact add operands form a lossless address/step chain.
        set status_value [capture_status]
        set complete 0
        for {set hit 1} {$hit <= $max_hits} {incr hit} {
            if {![bit $status_value 42] || ![bit $status_value 45] ||
                [field $status_value 448 64] != $address} {
                error [format "hit %d is not the requested PC 0x%016x" \
                       $hit $address]
            }
            if {$protocol_version >= 18} {
                # USER1 v18 replaced the retired instruction's source
                # operands in the status payload with destination writeback
                # data.  The M-mode snapshot still holds the architectural
                # a2/a3 mapping operands at words 32/33.
                set current [read_snapshot_word_stable 32]
                set step [read_snapshot_word_stable 33]
            } else {
                set current [field $status_value 576 64]
                set step [field $status_value 640 64]
            }
            set next [expr {$current + $step}]
            puts [format "map_hit=%d current=0x%016x step=0x%016x next=0x%016x" \
                  $hit $current $step $next]
            if {$current != $expected} {
                error [format "MAP RANGE DISCONTINUITY hit=%d expected=0x%016x observed=0x%016x" \
                       $hit $expected $current]
            }
            if {($current & 0xfff) != 0} {
                error [format "MAP RANGE MISALIGNED hit=%d current=0x%016x" \
                       $hit $current]
            }
            if {$step != 0x1000 && $step != 0x200000 &&
                $step != 0x40000000} {
                error [format "MAP RANGE BAD STEP hit=%d current=0x%016x step=0x%016x" \
                       $hit $current $step]
            }
            if {$next <= $current || $next > $range_end} {
                error [format "MAP RANGE OVERRUN hit=%d current=0x%016x step=0x%016x end=0x%016x" \
                       $hit $current $step $range_end]
            }
            set expected $next
            if {$expected == $range_end} {
                puts [format "MAP RANGE COMPLETE hits=%d start=0x%016x end=0x%016x" \
                      $hit [parse_int [lindex $argv 2] start] $range_end]
                set complete 1
                break
            }
            write_command arm 1 pc 1 resume 1 \
                pc_addr $address pc_mask 0xfffffffffffffffc
            set status_value [wait_for_hit $timeout]
        }
        if {!$complete} {
            error [format "map range did not reach 0x%016x within %d hits; next expected 0x%016x" \
                   $range_end $max_hits $expected]
        }
    }
    walk-pc-reg-ne {
        if {$argc < 5 || $argc > 6} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set reg_a [parse_int [lindex $argv 2] reg-a]
        set reg_b [parse_int [lindex $argv 3] reg-b]
        set max_hits [parse_int [lindex $argv 4] max-hits]
        set timeout [expr {$argc == 6 ?
            [parse_int [lindex $argv 5] timeout] : 300}]
        if {$reg_a > 31 || $reg_b > 31} {
            error "walk-pc-reg-ne registers must be in the range 0..31"
        }
        if {$max_hits < 1} {
            error "walk-pc-reg-ne max-hits must be positive"
        }
        set found 0
        for {set hit 1} {$hit <= $max_hits} {incr hit} {
            write_command arm 1 pc 1 resume 1 \
                pc_addr $address pc_mask 0xfffffffffffffffc
            set status_value [wait_for_hit $timeout]
            set value_a [read_snapshot_word_stable [expr {20 + $reg_a}]]
            set value_b [read_snapshot_word_stable [expr {20 + $reg_b}]]
            set mepc [read_snapshot_word_stable 10]
            set a0 [read_snapshot_word_stable 30]
            set a1 [read_snapshot_word_stable 31]
            puts [format "hit=%d mepc=0x%016x x%d=0x%016x x%d=0x%016x a0=0x%016x a1=0x%016x" \
                  $hit $mepc $reg_a $value_a $reg_b $value_b $a0 $a1]
            if {$value_a != $value_b} {
                puts [format "REGISTER MISMATCH AFTER %d HITS" $hit]
                set found 1
                break
            }
        }
        if {!$found} {
            error [format "registers x%d and x%d remained equal for %d hits" \
                   $reg_a $reg_b $max_hits]
        }
    }
    walk-pc-reg-eq {
        if {$argc < 5 || $argc > 6} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set reg [parse_int [lindex $argv 2] reg]
        set expected [parse_int [lindex $argv 3] value]
        set max_hits [parse_int [lindex $argv 4] max-hits]
        set timeout [expr {$argc == 6 ?
            [parse_int [lindex $argv 5] timeout] : 300}]
        if {$reg > 31} {
            error "walk-pc-reg-eq register must be in the range 0..31"
        }
        if {$max_hits < 1} {
            error "walk-pc-reg-eq max-hits must be positive"
        }
        set found 0
        for {set hit 1} {$hit <= $max_hits} {incr hit} {
            write_command arm 1 pc 1 resume 1 \
                pc_addr $address pc_mask 0xfffffffffffffffc
            set status_value [wait_for_hit $timeout]
            set observed [read_snapshot_word_stable [expr {20 + $reg}]]
            set mepc [read_snapshot_word_stable 10]
            set a0 [read_snapshot_word_stable 30]
            set a1 [read_snapshot_word_stable 31]
            set s0 [read_snapshot_word_stable 28]
            set s1 [read_snapshot_word_stable 29]
            puts [format "hit=%d mepc=0x%016x x%d=0x%016x a0=0x%016x a1=0x%016x s0=0x%016x s1=0x%016x" \
                  $hit $mepc $reg $observed $a0 $a1 $s0 $s1]
            if {$observed == $expected} {
                puts [format "REGISTER MATCH AFTER %d HITS" $hit]
                set found 1
                break
            }
        }
        if {!$found} {
            error [format "x%d did not equal 0x%016x within %d hits" \
                   $reg $expected $max_hits]
        }
    }
    walk-pc-reg-value-ne {
        if {$argc < 5 || $argc > 6} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set reg [parse_int [lindex $argv 2] reg]
        set expected [parse_int [lindex $argv 3] value]
        set max_hits [parse_int [lindex $argv 4] max-hits]
        set timeout [expr {$argc == 6 ?
            [parse_int [lindex $argv 5] timeout] : 300}]
        if {$reg > 31} {
            error "walk-pc-reg-value-ne register must be in the range 0..31"
        }
        if {$max_hits < 1} {
            error "walk-pc-reg-value-ne max-hits must be positive"
        }
        set found 0
        for {set hit 1} {$hit <= $max_hits} {incr hit} {
            write_command arm 1 pc 1 resume 1 \
                pc_addr $address pc_mask 0xfffffffffffffffc
            set status_value [wait_for_hit $timeout]
            set observed [read_snapshot_word_stable [expr {20 + $reg}]]
            if {$observed != $expected} {
                set mepc [read_snapshot_word_stable 10]
                set a0 [read_snapshot_word_stable 30]
                set a1 [read_snapshot_word_stable 31]
                set s0 [read_snapshot_word_stable 28]
                set s1 [read_snapshot_word_stable 29]
                puts [format "hit=%d mepc=0x%016x x%d=0x%016x a0=0x%016x a1=0x%016x s0=0x%016x s1=0x%016x" \
                      $hit $mepc $reg $observed $a0 $a1 $s0 $s1]
                puts [format "REGISTER VALUE MISMATCH AFTER %d HITS: x%d expected=0x%016x observed=0x%016x" \
                      $hit $reg $expected $observed]
                set found 1
                break
            }
            if {$hit == 1 || ($hit & 15) == 0} {
                puts [format "hit=%d x%d=0x%016x (still expected)" \
                      $hit $reg $observed]
            }
        }
        if {!$found} {
            error [format "x%d remained equal to 0x%016x for %d hits" \
                   $reg $expected $max_hits]
        }
    }
    clear {
        if {$argc != 1} { usage }
        write_command clear 1
        after 20
        set status_value [capture_status]
    }
    arm-mem {
        if {$argc < 2 || $argc > 5} { usage }
        set address [parse_int [lindex $argv 1] address]
        set mask [expr {$argc >= 3 ?
            [parse_int [lindex $argv 2] mask] : 0xfffffffffffffff8}]
        set access [expr {$argc >= 4 ? [lindex $argv 3] : "read"}]
        set source [expr {$argc >= 5 ? [lindex $argv 4] : "all"}]
        set match_read [expr {$access eq "read" || $access eq "rw"}]
        set match_write [expr {$access eq "write" || $access eq "rw"}]
        if {!$match_read && !$match_write} {
            error "access must be read, write, or rw"
        }
        set match_scalar [expr {$source eq "scalar" || $source eq "all"}]
        set match_ptw [expr {$source eq "ptw" || $source eq "all"}]
        if {!$match_scalar && !$match_ptw} {
            error "source must be scalar, ptw, or all"
        }
        write_command arm 1 read $match_read write $match_write \
            scalar $match_scalar ptw $match_ptw clear 1 \
            mem_addr $address mem_mask $mask
        after 20
        set status_value [capture_status]
    }
    arm-pc {
        if {$argc < 2 || $argc > 3} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set mask [expr {$argc == 3 ?
            [parse_int [lindex $argv 2] mask] : 0xfffffffffffffffc}]
        write_command arm 1 pc 1 clear 1 pc_addr $address pc_mask $mask
        after 20
        set status_value [capture_status]
    }
    arm-pc-delay {
        if {$argc < 3 || $argc > 4} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set delay [parse_int [lindex $argv 2] delay-cycles]
        set mask [expr {$argc == 4 ?
            [parse_int [lindex $argv 3] mask] : 0xfffffffffffffffc}]
        if {$delay < 1} {
            error "arm-pc-delay delay must be positive"
        }
        set before [capture_status]
        if {[field $before 32 8] < 17} {
            error "arm-pc-delay requires USER1 version 17 or newer"
        }
        write_command arm 1 pc 1 cycle 1 clear 1 \
            pc_addr $address pc_mask $mask cycle_target $delay
        after 20
        set status_value [capture_status]
    }
    sample-pc-delay {
        if {$argc < 3 || $argc > 4} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set delay [parse_int [lindex $argv 2] delay-cycles]
        set timeout [expr {$argc == 4 ?
            [parse_int [lindex $argv 3] timeout] : 300}]
        if {$delay < 1} {
            error "sample-pc-delay delay must be positive"
        }
        set before [capture_status]
        if {[field $before 32 8] < 17} {
            error "sample-pc-delay requires USER1 version 17 or newer"
        }
        set previous_snapshot_cycle [read_snapshot_word_stable 4]
        write_command arm 1 pc 1 cycle 1 clear 1 \
            pc_addr $address pc_mask 0xfffffffffffffffc \
            cycle_target $delay
        after 20
        write_command reset 1
        puts [format "PC DELAY RESET pc=0x%016x delay=%d" \
              $address $delay]
        set status_value [wait_for_hit $timeout]
        set hit_cycle [field $status_value 384 64]

        # The trigger record precedes M-mode handler execution. Do not read a
        # stale complete snapshot retained across reset: require mcycle to
        # change, be at or after the trigger, and remain stable across reads,
        # as well as requiring the handler's COMPLETE state.
        set deadline [expr {[clock milliseconds] + 30000}]
        set snapshot_ready 0
        while {[clock milliseconds] < $deadline} {
            set snapshot_cycle [read_snapshot_word_stable 4]
            set snapshot_state [read_snapshot_word_stable 2]
            if {$snapshot_state == 2 &&
                $snapshot_cycle != $previous_snapshot_cycle &&
                $snapshot_cycle >= $hit_cycle} {
                set snapshot_ready 1
                break
            }
            after 100
        }
        if {!$snapshot_ready} {
            error "M-mode snapshot did not complete after delayed PC trigger"
        }

        set hit_pc [field $status_value 448 64]
        set hit_instr [field $status_value 784 32]
        set snapshot_minstret [read_snapshot_word_stable 5]
        set snapshot_mepc [read_snapshot_word_stable 10]
        set snapshot_ra [read_snapshot_word_stable 21]
        set snapshot_sp [read_snapshot_word_stable 22]
        set snapshot_s0 [read_snapshot_word_stable 28]
        set snapshot_a2 [read_snapshot_word_stable 32]
        set snapshot_a3 [read_snapshot_word_stable 33]
        set snapshot_s5 [read_snapshot_word_stable 41]
        puts [format "PC DELAY SAMPLE delay=%d start_cycle=%d hit_cycle=%d hit_pc=0x%016x hit_instr=0x%08x snapshot_cycle=%d minstret=%d mepc=0x%016x ra=0x%016x sp=0x%016x s0=0x%016x a2=0x%016x a3=0x%016x s5=0x%016x" \
              $delay [expr {$hit_cycle - $delay}] $hit_cycle $hit_pc \
              $hit_instr $snapshot_cycle $snapshot_minstret \
              $snapshot_mepc $snapshot_ra $snapshot_sp $snapshot_s0 \
              $snapshot_a2 $snapshot_a3 $snapshot_s5]
    }
    arm-cycle {
        if {$argc != 2} { usage }
        set cycle [parse_int [lindex $argv 1] cycle]
        write_command arm 1 cycle 1 clear 1 cycle_target $cycle
        after 20
        set status_value [capture_status]
    }
    trigger-cycle {
        if {$argc > 2} { usage }
        set delta [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] delta-cycles] : 10000000}]
        if {$delta < 10000} {
            error "trigger-cycle delta must be at least 10000 cycles"
        }
        set before [capture_status]
        set cycle [expr {[field $before 720 64] + $delta}]
        write_command arm 1 cycle 1 clear 1 cycle_target $cycle
        puts [format "OPENRV64 FPGA JTAG CYCLE IRQ ARMED live=%d target=%d delta=%d" \
              [field $before 720 64] $cycle $delta]
        after 20
        set status_value [capture_status]
    }
    read-cache {
        if {$argc < 2 || $argc > 3} { usage }
        set index [parse_int [lindex $argv 1] cache-index]
        if {$index > 1023} {
            error "cache-index must be in the range 0..1023"
        }
        set selector [expr {$argc == 3 ? [lindex $argv 2] : 0}]
        if {$selector eq "tag"} {
            set cache_tag 1
            set word 0
        } else {
            set cache_tag 0
            set word [parse_int $selector cache-word]
            if {$word > 3} {
                error "cache-word must be 0, 1, 2, 3, or tag"
            }
        }
        write_command cache_read 1 cache_index $index \
            cache_word $word cache_tag $cache_tag
        set status_value [wait_readback 0 $index]
    }
    read-snapshot {
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] snapshot-index]
        if {$index > 511} {
            error "snapshot-index must be in the range 0..511"
        }
        write_command snapshot_read 1 snapshot_index $index
        set status_value [wait_readback 1 $index]
    }
    dump-snapshot {
        if {$argc != 1} { usage }
        set labels {
            magic version state hwirq mcycle minstret mcause mtval
            mtval2 mtinst mepc mstatus satp mie mip sstatus
            sepc scause stval mhartid
        }
        for {set index 0} {$index < [llength $labels]} {incr index} {
            puts [format "%02d %-8s 0x%016x" $index \
                  [lindex $labels $index] [read_snapshot_word_stable $index]]
        }
        for {set reg 0} {$reg < 32} {incr reg} {
            set index [expr {20 + $reg}]
            puts [format "%02d x%-7d 0x%016x" $index $reg \
                  [read_snapshot_word_stable $index]]
        }
        set index 52
        foreach label {stub_state stub_entry stub_bytes stub_result stub_magic} {
            puts [format "%02d %-10s 0x%016x" $index $label \
                  [read_snapshot_word_stable $index]]
            incr index
        }
    }
    read-stub {
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] stub-index]
        if {$index > 2047} {
            error "stub-index must be in the range 0..2047"
        }
        write_command stub_read 1 stub_index $index
        set status_value [wait_readback 2 $index]
    }
    write-stub {
        if {$argc != 3} { usage }
        set index [parse_int [lindex $argv 1] stub-index]
        set data [parse_int [lindex $argv 2] stub-data]
        if {$index > 2047} {
            error "stub-index must be in the range 0..2047"
        }
        write_stub_word $index $data
        set status_value [capture_status]
    }
    dump-stub {
        if {$argc < 1 || $argc > 3} { usage }
        set start [expr {$argc >= 2 ?
            [parse_int [lindex $argv 1] start-word] : 0}]
        set count [expr {$argc == 3 ?
            [parse_int [lindex $argv 2] word-count] : 16}]
        if {$start > 2047 || $count < 1 || $start + $count > 2048} {
            error "stub dump range must fit inside words 0..2047"
        }
        for {set index $start} {$index < $start + $count} {incr index} {
            puts [format "%04d 0x%04x 0x%016x" $index \
                  [expr {$index * 8}] [read_stub_word $index]]
        }
    }
    read-instr-trace {
        global retire_trace_depth
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] record]
        if {$index >= $retire_trace_depth} {
            error [format "instruction trace record must be in 0..%d" \
                   [expr {$retire_trace_depth - 1}]]
        }
        set record [read_retire_trace_word [expr {2 * $index}]]
        set wdata [read_retire_trace_word [expr {2 * $index + 1}]]
        set stored_pc [field $record 32 32]
        set instr [field $record 0 32]
        puts [format "%04x pc_low=0x%08x instr=0x%08x rd=x%d wdata=0x%016x pred=%d taken=%d" \
            $index [expr {$stored_pc & 0xfffffffc}] $instr \
            [field $instr 7 5] $wdata [bit $stored_pc 1] \
            [bit $stored_pc 0]]
    }
    read-load-trace {
        global load_trace_depth protocol_version
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] record]
        if {$index >= $load_trace_depth} {
            error [format "load trace record must be in 0..%d" \
                   [expr {$load_trace_depth - 1}]]
        }
        set meta [read_load_trace_word $index 0]
        set data [read_load_trace_word $index 1]
        if {$protocol_version >= 21} {
            puts [format "%04x vaddr_low=0x%08x paddr_low=0x%08x data=0x%016x" \
                $index [field $meta 0 32] [field $meta 32 32] $data]
        } else {
            puts [format "%04x pc_low=0x%08x addr_low=0x%08x rd=x%d data=0x%016x" \
                $index [expr {[field $meta 37 24] << 2}] \
                [field $meta 0 32] [field $meta 32 5] $data]
        }
    }
    read-store-trace {
        global store_trace_depth protocol_version
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] record]
        if {$index >= $store_trace_depth} {
            error [format "store trace record must be in 0..%d" \
                   [expr {$store_trace_depth - 1}]]
        }
        set meta [read_store_trace_word $index 0]
        set data [read_store_trace_word $index 1]
        if {$protocol_version >= 21} {
            puts [format "%04x vaddr_low=0x%08x paddr_low=0x%08x data=0x%016x" \
                $index [field $meta 0 32] [field $meta 32 32] $data]
        } else {
            puts [format "%04x pc_low=0x%08x addr_low=0x%08x wstrb=0x%02x data=0x%016x" \
                $index [expr {[field $meta 40 24] << 2}] \
                [field $meta 0 32] [field $meta 32 8] $data]
        }
    }
    read-fetch-trace {
        global fetch_trace_depth
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] record]
        if {$index >= $fetch_trace_depth} {
            error [format "fetch trace record must be in 0..%d" \
                   [expr {$fetch_trace_depth - 1}]]
        }
        set pc [read_fetch_trace_word $index 0]
        set data [read_fetch_trace_word $index 1]
        puts [format "%04x pc=0x%016x data=0x%016x" $index $pc $data]
    }
    read-wave-trace {
        global protocol_version wave_trace_depth
        if {$argc != 2} { usage }
        if {$protocol_version < 23} {
            error "wave trace readback requires USER1 protocol version 23"
        }
        set index [parse_int [lindex $argv 1] record]
        if {$index >= $wave_trace_depth} {
            error [format "wave trace record must be in 0..%d" \
                   [expr {$wave_trace_depth - 1}]]
        }
        lassign [read_wave_trace $index] word0 word1 word2 word3
        puts [format "%04x word0=0x%016x word1=0x%016x word2=0x%016x word3=0x%016x" \
              $index $word0 $word1 $word2 $word3]
    }
    wave-status {
        global protocol_version
        if {$argc != 1} { usage }
        if {$protocol_version < 23} {
            error "wave trace status requires USER1 protocol version 23"
        }
        print_wave_status
    }
    dump-wave-trace {
        global protocol_version
        if {$argc != 2 && $argc != 4} { usage }
        if {$protocol_version < 23} {
            error "wave trace dump requires USER1 protocol version 23"
        }
        set start_sample [expr {$argc == 4 ?
            [parse_int [lindex $argv 2] start-sample] : 0}]
        set sample_count [expr {$argc == 4 ?
            [parse_int [lindex $argv 3] sample-count] : -1}]
        dump_wave_trace_csv [lindex $argv 1] $start_sample $sample_count
    }
    dump-instr-trace -
    dump-retire-trace {
        global retire_trace_depth retire_trace_meta_base
        if {$argc > 2} { usage }
        set max_records [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] max-records] : 64}]
        if {$max_records < 1 || $max_records > $retire_trace_depth} {
            error [format "retire trace record count must be in 1..%d" \
                   $retire_trace_depth]
        }
        set total [read_retire_trace_word $retire_trace_meta_base]
        set meta [read_retire_trace_word [expr {$retire_trace_meta_base + 1}]]
        set write_index [field $meta 0 13]
        set frozen [bit $meta 13]
        set retained [expr {$total < $retire_trace_depth ?
                            $total : $retire_trace_depth}]
        set selected [expr {$retained < $max_records ?
            $retained : $max_records}]
        set skip [expr {$retained - $selected}]
        puts [format "instr_trace total=%d retained=%d selected=%d write_index=%d frozen=%s" \
            $total $retained $selected $write_index [yesno $frozen]]
        for {set sequence [expr {$total - $selected}]} \
            {$sequence < $total} {incr sequence} {
            print_retire_record $sequence
        }
    }
    dump-load-trace {
        global load_trace_depth load_trace_meta_base
        if {$argc > 2} { usage }
        set max_records [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] max-records] : 64}]
        if {$max_records < 1 || $max_records > $load_trace_depth} {
            error [format "load trace record count must be in 1..%d" \
                   $load_trace_depth]
        }
        set total [read_retire_trace_word $load_trace_meta_base]
        set meta [read_retire_trace_word [expr {$load_trace_meta_base + 1}]]
        set write_index [field $meta 0 12]
        set frozen [bit $meta 12]
        set retained [expr {$total < $load_trace_depth ?
                            $total : $load_trace_depth}]
        set selected [expr {$retained < $max_records ?
            $retained : $max_records}]
        puts [format "load_trace total=%d retained=%d selected=%d write_index=%d frozen=%s" \
            $total $retained $selected $write_index [yesno $frozen]]
        for {set sequence [expr {$total - $selected}]} \
            {$sequence < $total} {incr sequence} {
            print_load_record $sequence
        }
    }
    dump-store-trace {
        global store_trace_depth store_trace_meta_base
        if {$argc > 2} { usage }
        set max_records [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] max-records] : 64}]
        if {$max_records < 1 || $max_records > $store_trace_depth} {
            error [format "store trace record count must be in 1..%d" \
                   $store_trace_depth]
        }
        set total [read_retire_trace_word $store_trace_meta_base]
        set meta [read_retire_trace_word [expr {$store_trace_meta_base + 1}]]
        set write_index [field $meta 0 12]
        set frozen [bit $meta 12]
        set retained [expr {$total < $store_trace_depth ?
                            $total : $store_trace_depth}]
        set selected [expr {$retained < $max_records ?
            $retained : $max_records}]
        puts [format "store_trace total=%d retained=%d selected=%d write_index=%d frozen=%s" \
            $total $retained $selected $write_index [yesno $frozen]]
        for {set sequence [expr {$total - $selected}]} \
            {$sequence < $total} {incr sequence} {
            print_store_record $sequence
        }
    }
    dump-fetch-trace {
        global fetch_trace_depth fetch_trace_meta_base protocol_version
        if {$argc > 2} { usage }
        if {$protocol_version < 22} {
            error "fetch trace readback requires USER1 protocol version 22"
        }
        set max_records [expr {$argc == 2 ?
            [parse_int [lindex $argv 1] max-records] : 64}]
        if {$max_records < 1 || $max_records > $fetch_trace_depth} {
            error [format "fetch trace record count must be in 1..%d" \
                   $fetch_trace_depth]
        }
        set total [read_retire_trace_word $fetch_trace_meta_base]
        set meta [read_retire_trace_word [expr {$fetch_trace_meta_base + 1}]]
        set write_index [field $meta 0 11]
        set frozen [bit $meta 11]
        set retained [expr {$total < $fetch_trace_depth ?
                            $total : $fetch_trace_depth}]
        set selected [expr {$retained < $max_records ?
            $retained : $max_records}]
        puts [format "fetch_trace total=%d retained=%d selected=%d write_index=%d frozen=%s" \
            $total $retained $selected $write_index [yesno $frozen]]
        for {set sequence [expr {$total - $selected}]} \
            {$sequence < $total} {incr sequence} {
            print_fetch_record $sequence
        }
    }
    load-stub {
        if {$argc < 2 || $argc > 3} { usage }
        set entry [expr {$argc == 3 ?
            [parse_int [lindex $argv 2] entry-offset] : 0}]
        load_stub_image [lindex $argv 1] $entry
        set status_value [capture_status]
    }
    clear-stub {
        if {$argc != 1} { usage }
        write_stub_word $stub_magic_word 0
        write_stub_word $stub_meta_word 0
        if {[read_stub_word $stub_magic_word] != 0} {
            error "stub descriptor clear did not verify"
        }
        puts "stub descriptor cleared"
        set status_value [capture_status]
    }
    read-uart {
        if {$argc != 2} { usage }
        set index [parse_int [lindex $argv 1] uart-word-index]
        if {$index > 2044 || ($index & 3) != 0} {
            error "UART burst index must be a multiple of four in 0..2044"
        }
        set uart_result [read_uart_burst $index]
        set uart_bytes [string range $uart_result 96 159]
        puts [format "uart_bytes=0x%s" $uart_bytes]
        puts [format "uart_burst=0x%s" [reverse_hex_bytes $uart_bytes]]
        set status_value [capture_status]
    }
    read-uart-lane {
        if {$argc != 3} { usage }
        set index [parse_int [lindex $argv 1] uart-word-index]
        set lane [parse_int [lindex $argv 2] uart-lane]
        if {$index > 2044 || ($index & 3) != 0 || $lane > 3} {
            error "UART lane read requires an aligned index in 0..2044 and lane 0..3"
        }
        set status_value [read_uart_lane $index $lane]
    }
    dump-uart {
        if {$argc != 2} { usage }
        dump_uart_image [lindex $argv 1]
    }
    follow-uart {
        set start_mode retained
        set until_text ""
        set timeout_seconds 0
        set poll_ms 10
        set argument 1
        while {$argument < $argc} {
            set option [lindex $argv $argument]
            incr argument
            if {$argument >= $argc} {
                error "missing value for $option"
            }
            set option_value [lindex $argv $argument]
            incr argument
            switch -- $option {
                --from {
                    set start_mode $option_value
                }
                --until {
                    set until_text $option_value
                }
                --timeout-seconds {
                    set timeout_seconds [parse_int $option_value timeout]
                }
                --poll-ms {
                    set poll_ms [parse_int $option_value poll-ms]
                }
                default {
                    error "unknown follow-uart option: $option"
                }
            }
        }
        follow_uart $start_mode $until_text $timeout_seconds $poll_ms
    }
    default {
        usage
    }
}

if {$status_value ne ""} {
    print_status $status_value
}

# XSDB otherwise falls back to its interactive prompt after sourcing this
# script. That leaves the managed run alive and holds run/log/build.lock even
# though the requested command and status print have completed.
disconnect
exit 0
