#ifndef OPENRV64_RVMODEL_MACROS_H
#define OPENRV64_RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION                                      \
  .pushsection .tohost,"aw",@progbits;                           \
  .balign 8; .global tohost; tohost: .dword 0;                    \
  .balign 8; .global fromhost; fromhost: .dword 0;                \
  .popsection;

#define STANDARD_SM_SUPPORTED

#define RVMODEL_HALT_PASS                                         \
  li x1, 1;                                                       \
  la t0, tohost;                                                  \
  sw x1, 0(t0);                                                   \
  sw x0, 4(t0);                                                   \
1: j 1b;

#define RVMODEL_HALT_FAIL                                         \
  li x1, 3;                                                       \
  la t0, tohost;                                                  \
  sw x1, 0(t0);                                                   \
  sw x0, 4(t0);                                                   \
1: j 1b;

#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100
#define RVMODEL_MTIME_ADDRESS 0x0200BFF8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_MSIP_ADDRESS 0x02000000

#define RVMODEL_SET_MSW_INT(_R1, _R2)                             \
  li _R1, 1;                                                      \
  li _R2, RVMODEL_MSIP_ADDRESS;                                  \
  sw _R1, 0(_R2);

#define RVMODEL_CLR_MSW_INT(_R1, _R2)                             \
  li _R2, RVMODEL_MSIP_ADDRESS;                                  \
  sw zero, 0(_R2);

#define RVMODEL_SET_MEXT_INT(_R1, _R2)                            \
  li _R1, 7;                                                      \
  li _R2, 0x0c000000;                                            \
  sw _R1, 4(_R2);                                                \
  li _R1, 2;                                                      \
  li _R2, 0x0c002000;                                            \
  sw _R1, 0(_R2);                                                \
  li _R2, 0x0c200000;                                            \
  sw zero, 0(_R2);                                               \
  li _R1, 2;                                                      \
  li _R2, 0x10000001;                                            \
  sb _R1, 0(_R2);

#define RVMODEL_CLR_MEXT_INT(_R1, _R2)                            \
  li _R2, 0x10000001;                                            \
  sb zero, 0(_R2);                                               \
  li _R2, 0x0c200004;                                            \
  lw _R1, 0(_R2);                                                \
  sw _R1, 0(_R2);                                                \
  li _R2, 0x0c002000;                                            \
  sw zero, 0(_R2);

// The current platform exposes machine PLIC and CLINT contexts only. ACT4's
// common environment requires all four supervisor hooks to be present even
// when supervisor interrupt injection is unavailable. Keeping these hooks
// empty makes that limitation an exact test failure rather than a build-wide
// exclusion.
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif
