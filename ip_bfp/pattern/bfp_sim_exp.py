import numpy as np
import time
from scipy.cluster.vq import kmeans2
from scipy.stats import norm

np.random.seed(42)

def calculate_sqnr(original, reconstructed):
    """ 計算訊號與量化雜訊比 (SQNR/SDNR) """
    original = original.astype(np.float64)
    reconstructed = reconstructed.astype(np.float64)
    noise = original - reconstructed
    
    signal_power = np.mean(original ** 2)
    noise_power = np.mean(noise ** 2)
    
    if noise_power == 0:
        return float('inf')
    return 10 * np.log10(signal_power / noise_power)

def uniform_bfp(block, bits):
    """ Uniform BFP: 使用區塊內最大絕對值進行線性縮放 """
    max_val = np.max(np.abs(block))
    if max_val == 0:
        return block
    
    max_int = (1 << (bits - 1)) - 1
    scale = max_val / max_int
    
    quantized = np.round(block / scale)
    quantized = np.clip(quantized, -(1 << (bits - 1)), max_int)
    return quantized * scale

def generate_lloyd_max_sigma(bits, max_samples=200000):
    """ 為 Sigma 縮放 (標準常態) 產生 Lloyd-Max 表 """
    levels = 1 << bits
    num_samples = min(max_samples, max(levels * 1000, 50000))
    samples = np.random.randn(num_samples).astype(np.float32)
    
    # 初始中心點
    p = np.linspace(0.001, 0.999, levels)
    init_centroids = norm.ppf(p).astype(np.float32)
    
    try:
        centroids, _ = kmeans2(samples, init_centroids, iter=15, minit='matrix')
    except:
        centroids, _ = kmeans2(samples, levels, iter=15)
        
    centroids = np.sort(centroids)
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0
    return centroids, boundaries

def generate_lloyd_max_block_max(bits, block_size=32, max_samples=200000):
    """ 為 Block Max 縮放產生的分佈建立 Lloyd-Max 表 """
    levels = 1 << bits
    num_samples = min(max_samples, max(levels * 1000, 50000))
    
    # 模擬 Block Max 縮放後的資料分佈
    raw_samples = np.random.randn(num_samples)
    num_blocks = num_samples // block_size
    reshaped = raw_samples[:num_blocks*block_size].reshape(num_blocks, block_size)
    
    # 每個 block 除以自己的絕對最大值，使其分佈在 [-1, 1]
    block_maxes = np.max(np.abs(reshaped), axis=1, keepdims=True)
    block_maxes[block_maxes == 0] = 1.0
    normalized_samples = (reshaped / block_maxes).flatten().astype(np.float32)
    
    # 初始中心點 (均勻分佈在 -1 到 1 之間)
    init_centroids = np.linspace(-0.95, 0.95, levels).astype(np.float32)
    
    try:
        centroids, _ = kmeans2(normalized_samples, init_centroids, iter=15, minit='matrix')
    except:
        centroids, _ = kmeans2(normalized_samples, levels, iter=15)
        
    centroids = np.sort(centroids)
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0
    return centroids, boundaries

def non_uniform_bfp_sigma(block, centroids, boundaries):
    """ 使用 Sigma 縮放的 Non-Uniform """
    sigma = np.std(block)
    if sigma == 0: return block
    normalized = block / sigma
    indices = np.clip(np.digitize(normalized, boundaries), 0, len(centroids) - 1)
    return centroids[indices] * sigma

def non_uniform_bfp_max(block, centroids, boundaries):
    """ 使用 Block Max 縮放的 Non-Uniform """
    max_val = np.max(np.abs(block))
    if max_val == 0: return block
    normalized = block / max_val
    indices = np.clip(np.digitize(normalized, boundaries), 0, len(centroids) - 1)
    return centroids[indices] * max_val

def run_simulation(data_length=102400, block_size=32, bit_widths=[4, 8, 12]):
    print("="*60)
    print(f" BFP 實驗：縮放策略 vs 量化方式 (Block Size: {block_size})")
    print("="*60)
    
    # 產生 16-bit 有號範圍資料
    data = np.random.randn(data_length)
    data = np.round(data * 8192)
    data = np.clip(data, -32768, 32767)
    
    num_blocks = data_length // block_size
    blocks = data[:num_blocks*block_size].reshape(num_blocks, block_size)
    flatten_data = blocks.flatten()

    for bits in bit_widths:
        print(f"\n[目標位元: {bits}-bit]")
        
        # 1. Uniform (Block Max)
        rec_uni = np.array([uniform_bfp(b, bits) for b in blocks]).flatten()
        print(f"  1. Uniform (Block Max)      SQNR: {calculate_sqnr(flatten_data, rec_uni):.2f} dB")
        
        # 2. Non-Uniform (Sigma-based)
        c_sig, b_sig = generate_lloyd_max_sigma(bits)
        rec_sig = np.array([non_uniform_bfp_sigma(b, c_sig, b_sig) for b in blocks]).flatten()
        print(f"  2. Lloyd-Max (Sigma Scaled) SQNR: {calculate_sqnr(flatten_data, rec_sig):.2f} dB")
        
        # 3. Non-Uniform (Block Max-based) - 實驗組
        c_max, b_max = generate_lloyd_max_block_max(bits, block_size)
        rec_max = np.array([non_uniform_bfp_max(b, c_max, b_max) for b in blocks]).flatten()
        print(f"  3. Lloyd-Max (Max Scaled)   SQNR: {calculate_sqnr(flatten_data, rec_max):.2f} dB")

if __name__ == '__main__':
    # 改用較低位元做實驗，因為 Lloyd-Max 在低位元較有意義
    run_simulation(data_length=102400, block_size=32, bit_widths=[4, 6, 8])
