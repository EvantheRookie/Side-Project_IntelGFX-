# BMG vLLM Benchmark (Intel Arc Battlemage)

One-click benchmark for Intel Arc Battlemage GPUs using [Intel llm-scaler](https://github.com/intel/llm-scaler). Supports single and multi-GPU setups.

## Quick Start

```bash
git clone https://github.com/EvantheRookie/Side-Project_IntelGFX-.git
cd Side-Project_IntelGFX-
chmod +x bmg_vllm_control.sh
sudo ./bmg_vllm_control.sh
```

The script handles everything: GPU detection, Docker setup, model download, server launch, and benchmark.

## Requirements

| Requirement | Details |
|---|---|
| **Hardware** | Intel Arc Battlemage (B580/B570), single or multiple GPUs |
| **OS** | Linux with Intel GPU drivers (`xpu-smi` must work) |
| **Docker** | Docker Engine installed |
| **GCC** | `sudo apt install build-essential` |
| **Git + git-lfs** | For downloading models from HuggingFace |

## Supported Models

All model types from [Intel llm-scaler](https://github.com/intel/llm-scaler/blob/main/README.md) are supported:

| Type | Example | Benchmark |
|------|---------|-----------|
| Text generation | `DeepSeek-R1-Distill-Qwen-7B` | `vllm bench serve` (throughput) |
| Vision/Multimodal | `Qwen2.5-VL-7B-Instruct` | `vllm bench serve` (text only) |
| Embedding | `Qwen3-VL-Embedding-2B` | `/v1/embeddings` throughput |
| Reranker | `Qwen3-VL-Reranker-8B` | `/v1/score` throughput |
| Pre-quantized (GPTQ/AWQ/AutoRound) | Any INT4/INT8 model | Auto-detected from config.json |

Model type is auto-detected from `config.json` -- no manual flags needed.

## Multi-GPU (Tensor Parallelism)

Multiple GPUs are **auto-detected**. The script splits the model across all GPUs using `-tp N`:

```
1x B580 (24 GiB)  → models up to ~20 GB
2x B580 (48 GiB)  → models up to ~40 GB with -tp 2
3x B580 (72 GiB)  → models up to ~60 GB with -tp 3
```

Docker is configured with `--ipc=host` and `--shm-size=64g` for inter-GPU communication.

If a model's weight files exceed total VRAM, the script fails immediately with a clear message instead of crashing.

## How It Works

```
1. Detect Intel GPUs     → C probe reads PCIe address, VRAM from sysfs
2. Docker image select   → Pick version from Docker Hub or use current
3. Model selection       → Paste HuggingFace URL or type local folder name
4. Model validation      → Check architecture, quantization, model type
5. Auto-profile          → Read weight file size, KV cache dims, context length from config.json
6. Start vLLM server     → Auto-retry on OOM with halved context length
7. Run benchmark         → Appropriate benchmark per model type
```

## Model Selection

When prompted, paste a HuggingFace clone URL or type a local folder name:

```
Model: git clone https://huggingface.co/Qwen/Qwen2.5-7B-Instruct
```
```
Model: DeepSeek-R1-Distill-Qwen-7B
```

Models are stored in `/home/intel/LLM/` on host, mounted as `/llm/models/` in the container.

## Auto-Profiling

Everything is read from the model's `config.json` -- no guessing:

| What | Source |
|------|--------|
| Model size | Actual weight file size on disk (`.safetensors`/`.bin`) |
| Param count | Derived from file size and quantization bits |
| Quantization | `quantization_config.quant_method` from config.json |
| KV cache size | `num_hidden_layers`, `num_key_value_heads`, `head_dim` |
| Max context | `max_position_embeddings` |

**Pre-quantized models**: vLLM auto-detects the method from config.json. The script does NOT pass `--quantization` to avoid deprecated method errors.

**Non-quantized models**: Script passes `--quantization fp8` for Intel FP8 online quantization.

## OOM Auto-Recovery

If the server crashes with out-of-memory:
1. Script detects OOM from the log
2. Halves `max-model-len`
3. Retries (up to 3 times)
4. If still fails, reports model is too large for available VRAM

## Server Flags

| Flag | Purpose |
|---|---|
| `--dtype float16` | FP16 for Intel XPU |
| `--enforce-eager` | Prevents XPU graph compilation hangs |
| `--block-size 64` | Intel-specific KV cache block size |
| `--disable-sliding-window` | Required by Intel spec |
| `--gpu-memory-util 0.9` | Use 90% of available VRAM |
| `-tp N` | Tensor parallelism (N = detected GPU count) |
| `--allow-deprecated-quantization` | For pre-quantized models with deprecated methods |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| OOM during server start | Script auto-retries with shorter context. If still fails, model is too big. |
| Model weights > VRAM | Script detects this upfront. Use smaller model or add more GPUs. |
| `xpu-smi` not found | Install Intel GPU drivers: [Intel docs](https://dgpu-docs.intel.com/) |
| Architecture not supported | Upgrade container version or use a different model |

Check server logs: `sudo docker exec lsv-container tail -50 /tmp/vllm_server.log`

## References

- [Intel llm-scaler README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md)
- [Intel llm-scaler Releases](https://github.com/intel/llm-scaler/blob/main/Releases.md)
- [Supported Models](https://github.com/intel/llm-scaler/blob/main/README.md)
- [vLLM Docs](https://docs.vllm.ai/)
