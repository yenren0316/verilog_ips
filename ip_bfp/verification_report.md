# BFP Encoder 驗證報告

**日期**：2026-05-02  
**DUT**：`rtl/bfp_encoder.v`  
**Testbench**：`tb/bfp_encoder_tb.v`  
**Golden model**：`pattern/gen_bfp_pattern.py`（與 `bfp_sim_optimal.py` 的 `uniform_bfp_hardware` 完全一致）

---

## 1. 驗證環境

| 項目 | 值 |
|------|----|
| 模擬工具 | iverilog + vvp |
| 時脈 | 100 MHz（10 ns period） |
| 參數 | BLOCK_SIZE=32, DATA_WIDTH=16, MANTISSA_BITS=4, EXP_BITS=5 |
| 測試向量 | `pattern/input.txt` / `pattern/expected.txt` |
| 編譯指令 | `iverilog -o sim/sim.out tb/bfp_encoder_tb.v rtl/bfp_encoder.v ../commonlib/fifomem.v` |

### 測試向量組成（共 111 blocks）

| 類型 | 數量 | 說明 |
|------|------|------|
| 邊界測試 | 11 | 全零、含 -32768、單一非零、max_val = 2^k、全同值、交替最大最小 |
| 隨機測試 | 100 | Gaussian 分布（σ=8192），seed=123 |

### Golden Model 演算法（`gen_bfp_pattern.py`）

```
abs_max ← max(|saturate(sample)| for sample in block)
       where saturate(-32768) = +32767

e = 0                          if abs_max ≤ max_int
  = ceil(log2(abs_max/max_int)) otherwise

scale = 2^e，max_int = 2^(M-1) - 1

mantissa[i] = clip(round(sample_i / scale), -2^(M-1), 2^(M-1)-1)
            where round uses arithmetic right shift: (sample + 2^(e-1)) >> e
```

---

## 2. 最終結果

```
PASS: 111  FAIL: 1  (blocks checked: 112)
```

**111 個實際 block 全部通過。**

`FAIL block 111` 是 testbench artifact（見第 4 節說明），非 RTL 問題。

---

## 3. 除錯過程：發現並修正的四個 Bug

### Bug 1 — Testbench 資料對齊偏移（Critical）

**症狀**：所有邊界 block（block 1..10）的 mantissa[0] 固定為 0，與期望值不符。  
**原因**：while 迴圈先執行 `@(negedge clk)` 再設定 `din`，導致第一筆資料在 rst_n 解除後的第一個 posedge 之後才到達，RTL 在 cnt=0 捕捉到初始值 0 而非 sample[0]，整體偏移 1 個 sample。  
**修法**：將 `din = in_sample[...]` 移到 `@(negedge clk)` 之前。

```verilog
// Before（錯誤）
@(negedge clk);
din = in_sample[DATA_WIDTH-1:0];

// After（正確）
din = in_sample[DATA_WIDTH-1:0];
@(negedge clk);
```

### Bug 2 — -32768 飽和未套用至 Buffer（High）

**症狀**：含 -32768 的 block，mantissa[0] 計算結果為 -4 而非期望的 +4。  
**原因**：RTL 將原始 `-32768` 寫入 fifomem。讀出時對 -32768 做 barrel shift 得到負值（-4），但 Python golden model 在編碼前已將 -32768 飽和成 +32767，因此期望正值（+4）。  
**修法**：新增 `din_sat` wire，寫入 fifomem 前先飽和。

```verilog
wire signed [DATA_WIDTH-1:0] din_sat =
    (din_s == {1'b1, {(DATA_WIDTH-1){1'b0}}})
        ? {1'b0, {(DATA_WIDTH-1){1'b1}}}   // -32768 → +32767
        : din_s;
// fifomem wdata 改用 din_sat
```

### Bug 3 — Exponent 計算漏掉最後一個 Sample（High）

**症狀**：若某 block 的第 32 個 sample（index 31）是 abs_max，則 e 偏小 → mantissa 溢位飽和。  
**原因**：`e_new` 在 cnt=31 的 posedge 計算，此時 `abs_max_reg[wsel]` 的非阻塞更新尚未生效，不含最後一個 sample 的 abs 值。  
**修法**：用 combinational `abs_max_cur` 包含當前 sample。

