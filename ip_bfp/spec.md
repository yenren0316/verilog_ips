# BFP Encoder IP 規格書

**版本**：1.0  
**日期**：2026-05-02  
**檔案**：`rtl/bfp_encoder.v`（依賴 `commonlib/fifomem.v`）

---

## 1. 功能描述

BFP Encoder 將連續輸入的 16-bit 有號整數樣本依 block 為單位進行 Block Floating Point 量化：
- 每 `BLOCK_SIZE` 個樣本為一個 block
- 計算 block 內的 shared exponent `e`（等效 `ceil(log2(abs_max / max_int))`）
- 對每個樣本做 rounding + arithmetic right shift + clip，輸出 `MANTISSA_BITS` 位元的 mantissa
- 輸出吞吐量：穩態 **1 sample / cycle**，無氣泡

---

## 2. 模組介面

```verilog
module bfp_encoder #(
    parameter BLOCK_SIZE    = 32,   // 每 block 樣本數（建議為 2 的次方）
    parameter DATA_WIDTH    = 16,   // 輸入樣本位元寬（有號 2's complement）
    parameter MANTISSA_BITS = 4,    // 輸出 mantissa 位元數
    parameter EXP_BITS      = 5     // shared exponent 位元數（最大可表示 e=31）
) (
    input  wire                      clk,
    input  wire                      rst_n,       // 非同步低有效 reset

    // 輸入 stream
    input  wire                      din_valid,   // 上游資料有效
    input  wire [DATA_WIDTH-1:0]     din,         // 有號輸入樣本
    output wire                      din_ready,   // 恆為 1（目前不支援 back-pressure）

    // 輸出 stream
    output reg                       dout_valid,   // 輸出有效（STEADY 期間恆為 1）
    output reg  [MANTISSA_BITS-1:0]  dout_mantissa,// 有號 mantissa
    output reg  [EXP_BITS-1:0]       dout_exp,    // shared exponent（每 block 第一筆輸出時更新）
    output reg                       dout_last    // block 最後一筆 pulse（持續 1 cycle）
);
```

### 信號說明

| 信號 | 方向 | 說明 |
|------|------|------|
| `clk` | in | 系統時脈 |
| `rst_n` | in | 非同步 reset（低有效） |
| `din_valid` | in | 高時 `din` 有效，RTL 接收並處理 |
| `din` | in | 16-bit 有號樣本（2's complement，範圍 [-32768, 32767]） |
| `din_ready` | out | 目前恆為 1；支援 back-pressure 後才有意義 |
| `dout_valid` | out | STEADY 狀態下 `din_valid` 時恆為 1；INIT 期間為 0 |
| `dout_mantissa` | out | 量化後的有號 mantissa，[MANTISSA_BITS-1:0] |
| `dout_exp` | out | 當前 block 的 shared exponent，每 block 第一筆起固定不變 |
| `dout_last` | out | 每個 block 最後一筆資料輸出時拉高 1 cycle |

---

## 3. 參數與衍生常數

| 名稱 | 計算方式 | 預設值（BLOCK_SIZE=32, M=4） |
|------|----------|------------------------------|
| `ASIZE` | `$clog2(BLOCK_SIZE)` | 5 |
| `ABS_W` | `DATA_WIDTH - 1` | 15 |
| `MAX_INT` | `(1 << (MANTISSA_BITS-1)) - 1` | 7 |
| `MIN_INT` | `-(1 << (MANTISSA_BITS-1))` | -8 |

---

## 4. 架構概觀

```
                ┌────────────────────────────────────────────────────────┐
  din ─────────►│ din_sat（-32768 飽和至 +32767）                        │
                │      │                   │                             │
                │      ▼                   ▼                             │
                │ abs_sample          u_ping / u_pong (fifomem)         │
                │      │              wdata = din_sat                    │
                │      ▼              waddr = raddr = cnt               │
                │ abs_max_cur         wclken = din_valid & ~wsel / wsel  │
                │  = max(abs_sample,  combinational rdata                │
                │        abs_max_reg[wsel])                              │
                │      │                                                 │
                │      ▼                                                 │
                │    LZD  ──► e_base ──► thresh check ──► e_new         │
                │                         (at cnt_last, latch e_reg[wsel])│
                │                                                        │
                │  proc_rdata = wsel ? ping_rdata : pong_rdata          │
                │      │                                                 │
                │      ▼                                                 │
                │  sign_ext ──► round ──► barrel_shift(e_cur) ──► clip │
                │                                                        │
                │  ──► dout_mantissa, dout_exp, dout_valid, dout_last   │
                └────────────────────────────────────────────────────────┘
```

