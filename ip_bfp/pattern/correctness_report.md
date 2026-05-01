# Correctness Report — BFP vs Lloyd-Max 模擬程式碼審查

審查時間：2026-05-01  
審查檔案：`bfp_sim.py`、`bfp_sim_exp.py`、`bfp_sim_optimal.py`

---

## 總覽

| 編號 | 嚴重度 | 檔案 | 行號 | 標題 |
|------|--------|------|------|------|
| B1 | **CRITICAL** | `bfp_sim_optimal.py` | 104-106, 118-121 | 訓練/測試資料洩漏 |
| B2 | **HIGH** | `bfp_sim_optimal.py` | 44, 74-78 | 收斂時返回過期的 `boundaries` |
| B3 | **HIGH** | 全部三個檔案 | 見下方 | BFP scale 非 power-of-2，SQNR 偏樂觀 |
| B4 | MEDIUM | `bfp_sim.py` L40, `bfp_sim_exp.py` L35/54 | 40, 35, 54 | 低 bit-width 訓練樣本數不足 |
| B5 | MINOR | 全部三個檔案 | 見下方 | `clip` 範圍少用一個 level |
| W1 | 需要釐清 | `bfp_sim_optimal.py` | 33 | histogram 排除恰好等於 1.0 的值 |
| W2 | Dead code | `bfp_sim_optimal.py` | 47, 50 | `full_boundaries` 與 `max_shift` 從未使用 |
| W3 | 可重現性 | 全部三個檔案 | — | 沒有 random seed |
| W4 | 缺失 | 全部三個檔案 | — | 沒有 bit budget / 壓縮率計算 |

---

## 1.1 BFP 實作檢查

### Block max 計算
**PASS**（含 edge case）  
`bfp_sim.py:21`、`bfp_sim_exp.py:21`、`bfp_sim_optimal.py:14`

```python
max_val = np.max(np.abs(block))
if max_val == 0:
    return block   # 全零 block → 直接返回，不做量化
```

全零 block 有處理。`np.abs()` 後取 max，正確。

---

### Shared exponent 推導
**需要釐清（FAIL 對硬體模擬準確性）— Bug B3**

```python
# bfp_sim.py:28-29
max_int = (1 << (bits - 1)) - 1   # e.g. 8-bit → 127
scale = max_val / max_int          # 浮點除法，非 power-of-2！
```

**問題**：硬體 BFP 的 shared exponent 是整數 `e`，對應的縮放因子為 `2^e`。程式碼使用任意浮點 `max_val / max_int`，相當於假設 exponent 可以是任意實數。這給出比真實硬體更好的 SQNR（最佳化偏差）。

等價的硬體正確版本應為：
```python
import math
e = math.ceil(math.log2(max_val)) if max_val > 0 else 0
e = max(e, -(2**(exp_bits-1)))  # 飽和處理
e = min(e, (2**(exp_bits-1))-1)
scale = 2 ** (e - (bits - 1))   # mantissa 最高位對應 2^e
```

**影響**：目前模擬的 SQNR 會比實際硬體高 0.5–2 dB，視 block 內最大值的分布而定。**在所有三個檔案中。**

---

### Mantissa 量化
**PASS（rounding mode）、MINOR BUG（clip 範圍）**

`np.round()` 使用 banker's rounding（round-half-to-even），行為已知、數學合理，但未在 code 中明確記錄。

**Bug B5（MINOR）**：
```python
# bfp_sim.py:26, 33
max_int = (1 << (bits - 1)) - 1   # 8-bit → 127
quantized = np.clip(quantized, -max_int, max_int)  # clip 到 [-127, 127]
```

Two's complement 的 8-bit 範圍是 `[-128, 127]`，但程式碼 clip 到 `[-127, 127]`，浪費了 `−2^(bits-1)` 這個 code。有效 levels 數為 `2*max_int + 1 = 2^bits - 1` 而非 `2^bits`。損失約 `20*log10(2^bits / (2^bits - 1)) ≈ 0.05 dB`（對 8-bit 而言微小，但對 2-bit 約 1.2 dB）。

正確寫法：
```python
quantized = np.clip(quantized, -(1 << (bits - 1)), (1 << (bits - 1)) - 1)
```

---

### Dequantization 路徑
**PASS（功能正確，但不模擬硬體精度）**

```python
return quantized * scale   # = round(block / scale) * scale
```

還原公式正確：`dequantized = mantissa_int * (max_val / max_int)`。  
與 Bug B3 相關：硬體中 scale 會是 `2^e`，但這裡是浮點乘法，不存在 off-by-one 問題。

---

