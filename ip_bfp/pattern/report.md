# BFP vs Lloyd-Max 軟體模擬報告

**日期**：2026-05-02  
**模擬腳本**：`bfp_sim_optimal.py`（seed=42，結果可重現）

---

## 1. 模擬設定

| 項目 | 值 |
|------|----|
| 輸入資料 | 16-bit 有號整數，高斯分布（σ = 8192），clip 至 [−32768, 32767] |
| 樣本數 | 訓練集 1,024,000 / 測試集 1,024,000（完全獨立） |
| Block size | 32 samples/block |
| 評估指標 | SQNR（dB）= 10 log₁₀(signal power / quantization noise power) |
| 測試 bit-width | 2, 3, 4, 6, 8 bit |

---

## 2. 三種方法定義

### BFP Ideal（理論上界，硬體不可實現）

- Scale = `max_val / max_int`，其中 `max_int = 2^(M-1) − 1`
- Scale 為任意浮點數，等效假設 exponent 可以是任意實數
- 用途：作為 BFP 的理論性能天花板

### BFP Hardware（硬體精確版）

- Scale = `2^e`，`e = ⌈log₂(max_val / max_int)⌉`（power-of-2 約束）
- 等效硬體操作：AbsMax tree → Leading-Zero Detection (LZD) → Barrel Shift
- Shared exponent `e` 為整數，每個 block 傳輸一次（5 bits 足夠）
- **這是實際 RTL 實作的對象**

### Lloyd-Max（Max normalization，最優非均勻量化）

- 先以 block maximum 正規化至 [−1, 1]，再用 Lloyd-Max codebook 量化
- Codebook 以高解析度直方圖（empirical PDF）訓練，迭代收斂（tol = 1e-6）
- 訓練集與測試集完全獨立（避免 in-sample bias）
- 量化 level 集中在高機率區域（Gaussian 中心），比均勻量化更有效率

---

## 3. SQNR 結果

（Gaussian 分布，block_size=32，seed=42）

| Bits | BFP Ideal (dB) | BFP HW (dB) | HW vs Ideal | Lloyd-Max (dB) | LM vs HW BFP |
|------|---------------|-------------|-------------|----------------|--------------|
| 2    | 3.643         | 1.166       | −2.478      | 9.461          | **+8.296**   |
| 3    | 12.889        | 9.819       | −3.070      | 15.476         | **+5.657**   |
| 4    | 20.259        | 16.853      | −3.405      | 21.773         | **+4.920**   |
| 6    | 33.183        | 29.427      | −3.757      | 33.648         | **+4.221**   |
| 8    | 45.432        | 41.631      | −3.801      | 45.545         | **+3.915**   |

每增加 1 bit，SQNR 約增加 6 dB（符合理論值 6.02 dB/bit）。

---

## 4. 關鍵發現

### 4.1 BFP Hardware 的固定代價：~3.5 dB

Power-of-2 exponent 使得 scale 幾乎必然大於 `max_val`，量化步長因此比最佳值大。
在 Gaussian 分布下：
- 最壞情況（max_val 剛過 2^(e−1) 門檻）：scale ≈ 2× 最佳，SQNR 掉 6 dB
- 平均損失（實測）：**~3.5 dB**，與理論 E[20 log₁₀(2^e / max_val)] ≈ 3 dB 吻合

此代價是硬體 BFP 的必然成本，無法透過軟體最佳化消除。

### 4.2 Lloyd-Max 的優勢來源

Lloyd-Max 相對 BFP Hardware 的總優勢 = 兩部分疊加：

| 來源 | 大小 |
|------|------|
| 非均勻量化對均勻量化的理論增益（Gaussian） | ~1.5 dB |
| BFP Hardware power-of-2 代價 | ~3.5 dB |
| **合計** | **~5 dB**（低 bit-width 更大） |

2-bit 時優勢達 8.3 dB，因為低 bit-width 時非均勻量化的相對效益更高。

### 4.3 Sigma normalization 不適合硬體

`bfp_sim.py` 中的 Sigma 正規化 Lloyd-Max 在 ≥4-bit 時**輸給** BFP Ideal：

| Bits | BFP Ideal | Sigma-LM |
|------|-----------|---------|
| 4    | 20.3 dB   | 20.1 dB |
| 6    | 33.2 dB   | 28.7 dB |
| 8    | 45.4 dB   | 36.6 dB |

原因：計算 σ 需要 sqrt（硬體 critical path），且 block/σ 的分布並非嚴格 Gaussian（Student-t 效應），導致 codebook mismatch 隨 bit-width 增加而惡化。

---

## 5. 硬體設計建議

| 場景 | 建議方案 | 理由 |
|------|---------|------|
| NN inference（有 MAC downstream） | **BFP Hardware** | 整數 mantissa 直接做 MAC，省去 FP 運算（面積差 5–10×） |
| 純儲存/傳輸，2–4 bit，已知 Gaussian | Lloyd-Max（Max norm）可考慮 | 面積相近，SQNR 多 5 dB |
| ≥5 bit 或分布未知 | **BFP Hardware** | Lloyd-Max 面積代價 3–5×，robustness 差 |
| 任何場景 | **禁用 Sigma normalization** | sqrt 是 critical path 殺手，且性能劣於 BFP |

BFP Hardware Encoder 關鍵路徑估算（28 nm，1 GHz target）：

```
AbsMax tree (log₂32 = 5 層) → LZD (3 層) → Barrel Shift (4 層) ≈ 12 FO4 ≈ 1.5 ns
可 pipeline 至 1 GHz+
```

---

## 6. 已知限制與後續實驗

下列實驗尚未完成，結論在這些條件下可能不同：

| 缺失實驗 | 重要性 | 預期影響 |
|---------|--------|---------|
| Distribution mismatch（Gaussian train → Laplacian test） | 極高 | Lloyd-Max 可能退化 1–3 dB，喪失對 BFP 的優勢 |
| Block size sweep {8, 16, 32, 64, 128} | 高 | 影響 BFP exponent overhead 和最佳 block_size 選擇 |
| 真實 application 資料（input.txt 尚未使用） | 高 | 最具說服力的評估 |
| Variance mismatch（1.5×, 2×） | 中 | Lloyd-Max（Sigma）自適應，Lloyd-Max（Max）部分自適應 |

---

## 7. 修正記錄（本次模擬前修復的 Bug）

| 編號 | 嚴重度 | 內容 | 影響 |
|------|--------|------|------|
| B1 | Critical | `bfp_sim_optimal.py` 訓練/測試用同一份資料 | Lloyd-Max SQNR 偏高 0.1–0.5 dB |
| B2 | High | Lloyd-Max 收斂時返回過期的 boundaries | 極罕見的系統性誤差 |
| B3 | High | BFP 使用 float scale（非 power-of-2）→ 新增 HW 版本 | BFP 原本 SQNR 偏高 0.5–3 dB |
| B5 | Minor | Clip 範圍 [−max_int, max_int] 少用一個 level | 浪費 2^(M-1) code，2-bit 損失 ~1.2 dB |