**核心原則**：cnt 同時作為 ping/pong 的 waddr 和 raddr，讓填寫 buf[wsel] 和讀取 buf[~wsel] 在同一個 cycle 內以同一個地址並行運作，達到零氣泡吞吐。

---

## 5. Ping-Pong Buffer

使用兩個 `fifomem` instance（`u_ping`、`u_pong`），每個深度 BLOCK_SIZE、寬度 DATA_WIDTH。

| 角色 | 條件 | 說明 |
|------|------|------|
| 寫入 ping | `wsel = 0` | wclken = din_valid & ~wsel |
| 寫入 pong | `wsel = 1` | wclken = din_valid & wsel |
| 讀取（處理） | `proc_rdata` | wsel=1 → ping_rdata；wsel=0 → pong_rdata |

`fifomem` 特性：
- **Write**：同步（posedge wclk 且 wclken=1 時寫入）
- **Read**：組合邏輯（`rdata = mem[raddr]`，當 cycle 即時可讀）

waddr = raddr = cnt（5 bits，0..31），兩者獨立：寫入端與讀取端使用同一地址但操作不同 buffer，不存在讀寫衝突。

---

## 6. 狀態機

```
      rst_n 解除
          │
          ▼
    ┌─────────────┐
    │   S_INIT    │  wsel=0, cnt 0→31
    │             │  填 buf[0], 追蹤 abs_max[0]
    │             │  dout_valid = 0
    └──────┬──────┘
           │ cnt == BLOCK_SIZE-1
           │ → latch e_reg[0], clear abs_max[0], wsel←1, state←STEADY
           ▼
    ┌─────────────────────────────────┐
    │           S_STEADY              │
    │  每 cycle（din_valid=1 時）：    │
    │  ┌ 寫入 buf[wsel][cnt] ← din   │
    │  ├ 追蹤 abs_max[wsel]           │
    │  └ 讀出 buf[~wsel][cnt]         │
    │    → round → shift → clip       │
    │    → dout_mantissa, dout_valid  │
    │                                 │
    │  cnt == BLOCK_SIZE-1 時：        │
    │  → e_reg[wsel] ← e_new         │
    │  → abs_max[wsel] ← 0           │
    │  → wsel ← ~wsel                │
    │  → dout_last ← 1               │
    └─────────────────────────────────┘
```

### 狀態轉換條件

| 當前狀態 | 條件 | 下一狀態 |
|----------|------|----------|
| S_INIT | cnt == BLOCK_SIZE-1 且 din_valid | S_STEADY |
| S_STEADY | — | S_STEADY（保持） |
| 任意 | rst_n = 0 | S_INIT（非同步 reset） |

---

## 7. 資料路徑細節

### 7.1 輸入飽和（din_sat）

```
din = -32768 (16'h8000)  →  din_sat = +32767 (16'h7FFF)
din = 其他值              →  din_sat = din
```

目的：-32768 在 2's complement 中無正數對應，abs 計算會溢位。飽和後與 Python golden model 行為一致。

### 7.2 Absolute Value（abs_sample）

```
din = -32768  → abs_sample = 32767 (飽和)
din < 0       → abs_sample = ~din[14:0] + 1  (取反加一)
din ≥ 0       → abs_sample = din[14:0]
```

用途：追蹤 block 內的 abs_max。

### 7.3 abs_max 追蹤

```
abs_max_cur = max(abs_sample, abs_max_reg[wsel])  // combinational
```

每 cycle 更新 abs_max_reg[wsel]（非阻塞）。使用 `abs_max_cur` 而非 `abs_max_reg` 計算 e_new，確保第 32 個 sample 也納入。

block 結束時清零：`abs_max_reg[wsel] ← 0`（為下個 block 做準備）。

### 7.4 Shared Exponent 計算（兩階段）

