# SPDX-License-Identifier: CERN-OHL-P-2.0

set scan_bits 832
set command_key 0x4f525636
set mask64 0xffffffffffffffff

proc usage {} {
    puts stderr "usage: fpga-jtag-snoop <status|resume|clear|arm-mem|arm-pc|arm-cycle> ?arguments?"
    puts stderr "  status"
    puts stderr "  resume"
    puts stderr "  clear"
    puts stderr "  arm-mem <address> ?mask? ?read|write|rw? ?scalar|ptw|all?"
    puts stderr "  arm-pc <pc> ?mask?"
    puts stderr "  arm-cycle <absolute-core-cycle>"
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

proc write_command {arm read write scalar ptw pc cycle resume clear \
                    mem_addr mem_mask pc_addr pc_mask cycle_target} {
    global command_key mask64
    set value $command_key
    foreach {enabled index} [list \
            $arm 32 $read 33 $write 34 $scalar 35 $ptw 36 \
            $pc 37 $cycle 38 $resume 39 $clear 40] {
        if {$enabled} {
            set value [expr {$value | (1 << $index)}]
        }
    }
    set value [expr {$value | (($mem_addr & $mask64) << 64)}]
    set value [expr {$value | (($mem_mask & $mask64) << 128)}]
    set value [expr {$value | (($pc_addr & $mask64) << 192)}]
    set value [expr {$value | (($pc_mask & $mask64) << 256)}]
    set value [expr {$value | (($cycle_target & $mask64) << 320)}]
    scan_user1 $value 0
}

proc resume_and_clear {} {
    write_command 0 0 0 0 0 0 0 1 0 0 0 0 0 0
    # The always-running debug clock needs only a handful of cycles. This
    # delay also lets the restarted SoC domain consume the clear toggle.
    after 20
}

proc print_status {value} {
    global command_key
    set signature [field $value 0 32]
    if {$signature != $command_key} {
        error [format "USER1 signature mismatch: got 0x%08x expected 0x%08x" \
               $signature $command_key]
    }
    set hit_valid [bit $value 42]
    set reasons {}
    foreach {label index} {scalar 43 ptw 44 pc 45 cycle 46} {
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
    puts [format "armed=%s clock_halted=%s hit_valid=%s reason=%s" \
          [yesno [bit $value 40]] [yesno [bit $value 41]] \
          [yesno $hit_valid] $reason]
    puts [format "match read=%s write=%s scalar=%s ptw=%s pc=%s cycle=%s" \
          [yesno [bit $value 49]] [yesno [bit $value 50]] \
          [yesno [bit $value 51]] [yesno [bit $value 52]] \
          [yesno [bit $value 53]] [yesno [bit $value 54]]]
    puts [format "mem_target=0x%016x mem_mask=0x%016x" \
          [field $value 64 64] [field $value 128 64]]
    puts [format "pc_target=0x%016x pc_mask=0x%016x" \
          [field $value 192 64] [field $value 256 64]]
    puts [format "cycle_target=%d live_cycle=%d" \
          [field $value 320 64] [field $value 720 64]]
    if {$hit_valid} {
        puts [format "hit_cycle=%d hit_pc=0x%016x" \
              [field $value 384 64] [field $value 448 64]]
        puts [format "hit_addr=0x%016x hit_write=%s hit_error=%s" \
              [field $value 512 64] [yesno [bit $value 47]] \
              [yesno [bit $value 48]]]
        puts [format "hit_rdata=0x%016x hit_wdata=0x%016x hit_wstrb=0x%02x" \
              [field $value 576 64] [field $value 640 64] \
              [field $value 704 8]]
    }
}

if {$argc < 1} {
    usage
}

set server_url [expr {[info exists ::env(FPGA_HW_SERVER_URL)] ?
    $::env(FPGA_HW_SERVER_URL) : "tcp:10.1.6.21:3121"}]
connect -url $server_url
jtag targets -set -filter {name =~ "*xc7a100t*"}
set jtag_frequency [expr {[info exists ::env(FPGA_JTAG_FREQUENCY)] ?
    $::env(FPGA_JTAG_FREQUENCY) : 1000000}]
if {$jtag_frequency <= 0 || $jtag_frequency > 10000000} {
    error "FPGA_JTAG_FREQUENCY must be in the range 1..10000000 Hz"
}
jtag frequency $jtag_frequency

set command [lindex $argv 0]
switch -- $command {
    status {
        if {$argc != 1} { usage }
    }
    resume {
        if {$argc != 1} { usage }
        resume_and_clear
    }
    clear {
        if {$argc != 1} { usage }
        write_command 0 0 0 0 0 0 0 0 1 0 0 0 0 0
        after 20
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
        write_command 1 $match_read $match_write $match_scalar $match_ptw \
                      0 0 1 0 $address $mask 0 0 0
        after 20
    }
    arm-pc {
        if {$argc < 2 || $argc > 3} { usage }
        set address [parse_int [lindex $argv 1] pc]
        set mask [expr {$argc == 3 ?
            [parse_int [lindex $argv 2] mask] : 0xfffffffffffffffc}]
        write_command 1 0 0 0 0 1 0 1 0 0 0 $address $mask 0
        after 20
    }
    arm-cycle {
        if {$argc != 2} { usage }
        set cycle [parse_int [lindex $argv 1] cycle]
        write_command 1 0 0 0 0 0 1 1 0 0 0 0 0 $cycle
        after 20
    }
    default {
        usage
    }
}

print_status [scan_user1 0 1]
