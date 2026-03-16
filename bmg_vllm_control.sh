#!/bin/bash
# ==============================================================================
# BMG vLLM Benchmark Script (Intel llm-scaler spec)
# Fully automatic benchmark for Intel Arc Battlemage GPUs
# Ref: https://github.com/intel/llm-scaler/blob/main/vllm/README.md
# Ref: https://github.com/intel/llm-scaler/blob/main/Releases.md
# ==============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# Latest beta from https://github.com/intel/llm-scaler/blob/main/Releases.md
DEFAULT_IMAGE_TAG="0.14.0-b8.1"
CONTAINER_NAME="lsv-container"
MODEL_DIR="/home/intel/LLM"
VLLM_PORT=8000

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  BMG vLLM Benchmark (Intel llm-scaler spec)         ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# ==============================================================================
# STEP 1: Driver check
# ==============================================================================
if ! command -v xpu-smi &>/dev/null; then
    echo -e "${RED}[FAIL] xpu-smi not found. Install Intel GPU drivers first.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] xpu-smi found.${NC}"

# ==============================================================================
# STEP 2: Detect GPU and VRAM
# ==============================================================================
echo -e "\n${CYAN}--- GPU Detection ---${NC}"
GPU_COUNT=$(xpu-smi discovery 2>/dev/null | grep -c "Device ID" || echo "0")
[ "$GPU_COUNT" -eq 0 ] && GPU_COUNT=1

# Parse VRAM from xpu-smi: look for "Memory Physical Size" line, extract MiB value
VRAM_MIB=$(xpu-smi discovery 2>/dev/null \
    | grep -i "memory physical size" | head -1 \
    | grep -oP '[\d.]+(?=\s*MiB)' || echo "")

if [ -n "$VRAM_MIB" ]; then
    # Convert MiB to GiB (integer), e.g. 12281.75 MiB -> 12 GiB
    VRAM_GIB=$(awk "BEGIN{printf \"%d\", $VRAM_MIB / 1024}")
else
    # Fallback: try to get from sysfs
    VRAM_GIB=$(xpu-smi discovery 2>/dev/null \
        | grep -i "memory physical size" | head -1 \
        | grep -oP '[\d.]+(?=\s*GiB)' \
        | awk '{printf "%d", $1}' || echo "12")
    [ -z "$VRAM_GIB" ] && VRAM_GIB=12
fi

echo -e "${GREEN}[OK] ${GPU_COUNT} Intel GPU(s), ${VRAM_GIB} GiB VRAM each.${NC}"
xpu-smi discovery 2>/dev/null | grep -E "Device Name|Device ID|Memory" | head -6 || true

# ==============================================================================
# STEP 3: Docker setup
# ==============================================================================
echo -e "\n${CYAN}--- Docker Setup ---${NC}"
mkdir -p "$MODEL_DIR"

DOCKER_IMAGE="intel/llm-scaler-vllm:${DEFAULT_IMAGE_TAG}"