**Stage 1：從 LZD 取得初始估計**

```
lzc_val = lzc15(abs_max_cur)   // 15-bit casez priority encoder，0..15
msb_pos = 14 - lzc_val         // MSB 位置（0-indexed）
e_base  = max(0, msb_pos - (MANTISSA_BITS - 2))
```

**Stage 2：覆蓋率確認（修正 max_int 非 2 次方的誤差）**

```
thresh32 = MAX_INT << e_base       // e.g. 7 << 12 = 28672
e_new = 0              if abs_max_cur == 0
      = e_base          if thresh32[ABS_W-1:0] >= abs_max_cur
      = e_base + 1      otherwise
```

**說明**：LZD 只能精確定位 abs_max 的 MSB 位置，但 MAX_INT = 2^(M-1)-1 並非 2 的次方，因此 `e_base` 可能少 1。Stage 2 用乘法確認覆蓋，必要時加 1。

Block 結束時 latch：`e_reg[wsel] ← e_new`（與 abs_max 清零同一 posedge）。

### 7.5 Barrel Shift + Round + Clip

讀取正在輸出的 buffer：`proc_rdata = wsel ? ping_rdata : pong_rdata`

```
e_cur    = e_reg[~wsel]                     // 當前 block 的 exponent
sample_r = proc_rdata（有號 16-bit）
sample_ext = sign_extend(sample_r, 17 bits) // 明確符號擴展，避免無號運算

// Round-to-nearest（加半個 LSB）
rounded = sample_ext + (e_cur > 0 ? (1 << (e_cur - 1)) : 0)

// Arithmetic right shift
shifted = rounded >>> e_cur                 // 17-bit 有號算術右移

// Clip
mantissa_next = MAX_INT  if shifted > MAX_INT
              = MIN_INT  if shifted < MIN_INT
              = shifted[MANTISSA_BITS-1:0]  otherwise
```

結果於下一 posedge latch 至 `dout_mantissa`。

---

## 8. 時序圖

```
Cycle:       0  1  2 ... 31 | 32 33 34 ... 63 | 64 65 ... 95
             ───────────────────────────────────────────────
State:       [───── INIT ──] [──────── STEADY ────────────→
wsel:         0              1                  0
寫入端:       [── ping[0..31] ──] [── pong[0..31] ──] [── ping ─
讀取端:       (無)           [── ping[0..31] read ──] [── pong ─
abs_max 追:  max[0]          max[1]              max[0]
e_new latch: ↑(t=31)         ↑(t=63)             ↑(t=95)
             e_reg[0]←e0     e_reg[1]←e1         e_reg[0]←e2
dout_valid:  0 0 0 ... 0    1 1 1 ... 1          1 1 ... 1
dout_last:                               ↑(t=63)           ↑

輸出對應關係：
  dout at cycle 32..63  → block 0 的量化結果（使用 e_reg[0]）
  dout at cycle 64..95  → block 1 的量化結果（使用 e_reg[1]）
  ...
```

**啟動延遲**：第一個 block 輸出需等待 BLOCK_SIZE（32）個 cycle 的 INIT 填充，之後每 BLOCK_SIZE cycle 輸出一個完整 block，吞吐量 = 1 sample/cycle。

---

## 9. 編碼規則與假設

| 項目 | 規定 |
|------|------|
| 語言 | Verilog（非 SystemVerilog） |
| 時脈 | 單時鐘域，`always @(posedge clk)` |
| Reset | 非同步低有效 `rst_n` |
| 輸出暫存 | `dout_*` 均為 registered（不是組合輸出） |
| din_valid | 目前假設在 INIT 與 STEADY 期間持續為 1 |
| din_ready | 恆為 1（下游可無限接收） |
| -32768 處理 | 飽和至 +32767（abs_max 追蹤與 buffer 寫入均使用飽和值） |

---

## 10. 依賴模組

| 模組 | 路徑 | 用途 |
|------|------|------|
| `fifomem` | `../commonlib/fifomem.v` | Ping-pong buffer 的底層 SRAM（組合讀、同步寫） |

**編譯時需一起傳入**：
```bash
iverilog ... rtl/bfp_encoder.v ../commonlib/fifomem.v
```
