# BMG vLLM Benchmark (Intel Arc Battlemage)

One-click benchmark for Intel Arc Battlemage GPUs using [Intel llm-scaler](https://github.com/intel/llm-scaler).
Supports all model types, single and multi-GPU setups.

## Quick Start

```bash
git clone https://github.com/EvantheRookie/Side-Project_IntelGFX-.git
cd Side-Project_IntelGFX-
chmod +x bmg_vllm_control.sh
sudo ./bmg_vllm_control.sh
```

## Requirements

- Intel Arc Battlemage GPU (B580/B570), single or multiple
- Linux with Intel GPU drivers (`xpu-smi` must work)
- Docker, GCC, Git + git-lfs

## Supported Models (all from Intel llm-scaler)

| Type | Example | Task | Benchmark |
|------|---------|------|-----------|
| Text generation | `DeepSeek-R1-Distill-Qwen-7B` | `generate` | `vllm bench serve` |
| Multimodal/VL | `Qwen2.5-VL-7B-Instruct` | `multimodal` | `vllm bench serve` (text) |
| Embedding | `Qwen3-Embedding-8B`, `bge-m3` | `embed` | `/v1/embeddings` throughput |
| VL Embedding | `Qwen3-VL-Embedding-2B` | `embed` | `/v1/embeddings` throughput |
| Reranker | `bge-reranker-base` | `score` | `/v1/rerank` throughput |
| VL Reranker | `Qwen3-VL-Reranker-8B` | `score` | `/v1/rerank` throughput |
| Pre-quantized | GPTQ/AWQ/AutoRound models | auto-detected | per model type |

## Multi-GPU (Tensor Parallelism)

Auto-detected. Models split across all GPUs with `-tp N`:

```
1x B580 (24 GiB)  → models up to ~20 GB
2x B580 (48 GiB)  → models up to ~40 GB
3x B580 (72 GiB)  → models up to ~60 GB
```

Uses `CCL_TOPO_P2P_ACCESS=1` for optimal multi-GPU P2P communication.

## Quantization Options

For unquantized models, the script asks which online quantization to use:

| Option | Flag | Use case |
|--------|------|----------|
| FP8 (default) | `--quantization fp8` | Best speed/accuracy balance |
| INT4 | `--quantization sym_int4` | Lower VRAM, fits larger models |
| None | (no flag) | Highest accuracy, highest VRAM |

Pre-quantized models (GPTQ/AWQ/AutoRound) are auto-detected from `config.json`.

## Per-Task Server Flags (matching Intel spec)

| Flag | Text Gen | Multimodal | Embed/Reranker |
|------|----------|------------|----------------|
| `--disable-sliding-window` | Yes | No | No |
| `--no-enable-prefix-caching` | No | Yes | Yes |
| `--allowed-local-media-path` | No | Yes | No |
| `--max-num-batched-tokens` | 8192 | 5120 | 2048 |
| `--task` | (default) | (default) | embed / score |

## How It Works

```
1. Detect Intel GPUs       → C probe reads PCIe, VRAM from sysfs
2. Docker image selection  → Pick from Docker Hub or use current
3. Model selection         → HuggingFace URL or local folder
4. Model validation        → Architecture, type, quantization check
5. Auto-profile            → Read weight size, KV dims from config.json
6. Quantization choice     → FP8 / INT4 / None for unquantized models
7. Start vLLM server       → Per-task flags, OOM auto-retry
8. Run benchmark           → Type-specific benchmark
```

## Logging

Server logs go to `/llm/vllm.log` inside the container (per Intel spec):
```bash
sudo docker exec lsv-container tail -f /llm/vllm.log
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| OOM during start | Script auto-retries with shorter context |
| Model > VRAM | Detected upfront. Use smaller model or more GPUs |
| `--task` not recognized | Script uses Intel llm-scaler's vLLM which supports `--task` |
| Deprecated quantization | Script adds `--allow-deprecated-quantization` |

## References

- [Intel llm-scaler vLLM README](https://github.com/intel/llm-scaler/blob/main/vllm/README.md)
- [Intel llm-scaler Releases](https://github.com/intel/llm-scaler/blob/main/Releases.md)
- [Supported Models](https://github.com/intel/llm-scaler/blob/main/README.md)
