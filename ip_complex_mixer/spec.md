# Complex Mixer IP (`ip_complex_mixer`)

## Overview

Frequency-translates a complex baseband signal (I + jQ) by multiplying it with an
NCO (Numerically Controlled Oscillator) output:

```
dout_i = din_i * cos(θ) - din_q * sin(θ)
dout_q = din_i * sin(θ) + din_q * cos(θ)
```

The NCO uses a **quarter-wave shared ROM** — a single memory provides both cos and
sin by packing two complementary sin magnitudes per entry, reducing ROM area by 50%
versus two separate full-period tables.

---

## Parameters

| Parameter  | Default | Description                                  |
|-----------|---------|----------------------------------------------|
| `DATA_W`  | 16      | I/Q input/output width (signed)              |
| `AMP_W`   | 12      | NCO amplitude bits (signed, range ±2047)     |
| `PHASE_W` | 16      | Phase accumulator width (frequency resolution = fs / 2^PHASE_W) |
| `NCO_ROM` | `"pattern/nco_rom.hex"` | Path to ROM initialisation file |

---

## Ports

| Port         | Dir | Width    | Description                          |
|-------------|-----|----------|--------------------------------------|
| `clk`       | in  | 1        | Clock                                |
| `rst_n`     | in  | 1        | Active-low synchronous reset         |
| `din_valid` | in  | 1        | Input sample valid                   |
| `din_i`     | in  | DATA_W   | I (real) input, signed               |
| `din_q`     | in  | DATA_W   | Q (imaginary) input, signed          |
| `freq_word` | in  | PHASE_W  | NCO frequency word (runtime control) |
| `dout_valid`| out | 1        | Output sample valid (3-cycle latency)|
| `dout_i`   | out | DATA_W   | I output, signed                     |
| `dout_q`   | out | DATA_W   | Q output, signed                     |

---

## Architecture

### NCO ROM Optimization

Quarter-wave ROM: 2^(PHASE_W-2) = 16384 entries, each 2×AMP_W = 24 bits.

```
ROM entry i = { sin[QSIZE-1-i][11:0],  sin[i][11:0] }
                       hi                    lo
```

Quadrant decode (combinational, 0-cycle latency):

```
quadrant = phase[15:14]
raw_idx  = phase[13:0]

sin_amp  = quadrant[0] ? rom[raw_idx].hi : rom[raw_idx].lo
cos_amp  = quadrant[0] ? rom[raw_idx].lo : rom[raw_idx].hi
sin_sign = quadrant[1]
cos_sign = quadrant[1] ^ quadrant[0]
```

| Quadrant | Degrees    | sin index     | sin sign | cos index     | cos sign |
|---------|-----------|---------------|----------|---------------|----------|
| 0       | 0°–90°   | raw           | +        | QSIZE-1-raw   | +        |
| 1       | 90°–180° | QSIZE-1-raw   | +        | raw           | −        |
| 2       | 180°–270°| raw           | −        | QSIZE-1-raw   | −        |
| 3       | 270°–360°| QSIZE-1-raw   | −        | raw           | +        |

### Pipeline (3 stages)

```
Stage 1 │ Phase accumulator: phase_acc += freq_word
        │ Latch I1, Q1, valid1
        ▼
     [nco_lut — combinational]
        ▼
Stage 2 │ Latch sin_r, cos_r, I2, Q2, valid2
        ▼
Stage 3 │ dout_i = (I2*cos_r - Q2*sin_r)[27:12]
        │ dout_q = (I2*sin_r + Q2*cos_r)[27:12]
        │ dout_valid = valid2
```

Multiply width: 16 × 12 = 28-bit signed product. Bits [27:12] (÷ 2^12) give a
16-bit result normalised to the NCO full-scale amplitude.

---

## Submodules

| Module         | File                      | Description                         |
|---------------|---------------------------|-------------------------------------|
| `nco_lut`     | `rtl/nco_lut.v`           | Quarter-wave ROM + quadrant decoder |
| `rom`         | `../../commonlib/rom.v`   | Single-port ROM (async read)        |

---

## Simulation

```bash
# 1. Generate ROM hex (run once, or when AMP_W / PHASE_W changes)
python3 pattern/gen_nco_rom.py > pattern/nco_rom.hex

# 2. Generate test vectors
python3 pattern/gen_pattern.py

# 3. Compile
iverilog -o sim/complex_mixer.vvp \
    tb/complex_mixer_tb.v rtl/complex_mixer.v rtl/nco_lut.v \
    ../../commonlib/rom.v

# 4. Simulate
vvp sim/complex_mixer.vvp
```

Expected result: **PASS: 200  FAIL: 0**
