# Complex Mixer IP 規格書（`ip_complex_mixer`）

## 功能概述

對複數基頻訊號 (I + jQ) 乘上 NCO（數控振盪器）產生的複數載波，進行頻率搬移：

```
dout_i = din_i × cos(θ) − din_q × sin(θ)
dout_q = din_i × sin(θ) + din_q × cos(θ)
```

NCO 採用**四分之一週期共用 ROM 架構**：每個 ROM entry 打包兩個互補的 sin 振幅，
一次讀取即可同時取得 cos 與 sin，相較於兩張獨立全週期表格節省 50% ROM 面積。

---

## 可設定參數

| 參數       | 預設值 | 說明 |
|-----------|--------|------|
| `DATA_W`  | 16     | I/Q 輸入/輸出位元寬（有號） |
| `AMP_W`   | 12     | NCO 振幅位元寬（有號，範圍 ±2047） |
| `PHASE_W` | 16     | 相位累加器位元寬（頻率解析度 = fs / 2^PHASE_W） |
| `NCO_ROM` | `"pattern/nco_rom.hex"` | ROM 初始化檔案路徑 |

---

## 埠定義

| 訊號       | 方向 | 寬度    | 說明 |
|-----------|------|---------|------|
| `clk`     | in   | 1       | 時脈 |
| `rst_n`   | in   | 1       | 低態有效非同步重置 |
| `din_valid` | in | 1      | 輸入樣本有效 |
| `din_i`   | in   | DATA_W  | I（實部）輸入，有號 |
| `din_q`   | in   | DATA_W  | Q（虛部）輸入，有號 |
| `freq_word` | in | PHASE_W | NCO 頻率字，執行期控制 |
| `dout_valid` | out | 1    | 輸出有效（延遲 3 個時脈週期） |
| `dout_i`  | out  | DATA_W  | I 輸出，有號 |
| `dout_q`  | out  | DATA_W  | Q 輸出，有號 |

---

## 架構說明

### NCO ROM 記憶體優化

**Quarter-wave 共用 ROM**：深度 2^(PHASE_W−2) = 16384，每 entry 寬度 2×AMP_W = 24 bits。

```
ROM entry i = { sin[QSIZE−1−i][11:0],  sin[i][11:0] }
                        hi（鏡像值）          lo（正向值）
```

**象限解碼**（全組合邏輯，0-cycle latency）：

```
quadrant = phase[15:14]   // 2-bit 象限
raw_idx  = phase[13:0]    // 14-bit 四分之一表格索引

sin_amp  = quadrant[0] ? hi : lo    // 選取振幅
cos_amp  = quadrant[0] ? lo : hi

sin_sign = quadrant[1]
cos_sign = quadrant[1] XOR quadrant[0]

sin_out = sin_sign ? −sin_amp : +sin_amp   // 12-bit 有號
cos_out = cos_sign ? −cos_amp : +cos_amp
```

象限對應關係：

| 象限 | 角度範圍 | sin 索引       | sin 正負 | cos 索引       | cos 正負 |
|------|---------|---------------|--------|---------------|--------|
| 0    | 0°–90°   | raw           | +      | QSIZE-1-raw   | +      |
| 1    | 90°–180° | QSIZE-1-raw   | +      | raw           | −      |
| 2    | 180°–270°| raw           | −      | QSIZE-1-raw   | −      |
| 3    | 270°–360°| QSIZE-1-raw   | −      | raw           | +      |

### Pipeline 架構（3 個 stage）

```
  輸入
    │
Stage 1 ──── 相位累加器：phase_acc += freq_word
             暫存 I1, Q1, valid1
    │
    ├── [nco_lut 全組合邏輯]
    │
Stage 2 ──── 暫存 sin_r, cos_r（NCO 輸出）
             暫存 I2, Q2, valid2
    │
Stage 3 ──── 複數乘法 + 截位輸出
             dout_i = (I2×cos_r − Q2×sin_r)[27:12]
             dout_q = (I2×sin_r + Q2×cos_r)[27:12]
    │
  輸出（延遲 3 cycles）
```

**乘法與截位**：16×12 = 28-bit 有號乘積，取 bits[27:12]（÷ 2^12），  
等效於以 NCO 滿刻度為基準的正規化，輸出維持 16-bit 有號。

---

## 子模組

| 模組 | 檔案 | 說明 |
|------|------|------|
| `nco_lut` | `rtl/nco_lut.v` | Quarter-wave ROM + 象限解碼 |
| `rom` | `../../commonlib/rom.v` | 單埠 ROM（非同步讀、`$readmemh` 初始化） |

---

## 模擬與驗證

```bash
# 1. 生成 ROM hex（AMP_W / PHASE_W 更動時重新執行）
python3 pattern/gen_nco_rom.py > pattern/nco_rom.hex

# 2. 生成測試向量（Python bit-true golden model）
python3 pattern/gen_pattern.py

# 3. 編譯
iverilog -o sim/complex_mixer.vvp \
    tb/complex_mixer_tb.v rtl/complex_mixer.v rtl/nco_lut.v \
    ../../commonlib/rom.v

# 4. 模擬
vvp sim/complex_mixer.vvp
```

預期結果：**PASS: 200  FAIL: 0**（含邊界值：全零、±32767、±32768 等）

---

## ROM 初始化格式

`pattern/nco_rom.hex` 由 `pattern/gen_nco_rom.py` 生成：
- 共 16384 行，每行一個 6-digit hex 字（24-bit）
- 格式：`HHHHLL`（高 12-bit = sin[QSIZE-1-i]，低 12-bit = sin[i]）
- `$readmemh` 自動逐行載入至 ROM 陣列

---

## commonlib 新增說明

本 IP 新增 `commonlib/rom.v`：

```verilog
module rom #(
    parameter DSIZE     = 8,
    parameter ASIZE     = 4,
    parameter INIT_FILE = ""
)(
    output wire [DSIZE-1:0] rdata,
    input  wire [ASIZE-1:0] raddr
);
```

- 非同步讀（`assign rdata = mem[raddr]`），與 `fifomem.v` 風格一致
- `INIT_FILE` 為空字串時不執行 `$readmemh`，可作為純行為 ROM 使用
