# Experiment Coverage Report — 實驗設計審查

審查時間：2026-05-01  
基於：`correctness_report.md` 的發現

> 注意：此報告基於「已知 Bug B1/B3 存在」的現狀。下列 gap analysis 同時指出需要補的實驗，以及需要先修正 bug 才能信任的數據。

---

## 2.1 實驗覆蓋表格

### Bit-width 掃描

| Bit-width | bfp_sim.py | bfp_sim_exp.py | bfp_sim_optimal.py | 建議優先順序 |
|-----------|-----------|----------------|-------------------|------------|
| 2-bit     | ✗ 缺失    | ✗ 缺失         | ✗ 缺失            | 高（硬體極限） |
| 3-bit     | ✗ 缺失    | ✗ 缺失         | ✗ 缺失            | 高 |
| 4-bit     | ✗ 缺失    | ✓ 有           | ✓ 有              | — |
| 6-bit     | ✗ 缺失    | ✓ 有           | ✓ 有              | — |
| 8-bit     | ✓ 有      | ✓ 有           | ✓ 有              | — |
| 12-bit    | ✓ 有      | ✗ 缺失         | ✗ 缺失            | 低優先 |
| 14-bit    | ✓ 有      | ✗ 缺失         | ✗ 缺失            | 低優先 |

**狀態**：`bfp_sim.py` 只跑 {8, 12, 14}，對硬體設計最關鍵的低 bit-width 完全缺失。`bfp_sim_exp.py` 和 `bfp_sim_optimal.py` 跑了 {4, 6, 8}，較合理，但缺 {2, 3}。

**計畫書要求最少 {2, 3, 4, 6, 8}：PARTIAL（只有 exp/optimal 達到 4/6/8）**

---

### Block size 掃描（僅 BFP 相關）

| Block size | 任一檔案 | 備注 |
|------------|---------|------|
| 8          | ✗ 缺失  | — |
| 16         | ✗ 缺失  | — |
| 32         | ✓ 固定值 | 所有檔案硬碼為 32 |
| 64         | ✗ 缺失  | — |
| 128        | ✗ 缺失  | — |

**狀態：FAIL — 完全沒有 block size 掃描**  
Block size 直接影響 BFP 的壓縮率（exponent overhead = exp_bits/block_size）和 SQNR（block 越大，max 越大，量化雜訊越多）。這個掃描對硬體設計的 block_size 選擇至關重要。

---

### 輸入分布覆蓋

| 分布 | 任一檔案 | 備注 |
|------|---------|------|
| Gaussian（zero-mean, unit variance） | ✓ 有 | 三個檔案均有（scaled to 16-bit 範圍） |
| Laplacian | ✗ 缺失 | — |
| 實測 application 資料 | ✗ 缺失 | `input.txt` 存在但未被任何腳本讀取 |
| Uniform | ✗ 缺失 | 可作為 BFP 最佳情況 baseline |

**狀態：PARTIAL — 只有 Gaussian**  
Laplacian 分布在許多壓縮場景（speech, sparse activations）是主要分布，且對 Lloyd-Max 的優勢特別有利。缺失這個分布使比較結果難以一般化。

注意：`input.txt` 檔案存在，可能是真實 application 資料，但完全未被使用。**這是最重要的 gap**。

---

### 分布 mismatch 測試（Lloyd-Max 關鍵弱點）

| 測試項目 | 任一檔案 | 重要性 |
|---------|---------|--------|
| Gaussian train → Laplacian test | ✗ 缺失 | 極高 |
| Laplacian train → Gaussian test | ✗ 缺失 | 高 |
| variance mismatch 1.5× | ✗ 缺失 | 高 |
| variance mismatch 2× | ✗ 缺失 | 高 |
| outlier / heavy-tail（Cauchy, StudentT） | ✗ 缺失 | 中 |

**狀態：FAIL — 完全缺失**  
這是 Lloyd-Max vs BFP 比較中**最關鍵的實驗**。Lloyd-Max 在 matched distribution 下理論最優，但在 mismatch 下可能輸給 BFP。如果沒有這個測試，無法給出硬體設計建議。

---

## 2.2 必須記錄的指標

| 指標 | 目前狀態 | 備注 |
|------|---------|------|
| SQNR (dB) | ✓ 有 | 公式正確 |
| MSE | ✗ 缺失 | 可由 noise_power 直接輸出 |
| 壓縮率（含 metadata overhead） | ✗ 缺失 | 見 correctness_report.md Bug W4 |
| Task-level metric（NN accuracy 等） | ✗ 缺失 | 需要 application-specific 評估 |

---

## 2.3 Gap Analysis 與補充建議

### Gap 1（Critical）：分布 mismatch 實驗

**補充方式**：

```python
from scipy.stats import laplace

def generate_laplacian_data(data_length, scale=8192/np.sqrt(2)):
    """Laplacian with same variance as Gaussian(sigma=8192)"""
    data = laplace.rvs(scale=scale, size=data_length)
    return np.clip(np.round(data), -32768, 32767)

def run_mismatch_experiment():
    # 用 Gaussian 訓練 codebook
    g_centroids, g_boundaries = generate_lloyd_max_sigma(bits)
    
    # 在 Laplacian 資料上測試
    laplacian_data = generate_laplacian_data(data_length)
    sqnr_mismatch = evaluate(laplacian_data, g_centroids, g_boundaries)
    sqnr_matched = evaluate(laplacian_data, l_centroids, l_boundaries)  # Laplacian-trained
    
    print(f"SQNR degradation due to mismatch: {sqnr_matched - sqnr_mismatch:.2f} dB")
```

