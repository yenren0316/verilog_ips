# Executive Summary — BFP vs Lloyd-Max 硬體設計決策

審查時間：2026-05-01  
審查範圍：`bfp_sim.py`、`bfp_sim_exp.py`、`bfp_sim_optimal.py`

---

## 1. 最重要的三件事

### 1.1 程式碼有關鍵 Bug，SQNR 數字目前不可信

| Bug | 影響 | 修正難度 |
|-----|------|---------|
| **B1（Critical）** `bfp_sim_optimal.py` 訓練/測試用同一份資料 | Lloyd-Max SQNR 偏高（估計偏差 0.1–0.5 dB） | 低（加幾行 code） |
| **B3（High）** BFP scale 非 power-of-2 | BFP SQNR 偏高（估計偏差 0.5–2 dB），且不反映真實硬體 | 中（需改量化邏輯） |
| **B2（High）** `bfp_sim_optimal.py` loop 結束時 boundaries/centroids 不一致 | 極罕見但存在系統性誤差 | 低（一行 fix） |

**修正這三個 bug 之後，兩者的相對 SQNR 差距可能改變。建議先修正再做最終決策。**

### 1.2 Lloyd-Max 在 Gaussian matched 下多 ~1.5 dB，但代價是面積

理論上（Gaussian 分布，matched codebook）：
- **4-bit**：Lloyd-Max(Max) 與 BFP 面積相近，SQNR 多 1.5 dB → Lloyd-Max 佔優
- **8-bit**：Lloyd-Max(Max) 面積約 4× BFP，SQNR 仍只多 1.5 dB → BFP 佔優

然而，這 1.5 dB 的優勢依賴於分布匹配。**目前完全缺乏 distribution mismatch 實驗**，若 Lloyd-Max 在 mismatch 下退化 > 1.5 dB，則 BFP 在任何場景下都是主導選擇。

### 1.3 Downstream 用途決定一切

- **如果 downstream 有 MAC 運算（NN inference）**：選 BFP。BFP 的 mantissa 可直接做整數 MAC，這個系統級優勢遠超 1.5 dB SQNR 差距（FP MAC 面積約 5–10× 整數 MAC）。
- **如果是純儲存/傳輸**：看 bit-width 和分布確定性，可能 Lloyd-Max 有優勢。

---

## 2. 當前實驗覆蓋率：~30%

缺少的關鍵實驗（按優先順序）：
1. **Distribution mismatch**：Gaussian train → Laplacian test（最關鍵，決定 Lloyd-Max 能否用）
2. **Block size sweep** {8, 16, 32, 64, 128}：決定 BFP exponent overhead
3. **真實 application 資料**：`input.txt` 存在但完全未使用
4. **Bit budget 公平計算**：目前未計算 shared exponent 的 overhead

---

## 3. 硬體設計結論（Tentative）

```
應用場景          Bit-width   資料分布            建議
─────────────────────────────────────────────────────
NN inference       任何        任何                BFP（整數 MAC 優勢）
儲存/傳輸          2–4 bit     已知 Gaussian       Lloyd-Max (Max norm)
儲存/傳輸          ≥5 bit      任何                BFP
儲存/傳輸          任何        未知/混合           BFP（Robustness 優先）
```

**無論任何場景，不要用 Sigma normalization**：計算 sigma 需要 sqrt，是硬體 critical path 的殺手。

**BFP Encoder Critical Path**：AbsMax → LZD → Barrel Shift ≈ 12 FO4 delays，適合 pipeline 到 1 GHz。  
**Lloyd-Max(Max) Encoder 4-bit**：與 BFP 相近；**8-bit**：面積 3–5× BFP。

---

## 4. 建議下一步行動

| 順序 | 行動 | 預計時間 |
|------|------|---------|
| 1 | 修正 Bug B1, B2, B3 + 加 random seed | 1–2 小時 |
| 2 | 重跑所有實驗，確認 SQNR 數字 | 0.5 小時 |
| 3 | 加 Laplacian 分布 + mismatch 實驗 | 2–3 小時 |
| 4 | 加 block size sweep（BFP） | 1 小時 |
| 5 | 讀取並評估 input.txt | 1 小時 |
| 6 | 加真實 bits_per_sample 計算（含 overhead） | 0.5 小時 |
| 7 | 根據完整結果，做最終硬體架構決策 | — |

**在完成步驟 1–3 之前，不建議開始 RTL 設計。**
