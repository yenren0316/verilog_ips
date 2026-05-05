# Verilog IPs & Playground

Welcome to the `verilog-ips` repository! This workspace contains various Hardware Intellectual Property (IP) designs and behavioral modules implemented in Verilog. It serves as a library for reusable digital logic components and an experimental sandbox for RTL architecture.

## Included Modules

### 1. Asynchronous FIFOs (`async_fifo/`)
A collection of reliable, cross-clock domain synchronization FIFOs.
*   **Standard Async FIFO (`rtl/async_fifo.v`)**:
    *   Implements classic dual-clock architecture using Gray code pointers and 2-stage Flip-Flop synchronizers.
    *   Provides standard read semantics (data available 1 cycle after `rinc`).
*   **FWFT Async FIFO (`rtl/fwft_async_fifo.v`)**:
    *   First-Word Fall-Through (FWFT) wrapper around the standard FIFO.
    *   Pre-fetches the next available data word so it is immediately valid on the `rdata` bus without requiring a read enable signal first.
    *   Highly optimized: adds only minimal overhead (9 registers and 4 logic gates) over the standard FIFO.
*   **Verification**:
    *   Includes Python-generated bit-true test patterns.
    *   Full hardware bit-true matching verified via Verilog testbenches (`tb/`).
*   **Synthesis**:
    *   Contains Yosys synthesis scripts (`syn/`) that demonstrate how the behavioral dual-port SRAM model (`fifomem.v`) correctly infers as Distributed RAM (`RAM32M`) on Xilinx 7-Series FPGA architectures.

### 2. Common Library (`commonlib/`)
Reusable, foundational infrastructure blocks for IP development.
*   **`fifomem.v`**: A parameterized, behavioral Dual-Port SRAM model with asynchronous read support.
*   **`rom.v`**: A parameterized, single-port ROM with asynchronous read and `$readmemh` initialization.
*   **`sync_2ff.v`**: A parameterized 2-stage Flip-Flop synchronizer for safely passing signals across asynchronous clock domains.

### 3. Complex Mixer (`ip_complex_mixer/`)
A complex frequency mixer with NCO-optimized quarter-wave shared ROM.
*   **Architecture**: 3-stage pipeline — phase accumulator → NCO LUT → complex multiply.
*   **NCO ROM optimization**: Quarter-wave table packs `{sin[N/4-1-i], sin[i]}` per entry so both cos(θ) and sin(θ) are derived from a single ROM read, halving memory area vs. two separate tables.
*   **Parameters**: `DATA_W=16` (I/Q), `AMP_W=12` (NCO amplitude), `PHASE_W=16` (frequency resolution = fs/65536), runtime `freq_word` port.
*   **Verification**: Python golden model generates bit-true test vectors; 200/200 cases pass.

### 4. Block Floating-Point (BFP) Unit (`ip_bfp/`)
*   Contains RTL templates and extensive Python-based test pattern generators (`pattern/bfp_sim.py`) for exploring Block Floating-Point quantization algorithms and hardware trade-offs.

## Simulation & Tools

All modules are designed to be easily simulated using **Icarus Verilog (`iverilog`)**.
To view the output waveforms (`.vcd` files), you can use **GTKWave**. Synthesis evaluation is performed using **Yosys**.

*Note: Simulation outputs (`*.vvp`, `*.out`, `*.vcd`) are ignored by `.gitignore` to keep the repository clean.*
