# tb/

存放 Verilog testbench。

- `template_tb.v` — 讀取 `pattern/input.txt`（相對於執行 vvp 的 template/ 目錄），逐筆比對 DUT 輸出與 golden answer。

## 編譯與模擬

```bash
cd ~/projects/verilog/template
iverilog -o sim/sim.out tb/template_tb.v rtl/template.v
vvp sim/sim.out
```