### Block 邊界（最後一個非整數 block）
**PASS**

```python
# bfp_sim.py:93-94
num_blocks = data_length // block_size
data = data[:num_blocks * block_size]  # 截去尾巴
```

直接截去最後不足一個 block 的資料。此做法安全，但截去的樣本數沒有記錄。對 `data_length=102400, block_size=32`，恰好整除，無影響。

---

### Bit budget 統計
**FAIL — 缺失功能**

三個檔案均未計算壓縮率。應包含：
```
total_bits = N * mantissa_bits + (N / block_size) * shared_exp_bits
bits_per_sample = total_bits / N
```

共享 exponent（或 scale）的 overhead 完全未納入比較。這對 SQNR-per-bit 的分析是致命缺失。

---

## 1.2 Lloyd-Max 實作檢查

### Codebook 訓練 — 訓練/測試分離
**FAIL（Critical Bug B1）— 僅影響 `bfp_sim_optimal.py`**

```python
# bfp_sim_optimal.py:104-106, 118-121
training_data = (blocks / block_maxes).flatten()   # 來自同一份 data!

c_opt, b_opt = lloyd_max_1d_histogram(training_data, bits)  # 用 training_data 訓練
rec_opt = np.array([non_uniform_bfp_optimal(b, c_opt, b_opt) for b in blocks]).flatten()  # 用同一份 blocks 測試
sqnr_opt = calculate_sqnr(flatten_data, rec_opt)   # In-sample evaluation!
```

Codebook 在相同資料上訓練和評估。SQNR 數字因 in-sample overfitting 而偏高。  
資料量雖大（1,024,000 samples），經驗分布≈真實分布，實際偏差可能僅 0.1–0.5 dB，但方法論錯誤，違反計畫書 §1.2 的要求。

**修正**：拆分訓練集與測試集（例如 70%/30%），或用獨立 `np.random.randn` 生成訓練資料。

`bfp_sim.py` 和 `bfp_sim_exp.py` 的訓練資料是獨立的 `np.random.randn` 樣本，**PASS**。

---

### Iteration 收斂條件
**PASS（`bfp_sim_optimal.py`）、需要釐清（`bfp_sim.py` / `bfp_sim_exp.py`）**

`bfp_sim_optimal.py`：  
- `max_iter=100`，`tol=1e-6`（centroid 最大位移），明確且合理。

`bfp_sim.py` / `bfp_sim_exp.py`：  
- 使用 `scipy.kmeans2(iter=15)`，固定 15 次迭代，無收斂判斷。對於高 bit-width 或接近邊界的初始化，可能尚未收斂。

---

### Decision boundaries
**PASS**

```python
boundaries = (centroids[:-1] + centroids[1:]) / 2.0  # 中點
```

符合 Lloyd-Max 條件：`t_i = (y_i + y_{i+1}) / 2`。

---

### Centroid update（Lloyd-Max 條件 2）
**PASS（`bfp_sim_optimal.py`）、近似正確（k-means）**

`bfp_sim_optimal.py`：
```python
new_c = np.sum(bin_centers[mask] * pmf[mask]) / prob_sum  # 條件期望值（PDF 加權）
```

這是真正的 Lloyd-Max centroid 條件。**PASS**。

`bfp_sim.py` / `bfp_sim_exp.py` 使用 k-means（sample mean）估計條件期望值。樣本夠多時收斂至相同結果，但有抽樣噪音。

---

### Encoder 編碼方式（影響硬體估算）
**需要釐清**

```python
indices = np.digitize(normalized_block, boundaries)   # 比較所有 boundaries
```

`np.digitize` 是 linear scan（或 binary search 的封裝）。邏輯等效於硬體的 **boundary table（N-1 parallel comparators）** 方式。這是速度最快但面積最大的硬體實作。  
硬體設計時需要明確選擇：parallel comparators（快、大）或 binary search（慢、小）。

---

### PDF 假設與 Out-of-range 處理
**PASS（分布已記錄）、PASS（saturation）**

三個檔案均使用 Gaussian 分布訓練 codebook（`np.random.randn`）。  
`bfp_sim_optimal.py` 使用實測的 block-max-normalized empirical PDF，更接近真實硬體場景。

Out-of-range：`np.clip` 飽和到端點 centroid，行為正確。

---

### Bug B2：收斂時返回過期 boundaries（`bfp_sim_optimal.py`）
**FAIL — HIGH Severity**