# If container exists with a different image, remove it
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    EXISTING_IMAGE=$(sudo docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
    if [ "$EXISTING_IMAGE" != "$DOCKER_IMAGE" ] && [ -n "$EXISTING_IMAGE" ]; then
        echo -e "${YELLOW}[!] Container exists with image ${EXISTING_IMAGE}, need ${DOCKER_IMAGE}${NC}"
        echo -e "${YELLOW}    Removing old container...${NC}"
        sudo docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    fi
fi

if ! sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${YELLOW}Pulling ${DOCKER_IMAGE}...${NC}"
    sudo docker pull "$DOCKER_IMAGE"
    echo -e "${YELLOW}Creating container...${NC}"
    sudo docker run -td \
        --privileged --net=host --device=/dev/dri \
        --name="$CONTAINER_NAME" \
        -v "${MODEL_DIR}:/llm/models/" \
        -e no_proxy=localhost,127.0.0.1 \
        -e http_proxy="${http_proxy:-}" \
        -e https_proxy="${https_proxy:-}" \
        --shm-size="32g" \
        --entrypoint /bin/bash \
        "$DOCKER_IMAGE"
else
    sudo docker start "$CONTAINER_NAME" >/dev/null 2>&1
fi
echo -e "${GREEN}[OK] Container ready (${DOCKER_IMAGE}).${NC}"

# ==============================================================================
# STEP 4: Model selection
# ==============================================================================
echo -e "\n${CYAN}--- Model Selection ---${NC}"
echo "Models in ${MODEL_DIR}/:"
ls -1 "$MODEL_DIR/" 2>/dev/null | grep -v '^\.' | grep -v '\.log$' || echo "  (none)"
echo "----------------------------------------------"
echo -e "Paste a ${GREEN}git clone${NC} command or enter a local folder name:"
read -p "Model: " USER_INPUT

# Clean input
USER_INPUT=$(echo "$USER_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
USER_INPUT="${USER_INPUT%/}"
USER_INPUT="${USER_INPUT#git clone }"

# Parse
if [[ "$USER_INPUT" == https://huggingface.co/* ]]; then
    MODEL_NAME=$(basename "$USER_INPUT")
    CLONE_URL="$USER_INPUT"
else
    MODEL_NAME="$USER_INPUT"
    CLONE_URL=""
fi

# Download if needed
if [ -n "$CLONE_URL" ] && [ ! -d "${MODEL_DIR}/${MODEL_NAME}" ]; then
    if ! command -v git-lfs &>/dev/null; then
        echo -e "${YELLOW}Installing git-lfs...${NC}"
        sudo apt install -y git-lfs && git lfs install
    fi
    echo -e "${YELLOW}Cloning ${CLONE_URL}...${NC}"
    git clone "$CLONE_URL" "${MODEL_DIR}/${MODEL_NAME}"
fi

if [ ! -d "${MODEL_DIR}/${MODEL_NAME}" ]; then
    echo -e "${RED}[FAIL] ${MODEL_DIR}/${MODEL_NAME} does not exist.${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Model: ${MODEL_NAME}${NC}"

# ==============================================================================
# STEP 5: Pre-flight model compatibility check
# ==============================================================================
echo -e "${YELLOW}Checking model compatibility...${NC}"
MODEL_CHECK=$(sudo docker exec "$CONTAINER_NAME" python3 -c "
import json, sys
try:
    cfg = json.load(open('/llm/models/${MODEL_NAME}/config.json'))
    archs = cfg.get('architectures', [])
    if not archs:
        print('OK'); sys.exit(0)
    from vllm.model_executor.models import ModelRegistry
    supported = ModelRegistry.get_supported_archs()
    for a in archs:
        if a not in supported:
            print('UNSUPPORTED:' + a); sys.exit(0)
    print('OK')
except Exception as e:
    print('WARN:' + str(e))
" 2>/dev/null || echo "SKIP")

if [[ "$MODEL_CHECK" == UNSUPPORTED:* ]]; then
    BAD_ARCH="${MODEL_CHECK#UNSUPPORTED:}"
    echo -e "${RED}[FAIL] Architecture '${BAD_ARCH}' not supported by this vLLM container.${NC}"
    echo -e "${YELLOW}  Use a supported model or upgrade: docker pull intel/llm-scaler-vllm:<newer-tag>${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] Model compatible.${NC}"

# ==============================================================================
# STEP 6: Calculate max-model-len
# ==============================================================================
echo -e "\n${CYAN}--- Model Profiling ---${NC}"

# Extract param count from model name (e.g. "7B" -> 7)
PARAM_B=$(echo "$MODEL_NAME" | grep -ioE '[0-9]+(\.[0-9]+)?[bB]' \
          | grep -ioE '[0-9]+(\.[0-9]+)?' | tail -1)
PARAM_B=${PARAM_B:-7}

# With fp8 quantization: 1 byte per param
# Model memory = params_B * 1 (fp8) * 1.05 (overhead) ~= params_B * 1.05 GB
# KV cache per token ~= params_B * 0.10 MB (fp8 KV is smaller)
# Available = VRAM * 0.9 - model_mem
MODEL_LEN=$(awk -v vram="$VRAM_GIB" -v pb="$PARAM_B" '
BEGIN {
    usable = vram * 0.9
    model_gb = pb * 1.05
    kv_avail = usable - model_gb
    if (kv_avail < 0.5) kv_avail = 0.5
    raw = (kv_avail * 1024) / (pb * 0.10)
    if (raw < 2048)   raw = 2048
    if (raw > 32768)  raw = 32768
    len = int(raw / 512) * 512
    printf "%d", len
}')

echo -e "  Model size:  ~${PARAM_B}B params"
echo -e "  VRAM:        ${VRAM_GIB} GiB x ${GPU_COUNT} GPU(s)"
echo -e "  Quantization: FP8 (online, per Intel spec)"
echo -e "${GREEN}  max-model-len: ${MODEL_LEN}${NC}"

TP_ARG=""
[ "$GPU_COUNT" -gt 1 ] && TP_ARG="-tp ${GPU_COUNT}"

# ==============================================================================
# STEP 7: Start vLLM server (Intel spec)
# ==============================================================================
echo -e "\n${CYAN}--- Starting vLLM Server ---${NC}"

# Kill any existing vllm
sudo docker exec "$CONTAINER_NAME" pkill -f "vllm serve" 2>/dev/null || true
sleep 2
sudo docker exec "$CONTAINER_NAME" bash -c "> /tmp/vllm_server.log"

# Start server matching Intel llm-scaler README exactly:
# https://github.com/intel/llm-scaler/blob/main/vllm/README.md
echo -e "${YELLOW}Starting vLLM server (port ${VLLM_PORT})...${NC}"
sudo docker exec -d "$CONTAINER_NAME" bash -c "
    source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
    VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
    VLLM_WORKER_MULTIPROC_METHOD=spawn \
    vllm serve /llm/models/${MODEL_NAME} \
        --served-model-name ${MODEL_NAME} \
        --dtype=float16 \
        --enforce-eager \
        --port ${VLLM_PORT} \
        --host 0.0.0.0 \
        --trust-remote-code \
        --disable-sliding-window \
        --gpu-memory-util=0.9 \
        --max-num-batched-tokens=8192 \
        --disable-log-requests \
        --max-model-len=${MODEL_LEN} \
        --block-size 64 \
        --quantization fp8 \
        ${TP_ARG} \
    > /tmp/vllm_server.log 2>&1
"

echo -e "${CYAN}  Log: sudo docker exec ${CONTAINER_NAME} tail -f /tmp/vllm_server.log${NC}"
echo -e "${YELLOW}Waiting for server...${NC}"

N=0
while ! curl -sf "http://localhost:${VLLM_PORT}/v1/models" >/dev/null 2>&1; do
    sleep 5; N=$((N+1))

    # Show progress every 30s
    if [ $((N % 6)) -eq 0 ]; then
        LAST_LINE=$(sudo docker exec "$CONTAINER_NAME" tail -1 /tmp/vllm_server.log 2>/dev/null || echo "")
        echo -e "\n  ${CYAN}[${N}0s] ${LAST_LINE}${NC}"
    else
        echo -n "."
    fi

    # Crash detection
    if ! sudo docker exec "$CONTAINER_NAME" pgrep -f "vllm" >/dev/null 2>&1; then
        echo -e "\n${RED}[FAIL] Server crashed. Full log:${NC}"
        sudo docker exec "$CONTAINER_NAME" cat /tmp/vllm_server.log
        exit 1
    fi

    if [ $N -ge 60 ]; then
        echo -e "\n${RED}[FAIL] Timeout (5 min). Log:${NC}"
        sudo docker exec "$CONTAINER_NAME" tail -30 /tmp/vllm_server.log
        exit 1
    fi
done
echo -e "\n${GREEN}[OK] Server ready.${NC}"

# ==============================================================================
# STEP 8: Run benchmark (Intel spec)
# ==============================================================================
echo -e "\n${CYAN}--- Running Benchmark ---${NC}"

# Intel spec benchmark defaults
IN_LEN=1024
OUT_LEN=512
NUM_PROMPTS=10

# Clamp if needed
MAX_BENCH=$(( MODEL_LEN - 256 ))
if [ $(( IN_LEN + OUT_LEN )) -gt "$MAX_BENCH" ]; then
    IN_LEN=$(( MAX_BENCH * 2 / 3 ))
    OUT_LEN=$(( MAX_BENCH - IN_LEN ))
    # Round to 128
    IN_LEN=$(( (IN_LEN / 128) * 128 ))
    OUT_LEN=$(( (OUT_LEN / 128) * 128 ))
    [ "$IN_LEN" -lt 128 ] && IN_LEN=128
    [ "$OUT_LEN" -lt 128 ] && OUT_LEN=128
    echo -e "${YELLOW}  Adjusted for context: input=${IN_LEN}, output=${OUT_LEN}${NC}"
fi

echo -e "  input-len:    ${IN_LEN}"
echo -e "  output-len:   ${OUT_LEN}"
echo -e "  num-prompts:  ${NUM_PROMPTS}"
echo -e "  request-rate: inf"
echo ""

# Exact benchmark command from Intel llm-scaler README:
# https://github.com/intel/llm-scaler/blob/main/vllm/README.md
sudo docker exec -it "$CONTAINER_NAME" bash -c "
    source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
    vllm bench serve \
        --model /llm/models/${MODEL_NAME} \
        --dataset-name random \
        --served-model-name ${MODEL_NAME} \
        --random-input-len=${IN_LEN} \
        --random-output-len=${OUT_LEN} \
        --ignore-eos \
        --num-prompt ${NUM_PROMPTS} \
        --trust_remote_code \
        --request-rate inf \
        --backend vllm \
        --port=${VLLM_PORT}
"

echo -e "\n${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Benchmark complete.                                ${NC}"
echo -e "${GREEN}=====================================================${NC}"
