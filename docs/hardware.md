# Target Hardware

These notes describe hardware and emulation features for the target platforms.
Kernel implementation status is tracked in [plan.md](plan.md). A listed CPU
feature does not imply that Bullfinch uses it.

## Summary

| Platform | CPU | ISA |
|----------|-----|-----|
| QEMU virt | Configurable | ARM64 / RV64GC |
| Raspberry Pi 5 | Cortex-A76 | ARMv8.2-A |
| Orange Pi RV2 | X60 (Spacemit K1) | RV64GCV |
| Arduino UNO Q | Cortex-A53 | ARMv8.0-A |

## QEMU virt (ARM64)

Select a CPU model with `-cpu max` or a named core such as `cortex-a72` or
`neoverse-n1`. The features exposed by `max` can change between QEMU versions.
Some features also need machine options, as described in the
[QEMU virt documentation](https://www.qemu.org/docs/master/system/arm/virt.html).

Supported: ASIMD, FP16, Crypto, CRC32, LSE, RAS, SVE, PAC, BTI, MTE (needs
`-machine mte=on`)

## QEMU virt (RISC-V)

Select `-cpu max` or configure extensions on `rv64`, for example with
`-cpu rv64,v=true,zba=true`.

Supported: RV64GC, V (RVV 1.0), Zba, Zbb, Zbs, Zbc, Zicbom, Zicbop, Zicboz,
Zicntr, Zihpm, Zkt

Not supported: Zicfiss

## Raspberry Pi 5

The Broadcom BCM2712 contains Cortex-A76 cores running at 2.4 GHz.

Supported: ASIMD, FP16, Crypto, CRC32, LSE, DotProd, RDM, RAS, SSBS

Not supported: SVE, PAC (8.3+), BTI (8.5+), MTE (8.5+)

## Orange Pi RV2

Spacemit K1 / Ky X1 uses X60 cores running at 1.6 GHz, with partial RVA22 support.

Supported: RV64IMAFDC, V (RVV 1.0, 256-bit), Zba, Zbb, Zbc, Zbs, Zicbom, Zicbop,
Zicboz, Zicntr, Zicond, Zicsr, Zifencei, Zihintpause, Zihpm, Zfh, Zvfh, Zkt,
Zvkt, Sscofpmf, Sstc, Svinval, Svnapot, Svpbmt

Not supported: Zicfiss (RVA23), Zicclsm (misaligned vector access)

## Arduino UNO Q

The Qualcomm QRB2210 contains Cortex-A53 cores running at 2.0 GHz.
The board also has an STM32U585 microcontroller.

Supported: ASIMD, CRC32, TrustZone, Virtualization, Crypto (optional)

Not supported: LSE (8.1+), FP16 (8.2+), DotProd (8.2+), SVE, PAC (8.3+), BTI
(8.5+), MTE (8.5+)

## Implications

**Security**: The physical targets lack hardware control-flow integrity (CFI)
features listed here, such as BTI or Zicfiss.

**Atomics**: Pi 5 has LSE instructions. UNO Q uses load-linked/store-conditional
(LL/SC) sequences. RV2 has load-reserved/store-conditional (LR/SC) sequences
and atomic memory operations (AMO).

**Vectors**: Pi 5 supports NEON but not SVE. RV2 supports RVV 1.0.
QEMU can expose SVE on ARM64 and RVV on RISC-V.

**Boot**: The developer commands boot QEMU directly. ARM64 uses a raw image.
RISC-V uses OpenSBI to load the ELF kernel. For physical boards, U-Boot should
first be added through separate board profiles before replacing direct boot
in smoke tests.

## References

- QEMU ARM virt: <https://www.qemu.org/docs/master/system/arm/virt.html>
- QEMU RISC-V virt: <https://www.qemu.org/docs/master/system/riscv/virt.html>
- Cortex-A76: <https://en.wikichip.org/wiki/arm_holdings/microarchitectures/cortex-a76>
- Cortex-A53: <https://en.wikichip.org/wiki/arm_holdings/microarchitectures/cortex-a53>
- Spacemit K1 datasheet: <https://docs.banana-pi.org/en/BPI-F3/SpacemiT_K1_datasheet>
- QRB2210: <https://www.qualcomm.com/internet-of-things/products/q2-series/qrb2210>
