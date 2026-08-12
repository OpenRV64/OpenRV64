.section .text.startup, "ax", @progbits
.option norvc
.globl main
.type main, @function

main:
    addi sp, sp, -16
    sd   ra, 8(sp)
    call coremark_loop
.globl coremark_vm_done
coremark_vm_done:
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

.size main, .-main
