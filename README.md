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

- Intel Arc Battlemage GPU , single or multiple
- Linux with Intel GPU drivers (`xpu-smi` must work)
- Docker, GCC, Git + git-lfs

## Supported Models (all from Intel llm-scaler)

The script **automatically identifies model type** by reading `config.json` fields (`architectures`, `model_type`, `vision_config`, `audio_config`, etc.) and selects the correct server flags and benchmark method.

| Type | Example | Detection | Task | Benchmark |
|------|---------|-----------|------|-----------|
| Text generation | `DeepSeek-R1-Distill-Qwen-7B`, `Qwen3-14B` | `ForCausalLM` arch | `generate` | `vllm bench serve` |
| Multimodal/VL | `Qwen2.5-VL-7B-Instruct`, `LLaVA` | `vision_config` in json | `multimodal` | `vllm bench serve` + `/v1/chat/completions` with image |
| Omni (audio+vision) | `Qwen-Omni` | `audio_config` + `vision_config` | `omni` | `vllm bench serve` + `/v1/chat/completions` with image |
| Embedding | `bge-m3`, `gte-base`, `e5-large` | base `Model` arch / `embed` keywords | `embed` | `/v1/embeddings` throughput |
| VL Embedding | `Qwen3-VL-Embedding-2B` | `embed` + `vision_config` | `embed` | `/v1/embeddings` throughput |
| Reranker | `bge-reranker-base` | `ForSequenceClassification` / rerank keywords | `score` | `/v1/rerank` or `/v1/score` throughput |
| VL Reranker | `Qwen3-VL-Reranker-8B` | `score` + `vision_config` | `score` | `/v1/rerank` or `/v1/score` throughput |
| Reward model | `reward-model-deberta` | `RewardModel` arch / reward keywords | `reward` | `/v1/score` throughput |
| Pre-quantized | GPTQ/AWQ/AutoRound models | `quantization_config` in json | auto-detected | per model type |
| OCR | `GOT-OCR2` | ocr keywords | `multimodal` | vision benchmark |

## Multi-GPU (Tensor Parallelism)

Auto-detected. Models split across all GPUs with `-tp N`:

```
1x B60 (24 GiB)  → models up to ~20 GB
2x B60 (48 GiB)  → models up to ~40 GB
3x B60 (72 GiB)  → models up to ~60 GB
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

| Flag | Text Gen | Multimodal/Omni | Embed/Score/Reward |
|------|----------|-----------------|---------------------|
| `--disable-sliding-window` | Yes | No | No |
| `--no-enable-prefix-caching` | No | Yes | Yes |
| `--allowed-local-media-path` | No | Yes | No |
| `--max-num-batched-tokens` | 8192 | 5120 | 2048 |
| `--task` | (default) | (default) | embed / score / reward |

Omni models also auto-install `librosa` and `audioread` for audio processing.

## How It Works

```
1. Detect Intel GPUs       → C probe reads PCIe, VRAM from sysfs
2. Docker image selection  → Pick from Docker Hub or use current
3. Model selection         → HuggingFace URL or local folder
4. Model validation        → Read config.json: architectures, vision_config,
                             audio_config, model_type → auto-detect task type
                             Also validates against vLLM's model registry
5. Auto-profile            → Read weight size, KV dims from config.json
6. Quantization choice     → FP8 / INT4 / None for unquantized models
7. Start vLLM server       → Per-task flags, OOM auto-retry
8. Run benchmark           → Auto-selects method per model type
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
