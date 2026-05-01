import random
import os

def generate_pattern(filename, num_transactions=200):
    os.makedirs(os.path.dirname(filename), exist_ok=True)
    with open(filename, 'w') as f:
        for _ in range(num_transactions):
            data = random.randint(0, 255)
            f.write(f"{data}\n")
    print(f"Generated {num_transactions} test patterns in {filename}")

if __name__ == '__main__':
    generate_pattern('/Users/aaron/projects/verilog/async_fifo/pattern/input.txt')
