# Hardware Tradeoff Report — 硬體設計含義分析

審查時間：2026-05-01  
前提：基於 `correctness_report.md` 的程式碼分析推導。尚未取得真實矽實測數據。  
製程假設：**28nm CMOS, 1 GHz target clock**（僅用於相對估算，絕對數值需重新驗算）

> **Tentative 標記**：凡硬體成本估算，均為數量級估算（order-of-magnitude），非精確 gate count。

---

## 3.1 Encoder 硬體成本對比

### BFP Encoder（Uniform, `uniform_bfp` 函式）

程式碼對應的硬體操作序列：

1. **AbsMax Tree**：計算 `np.max(np.abs(block))`  
   - block_size=32：31 個 abs+comparator，樹深 log₂(32) = 5 層
   - 每個 comparator：~2 FO4 delay
   - Gate count（tentative）：31 × 16 = ~500 NAND2 equivalents（對 16-bit 輸入）

2. **Leading-Zero Detection（LZD）/ Priority Encoder**：推導 shared exponent `e`  
   - 輸入：16-bit max_val
   - 輸出：5-bit exponent（`ceil(log2(max_val))`）
   - Gate count（tentative）：~100 NAND2 eq.
   - Latency：~3 FO4 delay（log₂(16) = 4 層，可並行）

3. **Barrel Shifter × 32**：`round(block / 2^e)` → mantissa  
   - 每個 shifter：16-to-N bit barrel shift
   - Gate count（tentative）：32 × 4 × N ≈ 128N NAND2 eq.（N = mantissa_bits）
   - Latency：~4 FO4 delay（log₂(16) 層 MUX）

**BFP Critical Path**：AbsMax(5) → LZD(3) → Barrel Shift(4) ≈ **12 FO4 delays**  
（對應 28nm 約 ~1.5 ns，頻率 ~667 MHz；pipeline 可達 1 GHz+）

---

### Lloyd-Max Encoder

程式碼對應的編碼方式（從 `np.digitize` 推導）：

```python
indices = np.digitize(normalized_block, boundaries)  # 等效：parallel boundary comparison
```

這等效於硬體的 **boundary table + parallel comparators** 方式：

**Lloyd-Max (Max normalization)** 完整流程：

1. **AbsMax**（同 BFP step 1）：`max_val = np.max(np.abs(block))`  
   - 與 BFP 相同：~500 NAND2 eq.，5 層

2. **Division by max_val** ：`normalized = block / max_val`  
   - 32 個除法器（floating-point or fixed-point）
   - **這是最昂貴的部分**！32-bit FP division：~500–1000 NAND2 eq. per divider
   - 替代方案：用 LZD 結果做 barrel shift（將 division 化為 shift），可大幅降低成本
   - 若用 shift 近似（block max rounded to power-of-2）：~4 FO4 delay
   - 若用真正除法器：~20–30 FO4 delay（critical path 殺手）

3. **Boundary Comparison × (2^N - 1) parallel**：  
   - 4-bit：15 個 comparator 並行 → 速度快，面積小
   - 8-bit：255 個 comparator 並行 → 面積顯著增加
   - Gate count（tentative）：`(2^N - 1)` × 16 NAND2 eq. per comparator

4. **Priority Encoder**：comparator 輸出 → N-bit index  
   - 4-bit：15-to-4 priority encoder，~50 NAND2 eq.
   - 8-bit：255-to-8 priority encoder，~800 NAND2 eq.（或用 binary tree）

**Lloyd-Max (Sigma normalization)** 額外成本：

- 計算 `sigma = np.std(block)` 需要：
  - 32 次乘法（求平方）+ 1 次加法樹 + 1 次除以 N + 1 次 sqrt
  - **sqrt 是硬體噩夢**：最簡單的 sqrt 電路需要 ~10 個迭代除法，延遲數十個 cycle
  - 替代方案：LUT-based sqrt（犧牲精度，但常見），或用 SAD（sum of absolute deviation）近似 sigma
  - Sigma normalization 在硬體上不建議，除非有 dedicated FP unit

---

### Encoder 對比表格

| 方法 | 關鍵硬體操作 | Area（tentative, NAND2 eq.） | Latency（FO4）| 注意事項 |
|------|------------|--------------------------|--------------|---------|
| BFP（Uniform） | AbsMax + LZD + BarrelShift×32 | ~500 + 100 + 128N | ~12 | 面積與 bit-width N 線性，適合 pipeline |
| Lloyd-Max（Max norm, 4-bit） | AbsMax + Shift×32 + 15 comparators | ~500 + 128N + 240 + 50 | ~12–15 | 與 BFP 面積相近 |
| Lloyd-Max（Max norm, 8-bit） | AbsMax + Shift×32 + 255 comparators | ~500 + 128N + 4080 + 800 | ~12–15 | 面積隨 2^N 指數成長！ |
| Lloyd-Max（Sigma norm） | Var+sqrt + comparators | ~2000+ per sqrt | ~30–50 | **Sigma 路徑硬體不友善** |

