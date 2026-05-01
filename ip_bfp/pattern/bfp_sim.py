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
    
    # 預期的目標 Bit-width 最大整數值 (有號)
    max_int = (1 << (bits - 1)) - 1
    
    # Scale factor (縮放比例)
    scale = max_val / max_int
    
    # 量化與還原（完整 two's complement 範圍 [-(2^(m-1)), 2^(m-1)-1]）
    quantized = np.round(block / scale)
    quantized = np.clip(quantized, -(1 << (bits - 1)), max_int)
    return quantized * scale

def generate_lloyd_max_centroids(bits, max_samples=300000):
    """ 利用 k-means 產生標準常態分佈的 Lloyd-Max 中心點與邊界 """
    levels = 1 << bits
    # 動態調整取樣數，確保高 bit-width 時每個 bin 都有足夠的樣本 (最多取 max_samples)
    num_samples = min(max_samples, max(levels * 1000, 50000))
    
    print(f"    [Info] 正在產生 {bits}-bit ({levels} levels) 的 Lloyd-Max 表...")
    samples = np.random.randn(num_samples).astype(np.float32)
    
    # 使用百分位數作為初始猜測以加速收斂
    p = np.linspace(0.001, 0.999, levels)
    init_centroids = norm.ppf(p).astype(np.float32)
    
    try:
        centroids, _ = kmeans2(samples, init_centroids, iter=15, minit='matrix')
    except Exception as e:
        print(f"    [Warning] kmeans2 失敗: {e}. 改用預設 k-means 初始值。")
        centroids, _ = kmeans2(samples, levels, iter=15)
        
    centroids = np.sort(centroids)
    # 計算決策邊界 (兩個中心點的平均值)
    boundaries = (centroids[:-1] + centroids[1:]) / 2.0
    return centroids, boundaries

def non_uniform_bfp(block, centroids, boundaries):
    """ Non-Uniform BFP: 使用區塊標準差 (Sigma) 縮放，並查 Lloyd-Max 表 """
    sigma = np.std(block)
    if sigma == 0:
        return block
    
    # 正規化區塊資料
    normalized_block = block / sigma
    
    # 透過 boundaries 找出屬於哪一個區間
    indices = np.digitize(normalized_block, boundaries)
    indices = np.clip(indices, 0, len(centroids) - 1)
    
    # 將資料映射到對應的 centroid，並乘回 sigma 還原
    quantized_normalized = centroids[indices]
    return quantized_normalized * sigma

def run_simulation(data_length=102400, block_size=32, bit_widths=[8, 12, 14]):
    print("="*45)
    print(" Block Floating Point (BFP) 壓縮演算法比較")
    print("="*45)
    print(f"原始資料格式 : 16-bit 有號整數 (模擬範圍)")
    print(f"資料長度     : {data_length} samples")
    print(f"區塊大小     : {block_size} (可調整)")
    print(f"目標壓縮位元 : {bit_widths}")
    print(f"資料分佈     : 高斯分佈 (Gaussian)\n")
    
    # 產生 16-bit 範圍的高斯分佈資料
    # 將標準差設為 8192，確保 +/- 4*sigma 大致落在 16-bit (-32768 ~ 32767) 的動態範圍內
    data = np.random.randn(data_length)
    data = np.round(data * 8192)
    data = np.clip(data, -32768, 32767)
    
    # 根據 block_size 進行切塊
    num_blocks = data_length // block_size
    data = data[:num_blocks * block_size]
    blocks = data.reshape(num_blocks, block_size)
    
    for bits in bit_widths:
        print(f"--- 評估壓縮至 {bits}-bit 的結果 ---")
        
        # 1. 執行 Uniform BFP (Block Max)
        reconstructed_uniform = np.zeros_like(blocks, dtype=np.float64)
        for i in range(num_blocks):
            reconstructed_uniform[i] = uniform_bfp(blocks[i], bits)
        
        sqnr_uniform = calculate_sqnr(data, reconstructed_uniform.flatten())
        print(f"  > Uniform (Block Max) SQNR: {sqnr_uniform:.2f} dB")
        
        # 2. 執行 Non-Uniform BFP (Lloyd-Max + Sigma)
        start_time = time.time()
        centroids, boundaries = generate_lloyd_max_centroids(bits)
        reconstructed_non_uniform = np.zeros_like(blocks, dtype=np.float64)
        for i in range(num_blocks):
            reconstructed_non_uniform[i] = non_uniform_bfp(blocks[i], centroids, boundaries)
        
        sqnr_non_uniform = calculate_sqnr(data, reconstructed_non_uniform.flatten())
        elapsed = time.time() - start_time
        print(f"  > Non-Uniform (Sigma) SQNR: {sqnr_non_uniform:.2f} dB (建表+運算耗時: {elapsed:.2f}s)\n")

if __name__ == '__main__':
    run_simulation(data_length=102400, block_size=32, bit_widths=[2, 3, 4, 6, 8])
