import numpy as np
import time

np.random.seed(42)


def calculate_sqnr(original, reconstructed):
    original = original.astype(np.float64)
    reconstructed = reconstructed.astype(np.float64)
    noise = original - reconstructed
    signal_power = np.mean(original ** 2)
    noise_power = np.mean(noise ** 2)
    if noise_power == 0:
        return float('inf')
    return 10 * np.log10(signal_power / noise_power)


def uniform_bfp_ideal(blocks, mantissa_bits):
    """BFP 理想版：浮點 scale（理論上界，scale = max_val / max_int）。
    硬體不可實現，僅作為 BFP 的性能上限參考。
    """
    max_vals = np.max(np.abs(blocks), axis=1, keepdims=True)  # (N, 1)
    max_int = (1 << (mantissa_bits - 1)) - 1
    safe_max = np.where(max_vals == 0, 1.0, max_vals)
    scale = safe_max / max_int
    quantized = np.round(blocks / scale)
    # 完整 two's complement 範圍 [-(2^(m-1)), 2^(m-1)-1]
    quantized = np.clip(quantized, -(1 << (mantissa_bits - 1)), max_int)
    return np.where(max_vals == 0, blocks, quantized * scale)


def uniform_bfp_hardware(blocks, mantissa_bits):
    """BFP 硬體版：power-of-2 shared exponent，等效 leading-zero detection。

    定義：找最小非負整數 e，使得 (2^(m-1) - 1) * 2^e >= max_val。
    當 max_val <= max_int 時 e=0（scale=1）；否則 e = ceil(log2(max_val / max_int))。
    """
    max_vals = np.max(np.abs(blocks), axis=1)  # (N,)
    max_int = (1 << (mantissa_bits - 1)) - 1

    e = np.zeros(len(max_vals), dtype=np.float64)
    needs_scale = max_vals > max_int
    if np.any(needs_scale):
        e[needs_scale] = np.ceil(np.log2(max_vals[needs_scale] / max_int))

    scales = (2.0 ** e)[:, np.newaxis]       # (N, 1)
    max_vals_2d = max_vals[:, np.newaxis]     # (N, 1)

    quantized = np.round(blocks / scales)
    quantized = np.clip(quantized, -(1 << (mantissa_bits - 1)), max_int)
    return np.where(max_vals_2d == 0, blocks, quantized * scales)


def lloyd_max_histogram(data, bits, max_iter=100, tol=1e-6):
    """真正的 Lloyd-Max 算法（高解析度直方圖 + 向量化迭代）。

    data: 已正規化至 [-1, 1] 的訓練資料（須與測試資料完全獨立）。
    回傳的 centroids / boundaries 保證彼此一致（從最終 centroids 重算 boundaries）。
    """
    levels = 1 << bits
    num_bins = max(100000, levels * 100)

    hist, bin_edges = np.histogram(
        data, bins=num_bins,
        range=(-1.0 - 1e-9, 1.0 + 1e-9),  # 稍微擴展，確保 ±1.0 的值不被排除
        density=True
    )
    bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2.0
    pmf = hist * (bin_edges[1] - bin_edges[0])

    centroids = np.linspace(-0.99, 0.99, levels)

    for _ in range(max_iter):
        boundaries = (centroids[:-1] + centroids[1:]) / 2.0
        indices = np.clip(np.digitize(bin_centers, boundaries), 0, levels - 1)

        # 向量化計算條件期望值（Centroid condition of Lloyd-Max）
        prob_sums    = np.bincount(indices, weights=pmf,                minlength=levels)
        weighted_sum = np.bincount(indices, weights=pmf * bin_centers,  minlength=levels)
        new_centroids = np.where(prob_sums > 0, weighted_sum / prob_sums, centroids)
        new_centroids = np.sort(new_centroids)

        shift = np.max(np.abs(new_centroids - centroids))
        centroids = new_centroids   # 先更新，再判斷是否收斂
        if shift < tol:
            break

    # 從最終 centroids 重新計算 boundaries，保證兩者一致
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0
    return centroids, boundaries


def encode_lloyd_max(blocks, centroids, boundaries):
    """Lloyd-Max encoder（Block-Max normalization，向量化版本）。"""
    max_vals = np.max(np.abs(blocks), axis=1, keepdims=True)  # (N, 1)
    safe_max = np.where(max_vals == 0, 1.0, max_vals)
    normalized = blocks / safe_max

    indices = np.clip(
        np.digitize(normalized.flatten(), boundaries),
        0, len(centroids) - 1
    )
    reconstructed = centroids[indices].reshape(blocks.shape) * safe_max
    return np.where(max_vals == 0, blocks, reconstructed)