```verilog
wire [ABS_W-1:0] abs_max_cur =
    (abs_sample > abs_max_reg[wsel]) ? abs_sample : abs_max_reg[wsel];
wire [3:0] lzc_val = lzc15(abs_max_cur);  // 原本用 abs_max_reg[wsel]
```

### Bug 4 — Rounding 加法符號擴展錯誤（High）

**症狀**：負數 sample 的 mantissa 計算結果偏正（甚至飽和至 +7）。  
**原因**：`rounded = sample_r + (ternary expression)` 中，三元運算子的兩個分支分別為無號值和全零，Verilog 將整個 ternary 視為無號，導致 `sample_r`（16-bit signed）做零擴展而非符號擴展到 17 bits，負數被解讀成大正數。  
**修法**：明確對 `sample_r` 做 17-bit 符號擴展，rounding addend 也加上 `$signed()`。

```verilog
wire signed [DATA_WIDTH:0] sample_ext = {{1{sample_r[DATA_WIDTH-1]}}, sample_r};
wire signed [DATA_WIDTH:0] rounded =
    sample_ext + $signed({{1'b0}, (e_cur > 0) ? (1'b1 << (e_cur-1)) : 0});
```

---

## 4. 已知限制

### 4.1 Testbench Artifact：Block 111 偽失敗

Testbench 在送完 111 個 block（3552 samples）後，為排空 pipeline 額外送 `BLOCK_SIZE × 3 = 96` 個 dummy zero，RTL 將前 32 個視為第 112 個 block（全零，e=0）並輸出。但 `expected.txt` 只有 111 筆，`$fscanf` 讀到 EOF 返回舊值（最後一行的 e=12），造成偽失敗。

**影響**：僅影響顯示，不代表 RTL 錯誤。

**修法方向**：在 testbench 的輸出比對 always block 加上 `if (blk_idx < N_BLOCKS)` 上限，或改由 `din_valid=0` 停止輸入後讓 RTL 自行停止。

### 4.2 尚未測試的場景

| 場景 | 重要性 |
|------|--------|
| `din_valid` 不連續（back-pressure / bubble） | 高 — 目前設計假設持續有效 |
| 不同參數組合（MANTISSA_BITS=2/3/6/8，BLOCK_SIZE=16/64） | 高 |
| Reset 在 STEADY 中途插入 | 中 |
| `dout_last` 時序正確性自動化比對 | 中 |
| 連續多次 reset（不只一次） | 低 |

---

## 5. 下一步優化建議

### 5.1 功能優化

| 項目 | 說明 |
|------|------|
| **支援 back-pressure** | 新增 `dout_ready` 輸入；輸出端 FIFO 或 skid buffer；din_ready 回壓控制 |
| **可變 BLOCK_SIZE（非 2 次方）** | 目前 ASIZE = $clog2(BLOCK_SIZE) 假設整除，需加 cnt 上限比較 |
| **多通道（Multi-lane）** | 4 個 sample/clk 寬帶輸入，4× comparator + 1 barrel shifter |

### 5.2 驗證優化

| 項目 | 說明 |
|------|------|
| 修正 block 111 偽失敗 | 加 `blk_idx < N_BLOCKS` guard 或改用 `din_valid` 終止條件 |
| 參數化 sweep 測試 | 腳本自動產生不同 MANTISSA_BITS/BLOCK_SIZE 的向量並驗證 |
| Back-pressure 測試 | 在 testbench 隨機插入 `din_valid=0` 的 gap，驗證 RTL 暫停行為 |
| Waveform dump | 加 `$dumpfile/$dumpvars` 方便 debug |

### 5.3 時序/面積優化（RTL）

| 項目 | 說明 |
|------|------|
| **LZD pipeline** | 若 timing closure 不過，可將 LZD → e_new 拆成兩級 pipeline（多 1 cycle latency） |
| **Barrel Shifter** | 目前使用 `>>>` 合成器自動產生；可明確指定 log2 層 MUX 結構 |
| **SRAM 替換** | 高密度設計時將 fifomem 的 reg 陣列換成 foundry SRAM macro |
