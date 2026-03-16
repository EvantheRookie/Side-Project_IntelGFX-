# BMG vLLM Benchmark (Intel Arc Battlemage)

A fully automatic benchmark script for Intel Arc Battlemage (BMG) GPUs, aligned with the official [Intel llm-scaler](https://github.com/intel/llm-scaler) specification. Handles driver detection, Docker setup, model downloading, server launch, and `vllm bench serve` -- all in one go.

## Features

- **Fully Automatic** -- one script from zero to benchmark results
- **C-based GPU Detection** -- reads real PCIe addresses, root ports, link speed/width, and VRAM directly from sysfs (`/sys/kernel/debug/dri/<pci_id>/vram0_mm`)
- **Auto max-model-len Calculator** -- profiles VRAM and model size to calculate optimal context length
- **Model Compatibility Check** -- validates model architecture against container's vLLM before starting
- **Intel Spec Compliant** -- server and benchmark parameters match the [llm-scaler README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md) exactly
- **Crash Detection** -- detects server crashes during startup and dumps logs immediately

## Prerequisites

| Requirement | Details |
|---|---|
| **Hardware** | Intel Arc discrete GPU (Battlemage B580/B570) |
| **OS** | Linux with Intel GPU drivers installed (`xpu-smi` must be available) |
| **Docker** | Docker Engine with GPU passthrough support |
| **GCC** | Required for compiling the GPU detection helper (`sudo apt install build-essential`) |
| **Git + git-lfs** | Required for downloading models from HuggingFace |


## Quick Start

```bash
git clone https://github.com/EvantheRookie/Side-Project_IntelGFX-.git
cd Side-Project_IntelGFX-
chmod +x bmg_vllm_control.sh
sudo ./bmg_vllm_control.sh
```

## How It Works

### Step 1: Driver Check

Verifies `xpu-smi` is installed. Exits with instructions if not found.

### Step 2: GPU Detection (C probe via sysfs)

Compiles and runs an embedded C helper that scans `/sys/class/drm/cardN/device/vendor` for Intel GPUs (`0x8086`). For each GPU it detects:

- **PCIe BDF address** -- resolved from `/sys/class/drm/cardN/device` symlink
- **Root Port** -- parsed top-down from the sysfs device path (e.g. `0000:00:01.0`)
- **PCIe link speed & width** -- read from root port's `current_link_speed` / `current_link_width`
- **Real VRAM size** -- read from `/sys/kernel/debug/dri/<pci_id>/vram0_mm` (requires sudo)

Falls back to `xpu-smi discovery` if debug filesystem is not accessible.

Example output:
```
[GPU 0] card0 | PCIe: 0000:03:00.0 | Root Port: 0000:00:01.0 | Link: 16 GT/s x16 | VRAM: 12288 MiB
```

### Step 3: Docker Setup (Version Selection)

Queries Docker Hub for all available `intel/llm-scaler-vllm` tags and shows which ones are already downloaded locally. The current container's version is marked with `*`.

- **Press Enter** to keep the current container (no download, no rebuild)
- **Type a version tag** (e.g. `1.3`, `0.14.0-b8.1`) to switch

Only pulls from Docker Hub if the chosen version isn't already downloaded. Falls back to showing local-only images if Docker Hub is unreachable.

```
============== Docker Image Selection ==============
  Available on Docker Hub:
    * 0.14.0-b8.1  [downloaded] [current container]
      0.14.0-b8
      1.3  [downloaded]
      0.11.2
      ...
====================================================
  Default: 0.14.0-b8.1
  Releases: https://github.com/intel/llm-scaler/blob/main/Releases.md

Press Enter to keep current (0.14.0-b8.1), or type a version tag:
Version:
```

Container configuration:
```
--privileged --net=host --device=/dev/dri
-v /home/intel/LLM:/llm/models/
--shm-size="32g"
```

### Step 4: Model Selection

Lists models already in `/home/intel/LLM/`. You can paste a `git clone` command or enter a local folder name:

| Input | Example | What happens |
|---|---|---|
| git clone URL | `git clone https://huggingface.co/Qwen/Qwen2.5-7B` | Clones to `/home/intel/LLM/Qwen2.5-7B` |
| HuggingFace URL | `https://huggingface.co/Qwen/Qwen2.5-7B` | Clones to `/home/intel/LLM/Qwen2.5-7B` |
| Local folder | `Qwen2.5-7B` | Uses existing folder |

`git-lfs` is auto-installed if missing.

### Step 5: Model Validation (Deep Pre-flight Check)

Performs multiple checks before attempting to start the server:

| Check | What it catches |
|---|---|
| **GGUF format** | `.gguf` files -- vLLM on Intel XPU cannot load GGUF models |
| **config.json exists** | Non-HuggingFace model formats |
| **Architecture supported** | Model arch not in this vLLM version's ModelRegistry |
| **Model type** | Rerankers, embeddings, classifiers -- not text generation models |
| **Vision/multimodal** | VL models that crash due to config incompatibilities on XPU |
| **Config loading** | Attribute errors (e.g. missing `tie_word_embeddings`) |

If any check fails, the script exits with a clear error message and suggests compatible models.

### Step 6: Auto-Profiling & max-model-len

Calculates optimal `max-model-len` based on:
- Model parameter count (read from `config.json`, falls back to model name parsing)
- FP8 quantization (1 byte per parameter)
- Available VRAM (90% utilization)

```
model_mem   = params_B * 1.05 GB (FP8 + overhead)
kv_per_tok  = params_B * 0.10 MB
available   = VRAM * 0.9 - model_mem
max_len     = available / kv_per_tok
Clamped to [2048..32768], rounded to 512
```

### Step 7: vLLM Server Launch

Starts the server with all Intel-spec-required flags:

```bash
VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
VLLM_WORKER_MULTIPROC_METHOD=spawn \
vllm serve /llm/models/<MODEL> \
    --served-model-name <MODEL> \
    --dtype float16 \
    --enforce-eager \
    --trust-remote-code \
    --disable-sliding-window \
    --gpu-memory-util 0.9 \
    --max-num-batched-tokens 8192 \
    --disable-log-requests \
    --max-model-len <calculated> \
    --block-size 64 \
    --quantization fp8 \
    --port 8000 \
    --host 0.0.0.0
```

Waits for the server to respond on `/v1/models` with crash detection and progress reporting.

### Step 8: Benchmark

Runs `vllm bench serve` matching the Intel llm-scaler spec:

```bash
vllm bench serve \
    --model /llm/models/<MODEL> \
    --dataset-name random \
    --served-model-name <MODEL> \
    --random-input-len 1024 \
    --random-output-len 512 \
    --ignore-eos \
    --num-prompt 10 \
    --trust_remote_code \
    --request-rate inf \
    --backend vllm \
    --port 8000
```

Input/output lengths are auto-clamped if they exceed `max-model-len - 256`.

## Server Flags Reference

| Flag | Purpose |
|---|---|
| `--dtype float16` | FP16 weight dtype for Intel XPU |
| `--enforce-eager` | Disables XPU graph compilation (prevents hangs) |
| `--block-size 64` | Intel-specific KV cache block size |
| `--disable-sliding-window` | Required by Intel spec |
| `--gpu-memory-util 0.9` | Use 90% of available VRAM |
| `--quantization fp8` | FP8 online quantization |
| `-tp N` | Tensor parallelism across N GPUs (auto-detected) |

## File Structure

```
.
└── bmg_vllm_control.sh    # Main script (self-contained, ~500 lines, embeds C GPU detector)
```

## Runtime Paths

| Path | Description |
|---|---|
| `/home/intel/LLM/` | Host model storage (mounted as `/llm/models/` in container) |
| `/tmp/bmg_gpu_detect.c` | GPU detection C source (auto-generated) |
| `/tmp/bmg_gpu_detect` | Compiled GPU detection binary |
| `/tmp/vllm_server.log` | vLLM server log (inside container) |

## Troubleshooting

### Server fails to start / times out
- Check the log: `sudo docker exec lsv-container tail -50 /tmp/vllm_server.log`
- The script auto-dumps the full log on crash detection
- Reduce `max-model-len` if you see OOM errors

### xpu-smi not found
- Install Intel GPU drivers: [Intel Arc GPU Driver Guide](https://dgpu-docs.intel.com/)
- Verify with: `xpu-smi discovery`

### Model architecture not supported
- The container's vLLM version may not support newer model architectures
- Use a supported model or pull a newer container tag from [llm-scaler Releases](https://github.com/intel/llm-scaler/blob/main/Releases.md)

### Docker image version
- The script uses `0.14.0-b8.1` by default (latest beta)
- Check releases at: https://github.com/intel/llm-scaler/blob/main/Releases.md

## Known Issues & Limitations

- **Multi-GPU tensor parallelism not fully tested** -- single-GPU is the primary tested configuration
- **First server start is slow** -- model loading into VRAM can take several minutes
- **VRAM is the bottleneck** -- models that exceed available VRAM will fail to load

## Author

**EvantheRookie** -- [GitHub](https://github.com/EvantheRookie)

## References

- [Intel llm-scaler vLLM](https://github.com/intel/llm-scaler/blob/main/vllm/README.md) -- Official Intel benchmark and serving guide
- [Intel llm-scaler Releases](https://github.com/intel/llm-scaler/blob/main/Releases.md) -- Container version releases
- [vLLM Documentation](https://docs.vllm.ai/) -- vLLM project docs
- [Intel Arc GPU Drivers](https://dgpu-docs.intel.com/) -- Driver installation guides

## License

This project is provided as-is for use with Intel Arc discrete GPUs. See the [Intel llm-scaler](https://github.com/intel/llm-scaler) repository for upstream licensing.
