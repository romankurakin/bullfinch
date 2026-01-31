# Target Hardware

## Summary

| Platform | CPU | ISA |
|----------|-----|-----|
| QEMU virt | Configurable | ARM64 / RV64GC |
| Raspberry Pi 5 | Cortex-A76 | ARMv8.2-A |
| Orange Pi RV2 | X60 (Spacemit K1) | RV64GCV |
| Arduino UNO Q | Cortex-A53 | ARMv8.0-A |

## QEMU virt (ARM64)

Use `-cpu max` for all extensions or specific core (`cortex-a72`, `neoverse-n1`)

Supported: ASIMD, FP16, Crypto, CRC32, LSE, RAS, SVE, PAC, BTI, MTE (needs
`-machine mte=on`)

## QEMU virt (RISC-V)

Use `-cpu max` or `-cpu rv64,v=true,zba=true,...`

Supported: RV64GC, V (RVV 1.0), Zba, Zbb, Zbs, Zbc, Zicbom, Zicbop, Zicboz,
Zicntr, Zihpm, Zkt

Not supported: Zicfiss

## Raspberry Pi 5

Broadcom BCM2712, Cortex-A76 @ 2.4 GHz

Supported: ASIMD, FP16, Crypto, CRC32, LSE, DotProd, RDM, RAS, SSBS

Not supported: SVE, PAC (8.3+), BTI (8.5+), MTE (8.5+)

## Orange Pi RV2

Spacemit K1 / Ky X1, X60 core @ 1.6 GHz, RVA22 (partial)

Supported: RV64IMAFDC, V (RVV 1.0, 256-bit), Zba, Zbb, Zbc, Zbs, Zicbom, Zicbop,
Zicboz, Zicntr, Zicond, Zicsr, Zifencei, Zihintpause, Zihpm, Zfh, Zvfh, Zkt,
Zvkt, Sscofpmf, Sstc, Svinval, Svnapot, Svpbmt

Not supported: Zicfiss (RVA23), Zicclsm (misaligned vector access)

## Arduino UNO Q

Qualcomm QRB2210, Cortex-A53 @ 2.0 GHz, also has STM32U585 MCU

Supported: ASIMD, CRC32, TrustZone, Virtualization, Crypto (optional)

Not supported: LSE (8.1+), FP16 (8.2+), DotProd (8.2+), SVE, PAC (8.3+), BTI
(8.5+), MTE (8.5+)

## Implications

**Security**: No hardware CFI on physical targets.

**Atomics**: Pi 5 has LSE, UNO Q has LL/SC only, RV2 has LR/SC + AMO.

**Vectors**: Pi 5 NEON only, RV2 has RVV 1.0, QEMU has both SVE and RVV.

## References

- QEMU ARM virt: <https://www.qemu.org/docs/master/system/arm/virt.html>
- QEMU RISC-V virt: <https://www.qemu.org/docs/master/system/riscv/virt.html>
- Cortex-A76: <https://en.wikichip.org/wiki/arm_holdings/microarchitectures/cortex-a76>
- Cortex-A53: <https://en.wikichip.org/wiki/arm_holdings/microarchitectures/cortex-a53>
- Spacemit K1 datasheet: <https://docs.banana-pi.org/en/BPI-F3/SpacemiT_K1_datasheet>
- QRB2210: <https://www.qualcomm.com/internet-of-things/products/q2-series/qrb2210>
