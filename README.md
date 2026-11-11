# Reconfigurable-Convolution-Operator-for-DNN-in-Verilog

# Reconfigurable Convolution Core (BF16, 14nm)

Verilog RTL, Python accuracy-verification scripts and a synthesis script for the reconfigurable approximate BF16 convolution core from the paper:

**"Reconfigurable convolution kernels using temporal folding and spatial logic for DNN-based image classifiers"**, Sri Hari A S, Arunachalam V., *Integration*, 2027. DOI: [10.1016/j.vlsi.2026.102898](https://doi.org/10.1016/j.vlsi.2026.102898)

## Overview

A 3×3 convolution engine (9 multipliers + adder tree) that also runs as:
- **1×1:** 9 parallel pointwise convolutions
- **3×3:** native mode, 1 output per cycle
- **7×7:** temporal folding, 6 iterations of 3×3 chunks

## Files

| File | Description |
|------|-------------|
| `icg_cell.v` | Integrated clock-gating cell |
| `csa_15bit.v` | 15-bit carry-save adder |
| `dadda_mult_8x7.v` | 8×7 Dadda multiplier |
| `bf16_approx_trunc.v` | Approximate BF16 multiplier |
| `add_bf16_pipelined.v` | Pipelined BF16 adder |
| `co_cluster.v` | Kernel cluster (9 MACs + adder tree) |
| `reconfig_conv_core.v` | Top module |
| `model_verification.py` | Accuracy verification (FP32 vs approximate BF16) |
| `syn.tcl` | Synopsys Design Compiler synthesis script |
| `con.sdc` | Timing constraints |

## How to use

**Simulate:**
```bash
iverilog -o sim *.v <testbench>.v && vvp sim
```

**Accuracy check** (needs PyTorch and the ImageNet-1k / Chest X-ray datasets from Kaggle):
```bash
python <script>.py
```

**Synthesize** (needs Synopsys Design Compiler and the SAED 14nm EDK, which is not included):
```bash
# set DESIGN_REF_PATH in the .tcl to your SAED14_EDK location
dc_shell -f <script>.tcl
```

## Key results

571.4 MHz, 3.273 mW, 0.0121 mm², 3.142 TFLOPS/W, 0.02% Top-1 drop on DenseNet-121 (ImageNet-1k).