```python
# bfp_sim_optimal.py:42-78
for iteration in range(max_iter):
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0   # 從 c_k 計算
    ...
    new_centroids = ...      # = c_{k+1}
    shift = np.max(np.abs(new_centroids - centroids))
    if shift < tol:
        break                # 此時 centroids = c_k，boundaries = midpoints(c_k)
                             # new_centroids = c_{k+1} 被丟棄！
    centroids = new_centroids

return centroids, boundaries  # 返回 c_k 和 midpoints(c_k) — 一致，但不是最好的
```

**問題一（break 路徑）**：收斂時，`new_centroids`（= c_{k+1}）是更好的 centroid 估計，卻被丟棄。返回的是 c_k。誤差 O(tol) = O(1e-6)，實際影響微小。

**問題二（loop 耗盡路徑）**：若 100 次迭代未收斂（罕見但可能），`centroids` 已更新至 c_N，但 `boundaries` 還是上一輪計算的 midpoints(c_{N-1})。**返回的 centroids 和 boundaries 不一致！** 這會導致編碼時用 boundaries(c_{N-1}) 但 reconstruction 用 c_N，造成系統性誤差。

**修正**：
```python
if shift < tol:
    centroids = new_centroids   # 加這行！
    break
centroids = new_centroids
# 迴圈結束後重新計算：
boundaries = (centroids[:-1] + centroids[1:]) / 2.0
return centroids, boundaries
```

---

### Bug W1：histogram 排除恰好 1.0 的值
**需要釐清（MINOR）**

```python
# bfp_sim_optimal.py:33
hist, bin_edges = np.histogram(data, bins=num_bins, range=(-1.0, 1.0), density=True)
```

`np.histogram` 的最後一個 bin 是 `[edge[-2], edge[-1]]`（閉區間），其他 bins 是半開區間 `[left, right)`。因此恰好等於 1.0 的值**會被包含**（NumPy 特例）。  
但恰好等於 -1.0 的值（block 最大值為負數的情況）也應被包含（第一個 bin 是 `[edge[0], edge[1])`，-1.0 會被包含）。  
**實際上沒有問題**，但建議加 `range=(-1.0-1e-9, 1.0+1e-9)` 作為防禦性程式碼。

---

## 1.3 測試框架共用檢查

### SQNR 公式
**PASS**

```python
# 全部三個檔案
signal_power = np.mean(original ** 2)   # E[x²]（包含 DC，對零均值信號 = 方差）
noise_power = np.mean(noise ** 2)       # MSE
return 10 * np.log10(signal_power / noise_power)  # 功率比，正確
```

公式正確。注意是 power ratio（10 log10），不是 amplitude ratio（20 log10）。

---

### 公平性比對（Bit Budget）
**FAIL — 嚴重缺失**

| 方法 | 資料 bits/sample | Metadata bits/sample | 總計 |
|------|-----------------|---------------------|------|
| BFP (Uniform, block=32) | `mantissa_bits` | `exp_bits / 32` | `mantissa_bits + exp_bits/32` |
| Lloyd-Max (Sigma) | `codebook_bits` | `sigma_bits / 32` | `codebook_bits + sigma_bits/32` |
| Lloyd-Max (Max) | `codebook_bits` | `max_bits / 32` | `codebook_bits + max_bits/32` |

**目前程式碼的比對假設三種方法的總 bit budget 相同**（都用 `bits` 參數），但沒有明確計算 metadata overhead。如果 sigma 需要 FP32（32 bits）而 BFP exponent 只需要 8 bits，在 block_size=32 的情況下：
- BFP overhead = 8/32 = 0.25 bits/sample
- Lloyd-Max (Sigma) overhead = 32/32 = 1.0 bits/sample（如果 sigma 用 FP32）

這個差距等效於 **0.75 bits/sample 的額外 budget**，足以改變比較結果。

---

### Random seed
**FAIL — 缺失**

三個檔案均無 `np.random.seed()` 或 `rng = np.random.default_rng(seed=42)`。實驗結果不可重現，每次執行結果不同（SQNR 可能相差 0.1–0.3 dB）。

---

### Full-precision Baseline
**PASS（隱含）**

原始資料 `data` 保留為 float64，量化前後均有記錄，SQNR 相對於 `data`（ground truth）計算。技術上 baseline 已存在，但沒有明確標示「FP32 = 0 dB noise」的 baseline 行。

---

## 1.4 Summary：各 check 項目狀態表