def run_comparison(data_length=1024000, block_size=32,
                   bit_widths=[2, 3, 4, 6, 8]):
    print("=" * 70)
    print(" BFP vs Lloyd-Max 最正確壓縮效果對比")
    print("=" * 70)
    print(f"資料格式   : 16-bit 有號整數（高斯分佈，sigma=8192）")
    print(f"測試資料量 : {data_length:,} samples / {data_length // block_size:,} blocks")
    print(f"區塊大小   : {block_size}")
    print(f"訓練/測試  : 完全獨立（各 {data_length:,} samples）")
    print(f"Random seed: 42\n")

    # ── 產生完全獨立的訓練集與測試集 ──────────────────────────────────────
    def make_data(n):
        return np.clip(np.round(np.random.randn(n) * 8192), -32768, 32767)

    train_raw = make_data(data_length)
    test_raw  = make_data(data_length)

    num_blocks  = data_length // block_size
    train_blocks = train_raw[:num_blocks * block_size].reshape(num_blocks, block_size)
    test_blocks  = test_raw[:num_blocks * block_size].reshape(num_blocks, block_size)
    flatten_test = test_blocks.flatten()

    # 訓練集：Block-Max 正規化後的分布，作為 Lloyd-Max 的訓練資料
    train_maxes = np.max(np.abs(train_blocks), axis=1, keepdims=True)
    train_maxes[train_maxes == 0] = 1.0
    training_data = (train_blocks / train_maxes).flatten()

    print(f"[訓練資料] 正規化分布：mean={training_data.mean():.4f}, "
          f"std={training_data.std():.4f}, range=[{training_data.min():.3f}, {training_data.max():.3f}]\n")

    # ── 各 bit-width 實驗 ─────────────────────────────────────────────────
    for bits in bit_widths:
        exp_overhead_bits = 8   # 假設 shared exponent/scale 需要 8 bits
        bps = bits + exp_overhead_bits / block_size

        print(f"{'─' * 70}")
        print(f" {bits}-bit  ({1 << bits} levels)  "
              f"[等效 {bps:.3f} bits/sample，含 {exp_overhead_bits}-bit overhead/block]")
        print(f"{'─' * 70}")

        # 1. BFP Ideal（float scale）
        rec_ideal  = uniform_bfp_ideal(test_blocks, bits).flatten()
        sqnr_ideal = calculate_sqnr(flatten_test, rec_ideal)

        # 2. BFP Hardware（power-of-2 exponent）
        rec_hw  = uniform_bfp_hardware(test_blocks, bits).flatten()
        sqnr_hw = calculate_sqnr(flatten_test, rec_hw)

        # 3. Lloyd-Max（Max norm，獨立訓練集）
        t0 = time.time()
        centroids, boundaries = lloyd_max_histogram(training_data, bits)
        t_train = time.time() - t0

        rec_lm  = encode_lloyd_max(test_blocks, centroids, boundaries).flatten()
        sqnr_lm = calculate_sqnr(flatten_test, rec_lm)

        hw_loss  = sqnr_hw - sqnr_ideal   # <= 0，power-of-2 exponent 的代價
        lm_vs_hw = sqnr_lm - sqnr_hw

        print(f"  BFP Ideal    (float scale)  : {sqnr_ideal:8.3f} dB  ← 理論上界")
        print(f"  BFP Hardware (2^e scale)    : {sqnr_hw:8.3f} dB  [{hw_loss:+.3f} dB vs Ideal]")
        print(f"  Lloyd-Max    (Max norm)     : {sqnr_lm:8.3f} dB  [{lm_vs_hw:+.3f} dB vs HW BFP]"
              f"  (訓練: {t_train:.2f}s)")

        if lm_vs_hw > 0.3:
            verdict = f"Lloyd-Max 領先 HW BFP  {lm_vs_hw:+.2f} dB"
        elif lm_vs_hw < -0.3:
            verdict = f"HW BFP 領先 Lloyd-Max  {-lm_vs_hw:+.2f} dB"
        else:
            verdict = f"兩者相近（|差距| = {abs(lm_vs_hw):.2f} dB < 0.3 dB）"
        print(f"  → {verdict}\n")


if __name__ == '__main__':
    run_comparison(data_length=1024000, block_size=32,
                   bit_widths=[2, 3, 4, 6, 8])
