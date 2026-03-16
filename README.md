# BMG vLLM Ultimate Control Center (Intel Arc Battlemage)

All-in-one toolkit for running LLM inference and benchmarks on Intel Arc discrete GPUs (Battlemage B580/B770 series) using the official [Intel llm-scaler-vllm](https://github.com/intel/llm-scaler) Docker image.

## Features

- **4 Execution Modes** -- Online API + Web GUI, Offline Batch, Official Intel Benchmark, GPU Monitor
- **Built-in C GPU Monitor** -- real-time VRAM, power, temperature, fan speed, PCIe link info via `xpu-smi`
- **Smart max-model-len Calculator** -- auto-profiles VRAM, quantization, and model size to recommend optimal context length
- **Intel Spec Compliant** -- server parameters match the official [llm-scaler README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md) exactly

## Prerequisites

| Requirement | Details |
|---|---|
| **Hardware** | Intel Arc discrete GPU (Battlemage B580, B770, or compatible) |
| **OS** | Linux with Intel GPU drivers installed (`xpu-smi` must be available) |
| **Docker** | Docker Engine with GPU passthrough support |
| **Git + git-lfs** | Required for downloading models from HuggingFace (`sudo apt install git-lfs && git lfs install`) |
| **GCC** | Required only for the C GPU monitor (optional) |
| **Python 3** | Required only for Mode 1 (Gradio Web GUI) |

### Driver Installation

Intel Arc GPU drivers must be installed before running the script. If `xpu-smi` is not found, the script will prompt for an offline installer path or direct you to install drivers manually.

Verify your driver installation:

```bash
xpu-smi discovery
```

## Quick Start

```bash
git clone https://github.com/EvantheRookie/Side-Project_IntelGFX-.git
cd Side-Project_IntelGFX-
chmod +x bmg_vllm_control.sh
sudo ./bmg_vllm_control.sh
```

The script will guide you through each step interactively.

## How It Works (Step by Step)

### Step 1: Driver Check

The script verifies that `xpu-smi` is present. If Intel GPU drivers are missing, it offers to run an offline installer or exits with instructions.

### Step 2: Docker Setup

Pulls the official `intel/llm-scaler-vllm` Docker image and creates a container named `lsv-container`.

```
Container config:
  --privileged --net=host --device=/dev/dri
  -v /home/intel/LLM:/llm/models/
  --shm-size="32g"
```

> **Note:** The Intel README recommends using a specific release version tag (e.g. `0.6.6.post1`) rather than `latest`. The script will prompt you for the version.

### Step 3: Model Selection

Lists models already in `/home/intel/LLM/`. You can enter any of these formats:

| Format | Example | What happens |
|---|---|---|
| HuggingFace URL | `https://huggingface.co/Qwen/Qwen3.5-9B` | Clones the repo via `git clone` |
| owner/model | `Qwen/Qwen3.5-9B` | Builds the URL and clones automatically |
| Local folder name | `Qwen3.5-9B` | Uses existing folder (no download) |

Models are cloned to `/home/intel/LLM/<model_name>` on the host, which is already mounted into the container.

> **Requires `git-lfs`:** HuggingFace models use Git LFS for large weight files. Install it first:
> ```bash
> sudo apt install git-lfs && git lfs install
> ```
> If the model folder already exists, the download is skipped automatically.

### Step 4: Hardware Profiling

The script automatically:
1. Detects the number of Intel GPUs and VRAM per GPU
2. Reads model size (e.g. `7B`) and quantization (e.g. `INT4`, `FP8`) from the model name
3. Calculates the recommended `max-model-len` using:

```
model_mem_GB  = params_B x (quant_bits / 8) x 1.05
kv_per_tok_MB = params_B x 0.20
kv_avail_GB   = (vram x gpus x 0.90) - model_mem_GB
max_len       = (kv_avail_GB x 1024) / kv_per_tok_MB
Clamped to [2048 .. 131072], rounded to nearest 512
```

You can accept the recommendation or enter a custom value.

### Step 5: Mode Selection

```
1) Online API + Web GUI      (Live Chat + Stress Test)
2) Offline Batch Inference    (.txt / .csv max throughput)
3) Official Intel Benchmark   (vllm bench serve)
4) GPU Hardware Monitor       (BMG live dashboard)
```

## Execution Modes

### Mode 1: Online API + Web GUI

Starts the vLLM server and launches a Gradio web interface with two tabs:

- **Live Chat** -- streaming chat with TTFT and tokens/sec metrics displayed after each response
- **Stress Benchmark** -- configurable concurrency, request count, max tokens, and custom prompt

Requires `gradio` and `openai` Python packages (auto-installed).

```
Default ports:
  API Server : 8000
  Web GUI    : 7860
```

### Mode 2: Offline Batch Inference

Runs vLLM offline (no server) for maximum throughput on a batch of prompts.

- Place a text file (one prompt per line) in `/home/intel/LLM/`
- Or use the built-in test prompts
- Outputs per-prompt results and a summary with total tokens/sec

### Mode 3: Official Intel Benchmark

Runs `vllm bench serve` matching the exact command from the [Intel llm-scaler README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md):

```bash
vllm bench serve \
    --model /llm/models/<MODEL> \
    --dataset-name random \
    --served-model-name <MODEL> \
    --random-input-len 1024 \
    --random-output-len 512 \
    --ignore-eos \
    --num-prompt 10 \
    --trust-remote-code \
    --request-rate inf \
    --backend vllm \
    --port 8000
```

**Configurable parameters:**
| Parameter | Default | Description |
|---|---|---|
| Input token length | 1024 | Length of random input prompts |
| Output token length | 512 | Max output tokens per request |
| Number of prompts | 10 | Total benchmark requests |
| Request rate | inf | Requests per second (`inf` = send all at once) |

The script auto-clamps input+output to fit within `max-model-len` minus chat-template overhead.

### Mode 4: GPU Hardware Monitor

Launches the built-in C monitor as a standalone dashboard. Displays per-GPU:

```
=================================================================
 BMG Monitor Dashboard (Battlemage Intel ARC)
=================================================================
 [GPU 0] card0 | PCIe: 0000:03:00.0 | hwmon0
  +-- Root Port : 0000:00:01.0   | PCIe Link: 16 GT/s x16
  +-- GPU Render Usage :   45.2 %    | Core Freq :  2350 MHz
  +-- VRAM Usage       :   72.3 %    | VRAM Free :   4480 MiB
  +-- GPU Power        :  120.50 W   | Temp      :   62.0 C
  +-- Fan Speed        :   1200 RPM
=================================================================
```

The monitor is also available as a tmux split pane in Modes 1 and 3.

## vLLM Server Parameters (Intel Spec)

The server is started with all parameters required by the Intel llm-scaler specification:

```bash
VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
VLLM_WORKER_MULTIPROC_METHOD=spawn \
vllm serve /llm/models/<MODEL> \
    --served-model-name <MODEL> \
    --dtype float16 \
    --max-model-len <calculated> \
    --port 8000 \
    --host 0.0.0.0 \
    --enforce-eager \
    --trust-remote-code \
    --gpu-memory-util 0.9 \
    --block-size 64 \
    --disable-sliding-window \
    --max-num-batched-tokens <max-model-len> \
    --disable-log-requests \
    -tp <gpu_count>
```

| Flag | Purpose |
|---|---|
| `--dtype float16` | Explicit FP16 weight dtype for Intel XPU |
| `--enforce-eager` | Disables XPU graph compilation (prevents hangs) |
| `--block-size 64` | Intel-specific KV cache block size |
| `--disable-sliding-window` | Required by Intel spec |
| `--gpu-memory-util 0.9` | Use 90% of available VRAM |
| `-tp N` | Tensor parallelism across N GPUs (auto-detected) |
| `VLLM_WORKER_MULTIPROC_METHOD=spawn` | Required for Intel XPU multi-process workers |
| `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1` | Permits large context windows |

## File Structure

```
.
└── bmg_vllm_control.sh    # Main script (self-contained)
```

The script is fully self-contained. It embeds the C GPU monitor source code and compiles it on first run to `/usr/local/bin/bmg_monitor`.

## Runtime Paths

| Path | Description |
|---|---|
| `/home/intel/LLM/` | Host model storage (mounted into container as `/llm/models/`) |
| `/usr/local/bin/bmg_monitor` | Compiled GPU monitor binary |
| `/tmp/bmg_monitor.c` | GPU monitor C source (auto-generated) |
| `/tmp/vllm_server.log` | vLLM server log (inside container) |
| `/tmp/bmg_monitor.log` | Monitor log (fallback when no tmux/GUI terminal) |

## Troubleshooting

### Server fails to start / times out
- Check the server log: `sudo docker exec lsv-container tail -50 /tmp/vllm_server.log`
- Reduce `max-model-len` if you see OOM errors
- Ensure no other vLLM process is running: `sudo docker exec lsv-container pkill -f "vllm serve"`

### xpu-smi not found
- Install Intel GPU drivers: [Intel Arc GPU Driver Guide](https://dgpu-docs.intel.com/)
- Verify with: `xpu-smi discovery`

### Monitor shows N/A for all values
- The monitor requires `sudo` for `/sys/kernel/debug/` access
- Ensure `xpu-smi` is installed and functional

### Benchmark input+output exceeds context
- The script auto-clamps token lengths to fit within `max-model-len`
- Reduce input/output lengths manually if needed

### Docker image version
- The Intel README recommends pinning to a specific release version
- Check releases at: https://github.com/intel/llm-scaler/releases

## References

- [Intel llm-scaler vLLM](https://github.com/intel/llm-scaler/blob/main/vllm/README.md) -- Official Intel benchmark and serving guide
- [vLLM Documentation](https://docs.vllm.ai/) -- vLLM project docs
- [Intel Arc GPU Drivers](https://dgpu-docs.intel.com/) -- Driver installation guides

## License

This project is provided as-is for use with Intel Arc discrete GPUs. See the [Intel llm-scaler](https://github.com/intel/llm-scaler) repository for upstream licensing.