**關鍵觀察**：
- 4-bit 時，Lloyd-Max(Max) ≈ BFP 面積
- 8-bit 時，Lloyd-Max(Max) 面積 **3–5× BFP**（comparator 數量從 15 → 255）
- Sigma normalization 的 sqrt 硬體成本遠大於 Max normalization

---

## 3.2 Decoder 硬體成本對比

| 方法 | Decoder 操作 | Area（tentative） | Latency | 備注 |
|------|-------------|-------------------|---------|------|
| BFP | Barrel shift by shared_exp | ~128N NAND2 eq. | ~4 FO4 | 極簡單 |
| Lloyd-Max（Max） | LUT[N-bit index] → reconstruction value，然後 × max_val | N-bit ROM + 1 multiplier | ~5 FO4 | ROM 面積：2^N × 16 bit |
| Lloyd-Max（Sigma） | LUT + × sigma | 同上 + sigma storage | ~5 FO4 | — |

**LUT Storage**（tentative，以 16-bit reconstruction value 計）：

| Bit-width | Levels | LUT Size（bits） |
|-----------|--------|----------------|
| 4-bit | 16 | 16 × 16 = 256 bits |
| 6-bit | 64 | 64 × 16 = 1024 bits |
| 8-bit | 256 | 256 × 16 = 4096 bits |

Storage 成本可接受，但注意需要 **per-distribution** 的 LUT（Gaussian ≠ Laplacian），若需要支援多種分布，需多套 LUT。

---

## 3.3 Downstream 運算考量

程式碼未明確顯示 downstream 操作。以下分析兩種場景：

### 場景 A：MAC 運算（NN inference）

**BFP 的優勢極為顯著**：
- BFP 的 mantissa 是整數，多個 block 的 dot product 可以：
  1. 在 mantissa domain 做整數 MAC（不需要浮點）
  2. 最後一步用 shared exponent 對齊
  3. 這就是 MXFP4/MXFP6/MXFP8 的設計哲學
- 硬體：整數 MAC array，最後一層 exponent aligner

**Lloyd-Max 的問題**：
- Reconstruction values（codebook entries）是任意浮點數
- 做 dot product 需要先 dequantize（LUT lookup → FP value），再做 FP MAC
- FP MAC 面積比整數 MAC 大約 **5–10×**
- 或者：mantissa 存 index（整數），但需要先查表得到 FP value，才能做算術

**結論（場景 A）**：若 downstream 有 MAC 運算，BFP 的系統級優勢可能超過 Lloyd-Max 在 SQNR 上的優勢。

### 場景 B：儲存/傳輸後解壓（資料壓縮）

- 兩者都需要 decoder
- BFP decoder：barrel shift（簡單）
- Lloyd-Max decoder：LUT lookup + multiply（稍複雜）
- 差距較小，主要看 SQNR vs area 的 tradeoff

---

## 3.4 SQNR-per-Area Pareto 分析（Tentative）

**注意**：以下數字是基於程式碼分析和理論推導的估算。由於 Bug B3（BFP scale 非 power-of-2），實際 BFP SQNR 會比模擬值低 0.5–2 dB。Lloyd-Max 的 SQNR 在 Bug B1 修正後，相對 BFP 的優勢預計仍存在，但差距會縮小。

### 相對 SQNR 優勢估算（Gaussian 分布，matched codebook）

根據資訊理論，對 Gaussian 分布：
- Uniform quantizer SQNR ≈ `6.02 * N + 1.76` dB（N = bits，高分辨率近似）
- Lloyd-Max 相對 Uniform 的增益：約 `1.53` dB（與 bit-width 幾乎無關）

也就是說，Lloyd-Max 對 BFP 的 SQNR 優勢在任何 bit-width 下都約 **1.5 dB**（Gaussian matched）。

這 1.5 dB 相當於 BFP 多用約 **0.25 bit/sample**（because 6.02 dB/bit → 1.5/6.02 ≈ 0.25 bit）。

### Pareto 圖（ASCII，X=relative area, Y=SQNR gain over BFP）

```
SQNR gain (dB)
over BFP Uniform
    ^
2.0 |  [Gaussian matched]
    |   LM-4bit *
1.5 |   LM-6bit *  LM-8bit *
    |                           (SQNR gain 幾乎與 bit-width 無關)
1.0 |
    |   [Laplacian matched，BFP 使用 Gaussian codebook]
0.5 |   LM-4bit *   LM-6bit *   LM-8bit *
    |
0.0 +---+----------+----------+-----------> Area cost vs BFP Uniform
        4-bit       6-bit       8-bit
        ~1.0x       ~1.5x       ~4.0x
```

**解讀**：
- 4-bit：Lloyd-Max(Max) 面積 ≈ BFP，SQNR 多 1.5 dB → **Lloyd-Max 佔優**
- 6-bit：Lloyd-Max 面積 1.5×，SQNR 仍多 1.5 dB → **視 area budget 而定**
- 8-bit：Lloyd-Max 面積 4×，SQNR 仍多 1.5 dB → **BFP 佔優**（花 4× 面積換 1.5 dB 不值得）

