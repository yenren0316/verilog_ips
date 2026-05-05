#!/usr/bin/env python3
"""
gen_nco_rom.py — Generate quarter-wave NCO ROM hex file.

Each entry i packs two sin magnitudes:
    hi = round(AMP_MAX * sin((QSIZE-1-i) * pi/2 / QSIZE))
    lo = round(AMP_MAX * sin(i           * pi/2 / QSIZE))
    output: f"{(hi << AMP_W | lo):06x}"

Usage:
    python3 gen_nco_rom.py > pattern/nco_rom.hex
"""
import math

PHASE_W = 16
AMP_W   = 12
QASIZE  = PHASE_W - 2          # 14
QSIZE   = 1 << QASIZE          # 16384
AMP_MAX = (1 << (AMP_W - 1)) - 1  # 2047

for i in range(QSIZE):
    lo = round(AMP_MAX * math.sin(i           * math.pi / 2 / QSIZE))
    hi = round(AMP_MAX * math.sin((QSIZE-1-i) * math.pi / 2 / QSIZE))
    # Clamp to [0, AMP_MAX] to guard against float rounding at endpoints
    lo = max(0, min(AMP_MAX, lo))
    hi = max(0, min(AMP_MAX, hi))
    word = (hi << AMP_W) | lo
    print(f"{word:06x}")