---

### Gap 2（High）：Block size 掃描

**補充方式**：

```python
def run_block_size_sweep(bits=4, block_sizes=[8, 16, 32, 64, 128]):
    results = {}
    for bs in block_sizes:
        # 計算真實的 bits_per_sample（含 shared exponent overhead）
        exp_bits = 8  # 假設 8-bit exponent
        bps = bits + exp_bits / bs
        sqnr = run_bfp_at_block_size(bits=bits, block_size=bs)
        results[bs] = {'sqnr': sqnr, 'bits_per_sample': bps}
    return results
```

關鍵輸出：SQNR vs bits_per_sample 的 Pareto，展示最佳 block_size 選擇。

---

### Gap 3（High）：Variance mismatch

```python
def run_variance_mismatch(train_sigma=1.0, test_sigmas=[1.0, 1.5, 2.0, 4.0]):
    # Lloyd-Max codebook 在 train_sigma 下訓練
    # BFP 在各 test_sigma 下測試（BFP 自適應，不需要 retrain）
    # 結果：Lloyd-Max degradation vs BFP stability
    pass
```

BFP（max normalization）完全自適應，每 block 重新計算 max，不受 variance mismatch 影響。Lloyd-Max（sigma normalization）理論上也是自適應的（每 block 算 sigma），但 codebook 是針對特定分布形狀設計的。這個實驗測試的是**分布形狀的 mismatch**，而非 variance mismatch。

---

### Gap 4（Medium）：讀取 input.txt

`input.txt` 存在於 `pattern/` 目錄，可能是真實 application 資料。這是**最具說服力的評估**，應優先於合成資料。

```python
# 讀取並分析 input.txt
with open('input.txt', 'r') as f:
    real_data = np.array([float(line.strip()) for line in f])
print(f"Data range: [{real_data.min()}, {real_data.max()}]")
print(f"Distribution: mean={real_data.mean():.2f}, std={real_data.std():.2f}")
# 再進行量化評估
```

---

### Gap 5（Medium）：Bit budget 公平比對

必須加入：

```python
def compute_compression_metrics(n_samples, block_size, mantissa_bits, exp_bits=8):
    total_bits = n_samples * mantissa_bits + (n_samples // block_size) * exp_bits
    return total_bits / n_samples  # bits per sample

# 確保比較時 BFP 和 Lloyd-Max 使用相同的 bits_per_sample
# 例如 BFP 4-bit mantissa + 8-bit exp / 32 samples = 4.25 bps
# Lloyd-Max 應比較 4-bit（4.25 bps，含 max_val overhead 在同等條件下）
```

---

### Gap 6（Low）：Companding 對照組

μ-law companding + uniform quantizer 是 Lloyd-Max 的主要競爭對手（硬體簡單、效果接近）。建議加入作為參照點：

```python
def mu_law_quantize(block, bits, mu=255):
    max_val = np.max(np.abs(block))
    if max_val == 0: return block
    normalized = block / max_val
    # μ-law compress
    compressed = np.sign(normalized) * np.log(1 + mu * np.abs(normalized)) / np.log(1 + mu)
    # Uniform quantize
    max_int = (1 << (bits - 1)) - 1
    quantized = np.round(compressed * max_int)
    quantized = np.clip(quantized, -max_int, max_int) / max_int
    # μ-law expand
    expanded = np.sign(quantized) * (1/mu) * ((1+mu)**np.abs(quantized) - 1)
    return expanded * max_val
```

---

## 2.4 實驗覆蓋總結

| 計畫書 §2.1 要求 | 狀態 | 優先級 |
|-----------------|------|--------|
| Bit-width {2,3,4,6,8} | PARTIAL（只有 4,6,8） | 高 |
| Block size {8,16,32,64,128} | FAIL | 高 |
| Gaussian 分布 | PASS | — |
| Laplacian 分布 | FAIL | 高 |
| 實測 application 資料 | FAIL（input.txt 未使用） | 極高 |
| Distribution mismatch（形狀） | FAIL | 極高 |
| Variance mismatch 1.5×, 2× | FAIL | 高 |
| Outlier / heavy-tail | FAIL | 中 |
| SQNR 記錄 | PASS | — |
| MSE 記錄 | PARTIAL（可計算，未輸出） | 低 |
| 壓縮率（含 overhead） | FAIL | 高 |
| Task-level metric | 未知（需 application context） | 中 |

**覆蓋率估計：約 30%（3/10 主要要求達到）**

---

## 補充實驗的執行順序建議

1. 先修正 correctness_report.md 的 B1, B2, B3（結果才可信）
2. 加 random seed（可重現）
3. 讀取並分析 `input.txt`，確認是否可用
4. 加 block size 掃描 + 真實 bits_per_sample 計算
5. 加 Laplacian 分布測試
6. 加 distribution mismatch 實驗
7. 加 2-bit, 3-bit bit-width 實驗
8. 加 variance mismatch 測試
9. 加 μ-law 對照組
