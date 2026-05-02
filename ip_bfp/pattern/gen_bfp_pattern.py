"""
gen_bfp_pattern.py
產生 BFP encoder testbench 的輸入與期望輸出向量。

Golden model 與 bfp_sim_optimal.py 的 uniform_bfp_hardware 完全一致：
  e = ceil(log2(max_val / max_int))，scale = 2^e
  mantissa = clip(round(sample / scale), -(2^(M-1)), 2^(M-1)-1)

輸出格式：
  input.txt  — 每行一個十進位有號整數（16-bit 輸入樣本）
  expected.txt — 每行一個 block：exp m0 m1 ... m(BLOCK_SIZE-1)
"""

import numpy as np
import math

# ─── 參數（與 RTL parameter 一致）──────────────────────────────────────────
BLOCK_SIZE    = 32
DATA_WIDTH    = 16
MANTISSA_BITS = 4
EXP_BITS      = 5

np.random.seed(123)   # 與 bfp_sim_optimal.py 的 seed 不同，獨立測試集

# ─── Golden model ──────────────────────────────────────────────────────────

def bfp_hw_encode_block(block, mantissa_bits):
    """
    回傳 (e, mantissas) 對應 bfp_sim_optimal.py 的 uniform_bfp_hardware。
    e: 整數 shared exponent
    mantissas: list of signed integers, 長度 BLOCK_SIZE
    """
    max_int  = (1 << (mantissa_bits - 1)) - 1          # e.g. 4-bit → 7
    max_val  = int(np.max(np.abs(block)))

    # 處理 -32768：abs 溢位，飽和至 32767（與 RTL abs_sample 邏輯一致）
    for i, s in enumerate(block):
        if s == -(1 << (DATA_WIDTH - 1)):
            block = block.copy()
            block[i] = (1 << (DATA_WIDTH - 1)) - 1

    max_val = int(np.max(np.abs(block)))

    if max_val == 0:
        return 0, [0] * len(block)

    if max_val <= max_int:
        e = 0
    else:
        e = math.ceil(math.log2(max_val / max_int))

    scale = 2 ** e

    mantissas = []
    for s in block:
        # Round-to-nearest
        if e > 0:
            rounded = int(s) + (1 << (e - 1))
        else:
            rounded = int(s)
        m = rounded >> e   # arithmetic right shift（Python int >> 保留符號）
        # clip
        m = max(-(1 << (mantissa_bits - 1)), min((1 << (mantissa_bits - 1)) - 1, m))
        mantissas.append(m)

    return e, mantissas


# ─── 測試向量集 ────────────────────────────────────────────────────────────

def make_gaussian_blocks(n_blocks):
    data = np.clip(np.round(np.random.randn(n_blocks * BLOCK_SIZE) * 8192),
                   -32768, 32767).astype(np.int32)
    return data.reshape(n_blocks, BLOCK_SIZE)

def make_edge_blocks():
    """邊界條件測試 block 集合"""
    blocks = []

    # 1. 全零 block
    blocks.append(np.zeros(BLOCK_SIZE, dtype=np.int32))

    # 2. 含 -32768（abs 飽和邊界）
    b = np.zeros(BLOCK_SIZE, dtype=np.int32)
    b[0] = -32768
    b[1] = 100
    blocks.append(b)

    # 3. 單一非零（其餘全零）
    b = np.zeros(BLOCK_SIZE, dtype=np.int32)
    b[15] = 8192
    blocks.append(b)

    # 4. max_val 恰為 2^k（exponent 邊界）
    for k in [0, 1, 6, 7, 13, 14]:
        b = np.zeros(BLOCK_SIZE, dtype=np.int32)
        b[0] = min(1 << k, 32767)
        b[1] = -(min(1 << k, 32767))
        blocks.append(b)

    # 5. 全部相同值
    b = np.full(BLOCK_SIZE, 1000, dtype=np.int32)
    blocks.append(b)

    # 6. 交替最大最小值
    b = np.array([32767 if i % 2 == 0 else -32767 for i in range(BLOCK_SIZE)],
                 dtype=np.int32)
    blocks.append(b)

    return np.array(blocks)


# ─── 主程式 ────────────────────────────────────────────────────────────────

def main():
    # 隨機測試 block
    rand_blocks = make_gaussian_blocks(n_blocks=100)
    # 邊界測試 block
    edge_blocks = make_edge_blocks()

    all_blocks = np.vstack([edge_blocks, rand_blocks])
    n_blocks   = len(all_blocks)

    samples_flat = all_blocks.flatten()

    input_lines    = []
    expected_lines = []

    for blk in all_blocks:
        e, mantissas = bfp_hw_encode_block(blk, MANTISSA_BITS)
        # 輸入：每個樣本獨立一行
        for s in blk:
            input_lines.append(str(int(s)))
        # 期望輸出：一行 = exp + 所有 mantissa
        expected_lines.append(str(e) + ' ' + ' '.join(str(m) for m in mantissas))

    with open('input.txt', 'w') as f:
        f.write('\n'.join(input_lines) + '\n')

    with open('expected.txt', 'w') as f:
        f.write('\n'.join(expected_lines) + '\n')

    print(f"產生完成：{n_blocks} blocks（{len(edge_blocks)} 邊界 + {len(rand_blocks)} 隨機）")
    print(f"input.txt    : {len(input_lines)} 行（樣本數）")
    print(f"expected.txt : {len(expected_lines)} 行（block 數）")
    print(f"參數：BLOCK_SIZE={BLOCK_SIZE}, MANTISSA_BITS={MANTISSA_BITS}")

if __name__ == '__main__':
    main()