**Distribution mismatch 下（待實驗確認）**：
- 若 mismatch degradation > 1.5 dB，BFP 在任何 bit-width 都佔優
- Variance mismatch（同形狀，不同 scale）：Lloyd-Max(Sigma) 完全免疫（sigma 自適應），Lloyd-Max(Max) 部分免疫，BFP 完全免疫
- Distribution shape mismatch（Gaussian → Laplacian）：Lloyd-Max 退化 1–3 dB（tentative），BFP 基本不退化

---

## 3.5 Robustness 評估（Tentative，待 mismatch 實驗後更新）

### Distribution Mismatch 預測（理論推導）

對 Gaussian-trained codebook 在 Laplacian 資料上測試：
- Laplacian 有更重的尾巴，Gaussian codebook 的 outer levels 相對稀疏
- 尾部值無法被有效表示 → SQNR 退化

理論估算（非實測）：
- 4-bit：退化 **1–2 dB**（tentative）
- 8-bit：退化 **0.5–1 dB**（tentative，因為 8-bit 有足夠的 levels 覆蓋尾部）

若退化 ≥ 1.5 dB，Lloyd-Max 在 mismatch 場景下喪失對 BFP 的所有優勢。

### 是否需要 Multi-Codebook + Selector？

如果 application 資料分布不固定，需要：
- 2–4 套 codebook（Gaussian, Laplacian, heavy-tail 等）
- Per-block distribution classifier（增加 encoder 複雜度）
- Codebook selector bits（增加 metadata overhead）

**這個設計的硬體成本**：
- Codebook storage × K（K = 套數）：K × 4096 bits（8-bit）
- Classifier：計算 kurtosis 或 tail ratio，~500 NAND2 eq.（tentative）
- 總計：面積增加 **2–5×**（視 K 而定）

**結論（Tentative）**：除非 application 對 SQNR 要求極高（容忍不了 1 dB 退化），否則 multi-codebook 的硬體成本不值得。BFP 的 robustness 更適合不確定分布的場景。

---

## 3.6 設計建議

### 明確建議

> 以下建議是基於程式碼分析和理論推導的 **tentative** 結論。  
> **需要先完成 experiment_coverage_report.md 的 Gap 1（mismatch 實驗）才能確認。**

| 場景 | Bit-width | 資料特性 | 建議方案 | 理由 |
|------|-----------|---------|---------|------|
| NN inference（MAC downstream） | 任何 | 任何 | **BFP（Uniform）** | Mantissa 整數 MAC 的系統優勢遠超 1.5 dB SQNR 差距 |
| 資料儲存/傳輸 | 2–4 bit | 已知 Gaussian 分布 | **Lloyd-Max（Max norm）** | 面積相近，SQNR 多 1.5 dB |
| 資料儲存/傳輸 | 5–8 bit | 已知 Gaussian 分布 | **BFP（Uniform）** | Lloyd-Max 面積代價 > SQNR 效益 |
| 資料儲存/傳輸 | 任何 | 未知/混合分布 | **BFP（Uniform）** | Robustness 優先，Lloyd-Max 在 mismatch 退化明顯 |
| 資料儲存/傳輸 | 任何 | 已知重尾分布（Laplacian） | **Lloyd-Max（Laplacian codebook）** | 待 mismatch 實驗確認 |

**最重要的設計原則**：  
不要選 **Sigma normalization** 做硬體。計算 sigma 需要 sqrt，這是硬體的 critical path 殺手。一律使用 **Max normalization**（BFP 或 Lloyd-Max(Max)）。

---

### 不確定的部分（需要後續驗證）

| 問題 | 需要什麼才能回答 |
|------|----------------|
| Mismatch 時 Lloyd-Max 退化多少 dB？ | 執行 experiment_coverage_report.md Gap 1 |
| BFP SQNR 在 power-of-2 exponent 限制下損失多少？ | 修正 Bug B3 後重跑 |
| 最佳 block_size 是多少？ | 執行 block size sweep |
| `input.txt` 的資料是什麼分布？ | 讀取並分析 |
| 在實際 application SQNR loss 對 task accuracy 的影響？ | 需要 application-specific evaluation |

---

## 附錄：硬體估算假設

| 假設項目 | 數值 |
|---------|------|
| 製程 | 28nm CMOS（相對估算） |
| Standard cell NAND2 equivalent | 4 FO4 = 1 logic level |
| Barrel shifter（16-bit, N output） | 4 × N NAND2 eq. per shifter |
| 16-bit fixed-point comparator | ~16 NAND2 eq. |
| 16-bit integer multiplier（MAC用） | ~500 NAND2 eq. |
| FP32 multiplier | ~3000–5000 NAND2 eq. |
| sqrt（16-bit input，8-bit output） | ~1000–2000 NAND2 eq.（LUT-based） |

所有面積數字為數量級估算（± 2×），不能作為 RTL 綜合的依據。