| 計畫書 §1.1 / §1.2 Check | 狀態 | 備注 |
|--------------------------|------|------|
| Block max 使用 abs() 後取 max | PASS | — |
| 全零 block edge case | PASS | — |
| Shared exponent = power-of-2 | **FAIL** | B3：使用浮點 scale，非硬體 BFP |
| Exponent saturate/clip | 缺失 | B3 同：無 exponent bits 限制 |
| Round-to-nearest | PASS | np.round = banker's rounding，未記錄 |
| Mantissa overflow | PASS（有 clip） | B5：少用一個 level |
| Sign bit 處理 | 需要釐清 | 程式碼使用有號整數，符合 two's complement，但文件未記錄 |
| Dequantization 公式正確 | PASS | — |
| Block 邊界（非整數倍） | PASS | 截去尾巴 |
| Bit budget 計算 | **FAIL** | W4：完全缺失 |
| 訓練/測試分離（Lloyd-Max） | **FAIL**（optimal.py）/ PASS（其他） | B1 |
| 收斂條件 | PASS（optimal.py）/ 需要釐清（其他） | — |
| Decision boundaries = 中點 | PASS | — |
| Centroid = 條件期望值 | PASS（optimal.py）/ 近似（其他） | — |
| Encoder 方式（影響硬體） | 需要釐清 | np.digitize → parallel comparator 等效 |
| Out-of-range 飽和 | PASS | — |
| SQNR 公式正確 | PASS | — |
| 總 bit budget 相同（公平比對） | **FAIL** | W4：未計算 metadata overhead |
| Random seed | **FAIL** | W3 |
| FP32 baseline | PASS（隱含） | — |

---

## 必要修正（按優先順序）

### 修正 1（Critical）：解決訓練/測試洩漏 — `bfp_sim_optimal.py`

```python
# 在 run_optimal_experiment() 中，將 training_data 和 test blocks 分開
# 方法 A：用獨立資料生成訓練集
training_raw = np.random.randn(data_length)
training_raw = np.round(training_raw * 8192)
training_raw = np.clip(training_raw, -32768, 32767)
num_train_blocks = data_length // block_size
training_blocks = training_raw[:num_train_blocks*block_size].reshape(num_train_blocks, block_size)
train_maxes = np.max(np.abs(training_blocks), axis=1, keepdims=True)
train_maxes[train_maxes == 0] = 1.0
training_data = (training_blocks / train_maxes).flatten()
```

### 修正 2（High）：修正 `lloyd_max_1d_histogram` 返回值 — `bfp_sim_optimal.py`

```python
# 在 break 之前加上 centroids 更新，並在迴圈後重新計算 boundaries
for iteration in range(max_iter):
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0
    ...
    if shift < tol:
        centroids = new_centroids   # ← 加這行
        break
    centroids = new_centroids

boundaries = (centroids[:-1] + centroids[1:]) / 2.0   # ← 迴圈後重新計算
return centroids, boundaries
```

### 修正 3（High）：加入 power-of-2 exponent 版本的 BFP — 所有檔案

```python
def uniform_bfp_hardware(block, mantissa_bits, exp_bits=8):
    """硬體精確 BFP：shared exponent 限制為整數"""
    max_val = np.max(np.abs(block))
    if max_val == 0:
        return block, 0
    
    e = int(np.ceil(np.log2(max_val + 1e-15)))  # shared exponent（leading-zero detection）
    e = np.clip(e, -(1 << (exp_bits - 1)), (1 << (exp_bits - 1)) - 1)
    scale = 2.0 ** e / ((1 << (mantissa_bits - 1)) - 1)
    
    quantized = np.round(block / scale)
    max_int = (1 << (mantissa_bits - 1)) - 1
    quantized = np.clip(quantized, -max_int - 1, max_int)   # 修正 B5
    return quantized * scale, e
```

### 修正 4（Medium）：增加訓練樣本數下限 — `bfp_sim.py` / `bfp_sim_exp.py`

```python
# 原來：num_samples = min(max_samples, levels * 20)
# 修正：確保每個 level 有至少 1000 個樣本
num_samples = min(max_samples, max(levels * 1000, 10000))
```

### 修正 5（Minor）：加 random seed

```python
np.random.seed(42)   # 在所有 run_simulation() 的最開頭加上
```

### 修正 6（Minor）：修正 clip 範圍

```python
# 原來：np.clip(quantized, -max_int, max_int)
# 修正：
np.clip(quantized, -(1 << (bits - 1)), (1 << (bits - 1)) - 1)
```

---

## 結論

> **在修正 B1（訓練/測試洩漏）和 B3（非 power-of-2 scale）之前，Lloyd-Max 對 BFP 的 SQNR 優勢數字是不可信的。**  
> B2（boundaries 不一致）在實際使用中影響微小，但邏輯上有誤，應修正。  
> W3（無 random seed）和 W4（無 bit budget）是進行硬體決策前的必要補充。
