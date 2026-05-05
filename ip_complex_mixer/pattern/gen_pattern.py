#!/usr/bin/env python3
"""
gen_pattern.py — Golden model for complex_mixer.v.

Simulates the full 3-stage pipeline (bit-true) and writes:
    pattern/input.txt    — "din_i din_q freq_word" per line (decimal, signed I/Q)
    pattern/expected.txt — "exp_i exp_q"            per line (decimal, signed)

Pipeline model (matches RTL):
    Stage 1: phase_r = phase_acc; phase_acc += freq_word (if valid)
             latch I1, Q1
    Stage 2: sin_r, cos_r = nco_lut(phase_r); latch I2, Q2
    Stage 3: dout_i = (I2*cos_r - Q2*sin_r) >> AMP_W
             dout_q = (I2*sin_r + Q2*cos_r) >> AMP_W

All arithmetic uses integer truncation to match Verilog >> (arithmetic right shift
on signed values; for 2's complement the top 16 bits of the 29-bit sum match).
"""
import math
import os
import struct

# ── Parameters ────────────────────────────────────────────────────────────────
PHASE_W  = 16
AMP_W    = 12
DATA_W   = 16
QASIZE   = PHASE_W - 2
QSIZE    = 1 << QASIZE          # 16384
AMP_MAX  = (1 << (AMP_W - 1)) - 1   # 2047
PROD_W   = DATA_W + AMP_W       # 28

# ── Build ROM table (same as gen_nco_rom.py) ──────────────────────────────────
rom = []
for i in range(QSIZE):
    lo = round(AMP_MAX * math.sin(i           * math.pi / 2 / QSIZE))
    hi = round(AMP_MAX * math.sin((QSIZE-1-i) * math.pi / 2 / QSIZE))
    lo = max(0, min(AMP_MAX, lo))
    hi = max(0, min(AMP_MAX, hi))
    rom.append((hi, lo))   # rom[i] = (hi=sin[QSIZE-1-i], lo=sin[i])

def nco_lut(phase):
    """Returns (sin_out, cos_out) as signed integers, matching nco_lut.v."""
    quadrant = (phase >> (PHASE_W - 2)) & 0x3
    raw_idx  = phase & ((1 << QASIZE) - 1)
    hi, lo   = rom[raw_idx]
    sin_amp  = hi if (quadrant & 1) else lo
    cos_amp  = lo if (quadrant & 1) else hi
    sin_sign = bool(quadrant & 2)
    cos_sign = bool(bool(quadrant & 2) ^ bool(quadrant & 1))
    sin_out  = -sin_amp if sin_sign else sin_amp
    cos_out  = -cos_amp if cos_sign else cos_amp
    return sin_out, cos_out

def to_signed(val, bits):
    """Wrap an integer into signed two's complement range."""
    mask = (1 << bits) - 1
    val  = val & mask
    if val >= (1 << (bits - 1)):
        val -= (1 << bits)
    return val

def arithmetic_right_shift(val, shift, total_bits):
    """Arithmetic right shift matching Verilog >>> on signed."""
    # In Python signed integers, >> is arithmetic
    return val >> shift

# ── Test cases ────────────────────────────────────────────────────────────────
N_SAMPLES  = 200
FREQ_WORD  = 0x0800    # fs/32 frequency shift

# I/Q input: BPSK-ish pattern + some edge cases
import random
random.seed(42)

samples = []
# Edge cases first
for i_val, q_val in [(0, 0), (32767, 0), (-32768, 0), (0, 32767),
                     (32767, 32767), (-32768, -32768), (1, -1)]:
    samples.append((i_val, q_val))
# Random samples
for _ in range(N_SAMPLES - len(samples)):
    i_val = random.randint(-32768, 32767)
    q_val = random.randint(-32768, 32767)
    samples.append((i_val, q_val))

# ── Simulate 3-stage pipeline ─────────────────────────────────────────────────
phase_acc = 0

# Pipeline register state
# Stage 1 output
ph1, I1, Q1, v1 = 0, 0, 0, False
# Stage 2 output
sin_r, cos_r, I2, Q2, v2 = 0, 0, 0, 0, False
# Stage 3 output (collected)
outputs = []   # list of (out_i, out_q, valid)

def clock(din_i, din_q, freq_word, din_valid):
    """Advance one clock cycle. Returns (dout_i, dout_q, dout_valid)."""
    global phase_acc, ph1, I1, Q1, v1, sin_r, cos_r, I2, Q2, v2

    # Stage 3: compute output from stage-2 registers (combinational in this cycle)
    prod_I_cos = I2 * cos_r
    prod_Q_sin = Q2 * sin_r
    prod_I_sin = I2 * sin_r
    prod_Q_cos = Q2 * cos_r
    sum_i = prod_I_cos - prod_Q_sin   # 29-bit signed
    sum_q = prod_I_sin + prod_Q_cos

    # Truncate: take bits [PROD_W-1:AMP_W] = arithmetic right shift by AMP_W
    dout_i = to_signed(arithmetic_right_shift(sum_i, AMP_W, PROD_W + 1), DATA_W)
    dout_q = to_signed(arithmetic_right_shift(sum_q, AMP_W, PROD_W + 1), DATA_W)
    dout_v = v2

    # Stage 2: latch NCO + I/Q from stage-1 registers
    nco_s, nco_c = nco_lut(ph1)
    sin_r, cos_r = nco_s, nco_c
    I2, Q2 = I1, Q1
    v2 = v1

    # Stage 1: capture input, update phase
    ph1 = phase_acc   # phase_r gets old phase_acc
    I1, Q1 = din_i, din_q
    v1 = din_valid
    if din_valid:
        phase_acc = (phase_acc + freq_word) & ((1 << PHASE_W) - 1)

    return dout_i, dout_q, dout_v

# Feed inputs and collect outputs
all_inputs  = []
all_outputs = []

for s in samples:
    i_val, q_val = s
    out_i, out_q, out_v = clock(i_val, q_val, FREQ_WORD, True)
    all_inputs.append((i_val, q_val, FREQ_WORD))
    if out_v:
        all_outputs.append((out_i, out_q))

# Drain pipeline (3 extra cycles with dummy inputs)
for _ in range(3):
    out_i, out_q, out_v = clock(0, 0, FREQ_WORD, False)
    if out_v:
        all_outputs.append((out_i, out_q))

# ── Write files ───────────────────────────────────────────────────────────────
os.makedirs("pattern", exist_ok=True)

with open("pattern/input.txt", "w") as f:
    for i_val, q_val, fw in all_inputs:
        f.write(f"{i_val} {q_val} {fw}\n")

with open("pattern/expected.txt", "w") as f:
    for exp_i, exp_q in all_outputs:
        f.write(f"{exp_i} {exp_q}\n")

print(f"Generated {len(all_inputs)} input samples, {len(all_outputs)} expected outputs.")
print(f"freq_word = 0x{FREQ_WORD:04x}  ({FREQ_WORD}/{1<<PHASE_W} * fs)")
