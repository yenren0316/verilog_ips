# pattern/

存放由 Python 或 C++ 產生的測試向量（golden pattern）。

## 格式

每行三個十進位整數：`a  b  expected_sum`

## 產生方式

```bash
# Python
cd ~/projects/python/pattern_gen
python3 gen_pattern.py --num 100

# C++
cd ~/projects/cpp/pattern_gen
make && ./gen_pattern 100
```
