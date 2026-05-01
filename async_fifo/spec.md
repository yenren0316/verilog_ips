# Asynchronous FIFO Architecture & Specification

## 1. Overview
The Asynchronous FIFO is designed to safely transfer data between two independent, asynchronous clock domains without data loss or metastability issues. This implementation is based on the standard dual-clock FIFO architecture utilizing Gray code pointers for cross-clock domain synchronization.

## 2. Interface Definition
* **Write Domain:**
  * `wclk`: Write clock.
  * `wrst_n`: Write active-low reset.
  * `winc`: Write enable (increment write pointer).
  * `wdata`: Data to be written (DSIZE bits).
  * `wfull`: Output flag indicating the FIFO is full.
* **Read Domain:**
  * `rclk`: Read clock.
  * `rrst_n`: Read active-low reset.
  * `rinc`: Read enable (increment read pointer).
  * `rdata`: Data read from the FIFO (DSIZE bits).
  * `rempty`: Output flag indicating the FIFO is empty.

## 3. Core Modules & Architecture

### A. Dual-Port Memory (`fifomem`)
* Acts as the core storage element.
* **Write Operation:** Synchronous to `wclk`. Data is written to `waddr` when `winc` is asserted and the FIFO is not full (`~wfull`).
* **Read Operation:** Asynchronous (Fall-Through) read. The output `rdata` continuously reflects the memory contents at `raddr` without waiting for a clock edge.

### B. Synchronizers (`sync_2ff`)
* Standard 2-stage Flip-Flop (2-FF) synchronizers.
* Used to safely transfer the Gray code pointers across the asynchronous clock domains.
* Synthesizes incoming asynchronous signals (e.g., `rptr` or `wptr`) into the local clock domain.

### C. Read Pointer & Empty Logic (`rptr_empty`)
* Operates entirely in the `rclk` domain.
* **Read Address Generation:** Maintains a binary counter (`rbin`) for memory access.
* **Pointer Conversion:** Converts the binary counter to a Gray code pointer (`rptr`) to be sent to the write domain.
* **Empty Condition:** The FIFO is empty when the next Gray code read pointer (`rgraynext`) exactly matches the synchronized write pointer (`rq2_wptr`).

### D. Write Pointer & Full Logic (`wptr_full`)
* Operates entirely in the `wclk` domain.
* **Write Address Generation:** Maintains a binary counter (`wbin`) for memory access.
* **Pointer Conversion:** Converts the binary counter to a Gray code pointer (`wptr`) to be sent to the read domain.
* **Full Condition:** The FIFO is full when the next Gray code write pointer (`wgraynext`) has:
  * An inverted MSB compared to the synchronized read pointer.
  * An inverted 2nd MSB compared to the synchronized read pointer.
  * Matching remaining LSBs.

## 4. Control Flow & Cross-Domain Operation
1. **Data Write:** Data is written into the dual-port memory at the current `wbin` address. The write binary pointer increments.
2. **Pointer Conversion (Write):** The incremented `wbin` is converted to a Gray code pointer (`wptr`).
3. **Synchronization (W2R):** The `wptr` is safely passed through a 2-FF synchronizer clocked by `rclk` to become `rq2_wptr` in the read domain.
4. **Empty Flag Update:** The read domain compares its own Gray code pointer (`rgraynext`) with `rq2_wptr`. If they do not match, the FIFO is no longer empty, and `rempty` is de-asserted.
5. **Data Read:** Data is read continuously from the memory at the current `rbin` address. When the consumer processes it, they assert `rinc`.
6. **Pointer Conversion (Read):** The read binary pointer increments and is converted to a Gray code pointer (`rptr`).
7. **Synchronization (R2W):** The `rptr` is safely passed through a 2-FF synchronizer clocked by `wclk` to become `wq2_rptr` in the write domain.
8. **Full Flag Update:** The write domain compares `wgraynext` with `wq2_rptr` using the "inverted top 2 bits" rule. If space has opened up, `wfull` is de-asserted.