# sim/

存放模擬產出物（編譯後的執行檔、VCD waveform 等）。此目錄內容由工具產生，不納入版本控制。

```
sim.out   — iverilog 編譯輸出
dump.vcd  — 若 testbench 有呼叫 $dumpfile，waveform 存於此
```
