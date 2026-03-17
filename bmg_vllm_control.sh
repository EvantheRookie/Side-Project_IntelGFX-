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
# STEP 2: Detect GPU and VRAM (via sysfs + C probe)
# ==============================================================================
echo -e "\n${CYAN}--- GPU Detection ---${NC}"

BMG_DETECT_SRC="/tmp/bmg_gpu_detect.c"
BMG_DETECT_BIN="/tmp/bmg_gpu_detect"

# Compile the GPU detection helper (reads real PCIe addresses and VRAM from sysfs)
cat > "$BMG_DETECT_SRC" << 'CEOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <dirent.h>

#define MAX_GPUS 8

typedef struct {
    char card_name[16];
    char pci_id[64];
    char root_port[64];
    char pci_speed[16];
    char pci_width[16];
    char hwmon_dir[64];
    long long vram_size_bytes;
} GPUInfo;

int main() {
    GPUInfo gpus[MAX_GPUS];
    int gpu_count = 0;

    for (int i = 0; i < 32 && gpu_count < MAX_GPUS; i++) {
        char vendor_path[256];
        snprintf(vendor_path, sizeof(vendor_path), "/sys/class/drm/card%d/device/vendor", i);
        FILE *fp = fopen(vendor_path, "r");
        if (!fp) continue;
        char vendor[16] = {0};
        fscanf(fp, "%s", vendor);
        fclose(fp);

        if (strcmp(vendor, "0x8086") != 0) continue;

        char device_link[256], resolved_path[PATH_MAX];
        snprintf(device_link, sizeof(device_link), "/sys/class/drm/card%d/device", i);
        if (realpath(device_link, resolved_path) == NULL) continue;

        GPUInfo *gpu = &gpus[gpu_count];
        snprintf(gpu->card_name, sizeof(gpu->card_name), "card%d", i);

        /* Extract PCI BDF from resolved sysfs path (last component) */
        char *last_slash = strrchr(resolved_path, '/');
        if (last_slash) strcpy(gpu->pci_id, last_slash + 1);
        else strcpy(gpu->pci_id, "Unknown");

        /* Top-down parse: extract Root Port from sysfs path
         * e.g. /sys/devices/pci0000:00/0000:00:01.0/0000:01:00.0/... */
        strcpy(gpu->root_port, "Unknown");
        char *pci_str = strstr(resolved_path, "/pci");
        if (pci_str) {
            char *first_slash = strchr(pci_str + 1, '/');
            if (first_slash) {
                char *rp_start = first_slash + 1;
                char *rp_end = strchr(rp_start, '/');
                if (rp_end && (rp_end - rp_start < (int)sizeof(gpu->root_port))) {
                    strncpy(gpu->root_port, rp_start, rp_end - rp_start);
                    gpu->root_port[rp_end - rp_start] = '\0';
                }
            }
        }

        /* Read PCIe link speed and width from root port (fallback to device) */
        char path_buf[256];
        FILE *fs;

        snprintf(path_buf, sizeof(path_buf), "/sys/bus/pci/devices/%s/current_link_speed", gpu->root_port);
        fs = fopen(path_buf, "r");
        if (!fs) {
            snprintf(path_buf, sizeof(path_buf), "/sys/bus/pci/devices/%s/current_link_speed", gpu->pci_id);
            fs = fopen(path_buf, "r");
        }
        if (fs) { fgets(gpu->pci_speed, sizeof(gpu->pci_speed), fs); gpu->pci_speed[strcspn(gpu->pci_speed, "\n")] = 0; fclose(fs); }
        else strcpy(gpu->pci_speed, "N/A");

        snprintf(path_buf, sizeof(path_buf), "/sys/bus/pci/devices/%s/current_link_width", gpu->root_port);
        fs = fopen(path_buf, "r");
        if (!fs) {
            snprintf(path_buf, sizeof(path_buf), "/sys/bus/pci/devices/%s/current_link_width", gpu->pci_id);
            fs = fopen(path_buf, "r");
        }
        if (fs) { fgets(gpu->pci_width, sizeof(gpu->pci_width), fs); gpu->pci_width[strcspn(gpu->pci_width, "\n")] = 0; fclose(fs); }
        else strcpy(gpu->pci_width, "N/A");

        /* Find hwmon directory */
        char hwmon_base[256];
        snprintf(hwmon_base, sizeof(hwmon_base), "/sys/class/drm/card%d/device/hwmon/", i);
        DIR *dir = opendir(hwmon_base);
        gpu->hwmon_dir[0] = '\0';
        if (dir) {
            struct dirent *entry;
            while ((entry = readdir(dir)) != NULL) {
                if (strncmp(entry->d_name, "hwmon", 5) == 0) {
                    strcpy(gpu->hwmon_dir, entry->d_name);
                    break;
                }
            }
            closedir(dir);
        }

        /* Read real VRAM size from /sys/kernel/debug/dri/<pci_id>/vram0_mm */
        gpu->vram_size_bytes = -1;
        char vram_path[256];
        snprintf(vram_path, sizeof(vram_path), "/sys/kernel/debug/dri/%s/vram0_mm", gpu->pci_id);
        FILE *fp_vram = fopen(vram_path, "r");
        if (fp_vram) {
            char line[256];
            while (fgets(line, sizeof(line), fp_vram)) {
                long long val;
                if (strstr(line, "size:") && sscanf(strstr(line, "size:"), "size: %lld", &val) == 1) {
                    gpu->vram_size_bytes = val;
                    break;
                }
            }
            fclose(fp_vram);
        }

        gpu_count++;
    }

    if (gpu_count == 0) {
        fprintf(stderr, "No Intel GPUs found.\n");
        return 1;
    }

    /* Sort by PCI BDF address */
    for (int i = 0; i < gpu_count - 1; i++) {
        for (int j = 0; j < gpu_count - i - 1; j++) {
            if (strcmp(gpus[j].pci_id, gpus[j+1].pci_id) > 0) {
                GPUInfo temp = gpus[j];
                gpus[j] = gpus[j+1];
                gpus[j+1] = temp;
            }
        }
    }

    /* Output structured data for bash parsing:
     * GPU_COUNT=N
     * GPU:<index>|<card>|<pci_id>|<root_port>|<speed>|<width>|<hwmon>|<vram_bytes> */
    printf("GPU_COUNT=%d\n", gpu_count);
    for (int i = 0; i < gpu_count; i++) {
        printf("GPU:%d|%s|%s|%s|%s|%s|%s|%lld\n", i,
               gpus[i].card_name, gpus[i].pci_id, gpus[i].root_port,
               gpus[i].pci_speed, gpus[i].pci_width,
               gpus[i].hwmon_dir[0] ? gpus[i].hwmon_dir : "N/A",
               gpus[i].vram_size_bytes);
    }
    return 0;
}
CEOF

if ! command -v gcc &>/dev/null; then
    echo -e "${RED}[FAIL] gcc not found. Install with: sudo apt install build-essential${NC}"
    exit 1
fi

gcc -O2 -o "$BMG_DETECT_BIN" "$BMG_DETECT_SRC" 2>/dev/null
if [ ! -x "$BMG_DETECT_BIN" ]; then
    echo -e "${RED}[FAIL] Failed to compile GPU detection helper.${NC}"
    exit 1
fi

# Run detection (needs sudo for /sys/kernel/debug access)
DETECT_OUTPUT=$(sudo "$BMG_DETECT_BIN" 2>/dev/null) || {
    echo -e "${RED}[FAIL] No Intel GPUs detected.${NC}"
    exit 1
}

GPU_COUNT=$(echo "$DETECT_OUTPUT" | grep '^GPU_COUNT=' | cut -d= -f2)
[ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -eq 0 ] && { echo -e "${RED}[FAIL] No Intel GPUs detected.${NC}"; exit 1; }

# Parse first GPU's VRAM (bytes -> MiB -> GiB)
# All GPUs are assumed to have the same VRAM for max-model-len calculation
VRAM_BYTES=$(echo "$DETECT_OUTPUT" | grep '^GPU:0|' | cut -d'|' -f8)
if [ -n "$VRAM_BYTES" ] && [ "$VRAM_BYTES" -gt 0 ] 2>/dev/null; then
    VRAM_MIB=$(( VRAM_BYTES / 1048576 ))
    VRAM_GIB=$(( VRAM_BYTES / 1073741824 ))
    [ "$VRAM_GIB" -eq 0 ] && VRAM_GIB=1
else
    # Fallback: try xpu-smi
    VRAM_MIB_STR=$(xpu-smi discovery 2>/dev/null \
        | grep -i "memory physical size" | head -1 \
        | grep -oP '[\d.]+(?=\s*MiB)' || echo "")
    if [ -n "$VRAM_MIB_STR" ]; then
        VRAM_MIB=$(printf "%.0f" "$VRAM_MIB_STR")
        VRAM_GIB=$(( VRAM_MIB / 1024 ))
    else
        VRAM_MIB=12288
        VRAM_GIB=12
    fi
fi

# Display all detected GPUs
echo -e "${GREEN}[OK] ${GPU_COUNT} Intel GPU(s) detected:${NC}"
while IFS='|' read -r _idx card pci_id root_port speed width hwmon vram_b; do
    idx="${_idx#GPU:}"
    if [ "$vram_b" -gt 0 ] 2>/dev/null; then
        v_mib=$(( vram_b / 1048576 ))
        echo -e "  [GPU ${idx}] ${card} | PCIe: ${pci_id} | Root Port: ${root_port} | Link: ${speed} x${width} | VRAM: ${v_mib} MiB"
    else
        echo -e "  [GPU ${idx}] ${card} | PCIe: ${pci_id} | Root Port: ${root_port} | Link: ${speed} x${width} | VRAM: (debug access required)"
    fi
done < <(echo "$DETECT_OUTPUT" | grep '^GPU:')
echo -e "  ${CYAN}Total VRAM per GPU: ${VRAM_MIB} MiB (${VRAM_GIB} GiB)${NC}"

# ==============================================================================
# STEP 3: Docker setup (user chooses version)
# ==============================================================================
echo -e "\n${CYAN}--- Docker Setup ---${NC}"
mkdir -p "$MODEL_DIR"

# Detect current container image (if any)
CURRENT_CONTAINER_IMAGE=""
if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
    CURRENT_CONTAINER_IMAGE=$(sudo docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
fi

# List all locally downloaded intel/llm-scaler-vllm tags
# Use --filter to handle docker.io prefix variations
LOCAL_TAGS=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep 'intel/llm-scaler-vllm:' \
    | sed 's|.*intel/llm-scaler-vllm:||' \
    | sort -V || true)

# Fetch available tags from Docker Hub (best-effort, skip on network failure)
echo -e "${CYAN}Checking Docker Hub for available versions...${NC}"
REMOTE_TAGS=$(curl -sf --max-time 10 \
    "https://hub.docker.com/v2/repositories/intel/llm-scaler-vllm/tags/?page_size=50&ordering=-name" 2>/dev/null \
    | grep -oP '"name"\s*:\s*"\K[^"]+' \
    | sort -V || true)

echo ""
echo -e "${CYAN}============== Docker Image Selection ==============${NC}"

# Show remote tags (available to download)
if [ -n "$REMOTE_TAGS" ]; then
    echo -e "  ${CYAN}Available on Docker Hub:${NC}"
    while IFS= read -r tag; do
        # Check if this tag is already downloaded locally
        IS_LOCAL=""
        if [ -n "$LOCAL_TAGS" ]; then
            echo "$LOCAL_TAGS" | grep -qx "$tag" 2>/dev/null && IS_LOCAL="yes" || true
        fi
        IS_CURRENT=""
        if [ "$CURRENT_CONTAINER_IMAGE" = "intel/llm-scaler-vllm:${tag}" ]; then
            IS_CURRENT="yes"
        fi

        if [ -n "$IS_CURRENT" ]; then
            echo -e "    ${GREEN}* ${tag}  [downloaded] [current container]${NC}"
        elif [ -n "$IS_LOCAL" ]; then
            echo -e "    ${GREEN}  ${tag}  [downloaded]${NC}"
        else
            echo -e "      ${tag}"
        fi
    done <<< "$REMOTE_TAGS"
else
    # Fallback: show local tags only (no network)
    echo -e "  ${YELLOW}Could not reach Docker Hub. Showing local images only.${NC}"
    if [ -n "$LOCAL_TAGS" ]; then
        echo -e "  ${GREEN}Locally available:${NC}"
        while IFS= read -r tag; do
            if [ "$CURRENT_CONTAINER_IMAGE" = "intel/llm-scaler-vllm:${tag}" ]; then
                echo -e "    ${GREEN}* ${tag}  [current container]${NC}"
            else
                echo -e "    - ${tag}"
            fi
        done <<< "$LOCAL_TAGS"
    else
        echo -e "  ${YELLOW}No local images found.${NC}"
    fi
fi

echo -e "${CYAN}====================================================${NC}"
echo -e "  Default: ${CYAN}${DEFAULT_IMAGE_TAG}${NC}"
echo -e "  Releases: https://github.com/intel/llm-scaler/blob/main/Releases.md"
echo ""
if [ -n "$CURRENT_CONTAINER_IMAGE" ]; then
    CURRENT_TAG="${CURRENT_CONTAINER_IMAGE##*:}"
    echo -e "Press ${GREEN}Enter${NC} to keep current (${CURRENT_TAG}), or type a version tag:"
else
    echo -e "Press ${GREEN}Enter${NC} for default (${DEFAULT_IMAGE_TAG}), or type a version tag:"
fi
read -p "Version: " USER_TAG
USER_TAG=$(echo "$USER_TAG" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -z "$USER_TAG" ]; then
    if [ -n "$CURRENT_CONTAINER_IMAGE" ]; then
        CHOSEN_TAG="${CURRENT_CONTAINER_IMAGE##*:}"
    else
        CHOSEN_TAG="$DEFAULT_IMAGE_TAG"
    fi
else
    CHOSEN_TAG="$USER_TAG"
fi

DOCKER_IMAGE="intel/llm-scaler-vllm:${CHOSEN_TAG}"
echo -e "${CYAN}  Selected: ${DOCKER_IMAGE}${NC}"

# Check if chosen image matches current container -- if so, just reuse it
if [ "$CURRENT_CONTAINER_IMAGE" = "$DOCKER_IMAGE" ]; then
    echo -e "${GREEN}[OK] Container already using ${DOCKER_IMAGE}, reusing.${NC}"
    sudo docker start "$CONTAINER_NAME" >/dev/null 2>&1 || true
else
    # Remove old container if it exists (different version)
    if [ -n "$CURRENT_CONTAINER_IMAGE" ]; then
        echo -e "${YELLOW}[!] Switching from ${CURRENT_CONTAINER_IMAGE} to ${DOCKER_IMAGE}${NC}"
        sudo docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    # Pull only if image not available locally
    IMAGE_EXISTS=$(sudo docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep "intel/llm-scaler-vllm:${CHOSEN_TAG}" || true)
    if [ -z "$IMAGE_EXISTS" ]; then
        echo -e "${YELLOW}Pulling ${DOCKER_IMAGE} (this may take a while)...${NC}"
        sudo docker pull "$DOCKER_IMAGE"
    else
        echo -e "${GREEN}[OK] Image ${DOCKER_IMAGE} already downloaded locally.${NC}"
    fi

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
# STEP 5: Pre-flight model compatibility check (deep validation)
# ==============================================================================
echo -e "\n${CYAN}--- Model Validation ---${NC}"
MODEL_PATH="${MODEL_DIR}/${MODEL_NAME}"

# Check 1: Reject GGUF models (vLLM on Intel XPU does not support GGUF format)
GGUF_FILES=$(find "$MODEL_PATH" -maxdepth 1 -name '*.gguf' 2>/dev/null | head -1)
if [ -n "$GGUF_FILES" ]; then
    echo -e "${RED}[FAIL] This is a GGUF model. vLLM on Intel XPU does not support GGUF format.${NC}"
    echo -e "${YELLOW}  Download the original HuggingFace (safetensors) version instead.${NC}"
    echo -e "${YELLOW}  Example: git clone https://huggingface.co/Qwen/Qwen2.5-7B-Instruct${NC}"
    exit 1
fi

# Check 2: Must have config.json (standard HuggingFace format)
if [ ! -f "${MODEL_PATH}/config.json" ]; then
    echo -e "${RED}[FAIL] No config.json found in ${MODEL_PATH}${NC}"
    echo -e "${YELLOW}  This doesn't look like a standard HuggingFace model.${NC}"
    echo -e "${YELLOW}  vLLM requires models in HuggingFace safetensors format.${NC}"
    exit 1
fi

# Check 3: Deep validation inside container -- architecture support, model type,
# and config loading (catches attribute errors like tie_word_embeddings)
echo -e "${YELLOW}Checking model compatibility...${NC}"
MODEL_CHECK=$(sudo docker exec "$CONTAINER_NAME" python3 -c "
import json, sys, os

model_dir = '/llm/models/${MODEL_NAME}'
result = 'OK'
detail = ''

try:
    cfg = json.load(open(os.path.join(model_dir, 'config.json')))

    # --- Check architecture support ---
    archs = cfg.get('architectures', [])
    if archs:
        from vllm.model_executor.models import ModelRegistry
        supported = ModelRegistry.get_supported_archs()
        for a in archs:
            if a not in supported:
                print(f'UNSUPPORTED_ARCH:{a}')
                sys.exit(0)

    # --- Check quantization method compatibility ---
    # If model is pre-quantized, verify this vLLM version supports that method
    qcfg = cfg.get('quantization_config', {})
    quant_method = qcfg.get('quant_method', '').lower()
    if quant_method:
        try:
            from vllm.model_executor.layers.quantization import QUANTIZATION_METHODS
            # QUANTIZATION_METHODS is a dict of supported method names
            if quant_method not in QUANTIZATION_METHODS:
                print(f'UNSUPPORTED_QUANT:{quant_method}')
                sys.exit(0)
        except ImportError:
            pass  # Older vLLM without this registry, skip check

    # --- Check model type: reject non-generation models ---
    # Rerankers, embeddings, classifiers cannot do text generation
    model_type = cfg.get('model_type', '').lower()
    arch_str = ' '.join(archs).lower()

    # Reject non-generation models (rerankers, embeddings, classifiers)
    # Check both the architecture class names AND the model folder name
    model_name_lower = os.path.basename(model_dir).lower()
    reject_keywords = ['reranker', 'classifier', 'embedding', 'reward']
    for kw in reject_keywords:
        if kw in arch_str or kw in model_type or kw in model_name_lower:
            print(f'BAD_TYPE:This is a {kw} model, not a text generation model')
            sys.exit(0)

    # Reject sequence classification models
    for a in archs:
        if 'ForSequenceClassification' in a or 'ForTokenClassification' in a:
            print(f'BAD_TYPE:{a} is a classification model, not for text generation')
            sys.exit(0)

    # --- Deep check: try to actually load the config through transformers ---
    # This catches attribute errors like 'tie_word_embeddings' missing
    # Runs for ALL models including vision/multimodal (which llm-scaler supports)
    try:
        from transformers import AutoConfig
        auto_cfg = AutoConfig.from_pretrained(model_dir, trust_remote_code=True)
        # Probe attributes that vLLM accesses during model init
        _ = getattr(auto_cfg, 'tie_word_embeddings', None)
        _ = getattr(auto_cfg, 'hidden_size', None)
        _ = getattr(auto_cfg, 'num_attention_heads', None)
        # For VL models, also probe the text config if present
        text_cfg = getattr(auto_cfg, 'text_config', None)
        if text_cfg is not None:
            _ = getattr(text_cfg, 'tie_word_embeddings', None)
            _ = getattr(text_cfg, 'hidden_size', None)
    except AttributeError as e:
        print(f'CONFIG_ERROR:{e}')
        sys.exit(0)
    except Exception as e:
        err_str = str(e)
        if 'attribute' in err_str.lower():
            print(f'CONFIG_ERROR:{err_str}')
            sys.exit(0)
        # Other errors (missing tokenizer etc) are less critical, continue

    # Note if multimodal (for display only, not a blocker)
    is_mm = any(kw.lower() in arch_str or kw.lower() in model_type
                for kw in ['vl', 'vision', 'visual', 'image', 'video'])
    if is_mm:
        print('OK_MULTIMODAL')
    else:
        print('OK')

except FileNotFoundError:
    print('NO_CONFIG:config.json not found')
except Exception as e:
    print(f'WARN:{e}')
" 2>/dev/null || echo "SKIP")

# Handle all result types
case "$MODEL_CHECK" in
    UNSUPPORTED_ARCH:*)
        BAD_ARCH="${MODEL_CHECK#UNSUPPORTED_ARCH:}"
        echo -e "${RED}[FAIL] Architecture '${BAD_ARCH}' not supported by this vLLM container.${NC}"
        echo -e "${YELLOW}  Use a supported model or upgrade the container.${NC}"
        exit 1
        ;;
    UNSUPPORTED_QUANT:*)
        BAD_QUANT="${MODEL_CHECK#UNSUPPORTED_QUANT:}"
        echo -e "${RED}[FAIL] Quantization method '${BAD_QUANT}' not supported by this vLLM container.${NC}"
        echo -e "${YELLOW}  This model is pre-quantized with '${BAD_QUANT}', but the current container${NC}"
        echo -e "${YELLOW}  (vLLM version) doesn't support it.${NC}"
        echo -e "${YELLOW}  Options:${NC}"
        echo -e "${YELLOW}    1. Upgrade: choose a newer container version (1.0+)${NC}"
        echo -e "${YELLOW}    2. Use a non-quantized or FP8 version of this model${NC}"
        exit 1
        ;;
    BAD_TYPE:*)
        REASON="${MODEL_CHECK#BAD_TYPE:}"
        echo -e "${RED}[FAIL] ${REASON}${NC}"
        echo -e "${YELLOW}  The vLLM benchmark requires a text generation (CausalLM) model.${NC}"
        echo -e "${YELLOW}  Examples: DeepSeek-R1-Distill-Qwen-7B, Qwen2.5-7B-Instruct, Llama-3.1-8B${NC}"
        exit 1
        ;;
    OK_MULTIMODAL)
        echo -e "${GREEN}[OK] Model compatible (vision/multimodal).${NC}"
        echo -e "${YELLOW}  Note: The random-text benchmark tests text generation only, not vision.${NC}"
        ;;
    CONFIG_ERROR:*)
        CFG_ERR="${MODEL_CHECK#CONFIG_ERROR:}"
        echo -e "${RED}[FAIL] Model config error: ${CFG_ERR}${NC}"
        echo -e "${YELLOW}  The model's config.json is incompatible with this container's vLLM/transformers.${NC}"
        echo -e "${YELLOW}  Try a different model or upgrade the container.${NC}"
        exit 1
        ;;
    NO_CONFIG:*)
        echo -e "${RED}[FAIL] No config.json in model directory.${NC}"
        exit 1
        ;;
    OK)
        echo -e "${GREEN}[OK] Model compatible (text generation).${NC}"
        ;;
    SKIP|WARN:*)
        echo -e "${YELLOW}[WARN] Could not fully verify compatibility (continuing anyway).${NC}"
        ;;
    *)
        echo -e "${YELLOW}[WARN] Unexpected check result: ${MODEL_CHECK}${NC}"
        ;;
esac

# ==============================================================================
# STEP 6: Auto-profile model from config.json (no guessing)
# ==============================================================================
echo -e "\n${CYAN}--- Model Profiling ---${NC}"

# Read ALL needed parameters directly from config.json + measure weight files
eval "$(sudo docker exec "$CONTAINER_NAME" python3 -c "
import json, os, glob

model_dir = '/llm/models/${MODEL_NAME}'
cfg = json.load(open(os.path.join(model_dir, 'config.json')))

# ---- 1. Actual weight file size on disk (ground truth for VRAM) ----
seen = set()
weight_bytes = 0
for pattern in ('*.safetensors', '*.bin', '*.pt'):
    for f in glob.glob(os.path.join(model_dir, pattern)):
        rp = os.path.realpath(f)
        if rp not in seen:
            seen.add(rp)
            weight_bytes += os.path.getsize(f)
for pattern in ('**/*.safetensors', '**/*.bin'):
    for f in glob.glob(os.path.join(model_dir, pattern), recursive=True):
        rp = os.path.realpath(f)
        if rp not in seen:
            seen.add(rp)
            weight_bytes += os.path.getsize(f)
model_size_gb = weight_bytes / (1024**3) if weight_bytes > 0 else 0
print(f'MODEL_SIZE_GB={model_size_gb:.2f}')

# ---- 2. Quantization (read directly from config.json) ----
qcfg = cfg.get('quantization_config', {})
quant_method = qcfg.get('quant_method', '').lower()
quant_bits = qcfg.get('bits', 0)

pre_quantized = 0
quant_display = ''
if quant_method:
    pre_quantized = 1
    bits = quant_bits or 4
    if quant_method in ('fp8', 'fbgemm_fp8'):
        quant_display = f'FP8 (pre-quantized, auto-detected)'
    else:
        quant_display = f'{quant_method} INT{bits} (pre-quantized, auto-detected)'
else:
    quant_display = 'FP8 (online, per Intel spec)'
print(f'QUANT_DISPLAY=\"{quant_display}\"')
print(f'PRE_QUANTIZED={pre_quantized}')

# ---- 3. KV cache dimensions (read directly from config.json) ----
# These are the REAL values vLLM uses for KV cache allocation.
# For hybrid models (Qwen3-Next etc.), check text_config too.
tc = cfg.get('text_config', cfg)  # some VL models nest under text_config

num_layers = tc.get('num_hidden_layers', cfg.get('num_hidden_layers', 0))
num_kv_heads = tc.get('num_key_value_heads',
               tc.get('num_attention_heads',
               cfg.get('num_key_value_heads',
               cfg.get('num_attention_heads', 0))))
head_dim = tc.get('head_dim', 0)
if head_dim == 0:
    hidden = tc.get('hidden_size', cfg.get('hidden_size', 0))
    n_heads = tc.get('num_attention_heads', cfg.get('num_attention_heads', 1))
    head_dim = hidden // n_heads if n_heads > 0 else 0

print(f'NUM_LAYERS={num_layers}')
print(f'NUM_KV_HEADS={num_kv_heads}')
print(f'HEAD_DIM={head_dim}')

# ---- 4. Max context length from config.json ----
max_pos = tc.get('max_position_embeddings',
          cfg.get('max_position_embeddings', 0))
# Some models use other names
if max_pos == 0:
    max_pos = tc.get('max_sequence_length',
              tc.get('seq_length',
              cfg.get('max_sequence_length',
              cfg.get('seq_length', 0))))
print(f'MAX_POS_EMBED={max_pos}')

# ---- 5. Param count from file size (not from architecture formula) ----
if weight_bytes > 0 and quant_method:
    bits = quant_bits or 4
    # For quantized models: file_size / (bits/8) gives true param count
    # (approximate, as not all tensors are quantized, but much better than formula)
    param_b_est = (weight_bytes / (bits / 8)) / 1e9
    # Also include non-quantized overhead (~20% of params are in fp16 embeddings etc)
    param_b_est = param_b_est * 0.85  # discount for mixed precision
elif weight_bytes > 0:
    # fp16 model
    param_b_est = (weight_bytes / 2) / 1e9
else:
    param_b_est = 0
# Snap to known sizes for display
param_b = ''
if param_b_est > 0:
    for s in [0.5, 1, 1.5, 2, 3, 4, 7, 8, 9, 13, 14, 15, 32, 34, 70, 72]:
        if abs(param_b_est - s) / max(s, 1) < 0.25:
            param_b = str(s); break
    if not param_b:
        param_b = f'{param_b_est:.1f}'
print(f'CFG_PARAM_B={param_b}')
" 2>/dev/null || echo "CFG_PARAM_B=
MODEL_SIZE_GB=0
QUANT_DISPLAY=\"FP8 (online, per Intel spec)\"
PRE_QUANTIZED=0
NUM_LAYERS=0
NUM_KV_HEADS=0
HEAD_DIM=0
MAX_POS_EMBED=0")"

# Apply defaults
PARAM_B=""
if [ -n "$CFG_PARAM_B" ]; then
    PARAM_B="$CFG_PARAM_B"
fi
if [ -z "$PARAM_B" ]; then
    PARAM_B=$(echo "$MODEL_NAME" | grep -ioE '[0-9]+(\.[0-9]+)?[bB]' \
              | grep -ioE '[0-9]+(\.[0-9]+)?' | tail -1 || true)
fi
PARAM_B=${PARAM_B:-7}
MODEL_SIZE_GB=${MODEL_SIZE_GB:-0}
PRE_QUANTIZED=${PRE_QUANTIZED:-0}
NUM_LAYERS=${NUM_LAYERS:-0}
NUM_KV_HEADS=${NUM_KV_HEADS:-0}
HEAD_DIM=${HEAD_DIM:-0}
MAX_POS_EMBED=${MAX_POS_EMBED:-0}

# ---- Early VRAM check: fail fast if model can't possibly fit ----
if [ "$(echo "$MODEL_SIZE_GB $VRAM_GIB" | awk '{print ($1 > $2)}')" = "1" ]; then
    echo -e "${RED}[FAIL] Model weights are ${MODEL_SIZE_GB} GB but GPU only has ${VRAM_GIB} GiB VRAM.${NC}"
    echo -e "${RED}  This model cannot fit in your GPU memory.${NC}"
    echo -e "${YELLOW}  Options:${NC}"
    echo -e "${YELLOW}    1. Use a smaller/more quantized variant of this model${NC}"
    echo -e "${YELLOW}    2. Use a smaller model (e.g. 7B instead of 70B)${NC}"
    if [ "$GPU_COUNT" -eq 1 ]; then
        echo -e "${YELLOW}    3. Add more GPUs and use tensor parallelism${NC}"
    fi
    exit 1
fi

# ---- Calculate max-model-len from REAL config values ----
# KV cache per token per layer = 2 * num_kv_heads * head_dim * dtype_bytes (fp16=2)
# Total KV per token = num_layers * kv_per_token_per_layer
# Available VRAM for KV = total_vram * gpu_util - model_weights - overhead
MODEL_LEN=$(awk -v vram="$VRAM_GIB" -v model_gb="$MODEL_SIZE_GB" \
                -v num_layers="$NUM_LAYERS" -v num_kv_heads="$NUM_KV_HEADS" \
                -v head_dim="$HEAD_DIM" -v max_pos="$MAX_POS_EMBED" \
                -v pre_q="$PRE_QUANTIZED" -v pb="$PARAM_B" '
BEGIN {
    usable_gb = vram * 0.85  # leave 15% for driver/OS/fragmentation

    # Model weight VRAM = file size on disk (what gets loaded)
    # Plus ~20% overhead for activations, optimizer states, buffers
    if (model_gb > 0) {
        weight_vram = model_gb * 1.2
    } else if (pre_q == 1) {
        weight_vram = pb * 0.5 * 1.2
    } else {
        weight_vram = pb * 1.0 * 1.2
    }

    kv_avail_gb = usable_gb - weight_vram
    if (kv_avail_gb <= 0) {
        # Model barely fits, use minimum context
        printf "%d", 512
        exit
    }

    # KV cache per token (bytes) from REAL config values
    if (num_layers > 0 && num_kv_heads > 0 && head_dim > 0) {
        # 2 = key + value, 2 = fp16 bytes
        kv_bytes_per_token = num_layers * 2 * num_kv_heads * head_dim * 2
    } else {
        # Fallback: rough estimate based on param count
        kv_bytes_per_token = pb * 100000  # ~0.1 MB per billion params per token
    }

    if (kv_bytes_per_token > 0) {
        kv_avail_bytes = kv_avail_gb * 1024 * 1024 * 1024
        raw = kv_avail_bytes / kv_bytes_per_token
    } else {
        raw = 2048
    }

    # Cap at model max context length from config.json
    if (max_pos > 0 && raw > max_pos) raw = max_pos

    # Clamp and align
    if (raw < 512)    raw = 512
    if (raw > 32768)  raw = 32768
    len = int(raw / 256) * 256
    printf "%d", len
}')

echo -e "  Model size:  ~${PARAM_B}B params"
if [ "$(echo "$MODEL_SIZE_GB" | awk '{print ($1 > 0)}')" = "1" ]; then
    echo -e "  Weight files: ${MODEL_SIZE_GB} GB on disk"
fi
echo -e "  VRAM:        ${VRAM_GIB} GiB x ${GPU_COUNT} GPU(s)"
echo -e "  Quantization: ${QUANT_DISPLAY}"
if [ "$NUM_LAYERS" -gt 0 ] && [ "$NUM_KV_HEADS" -gt 0 ]; then
    echo -e "  KV config:   ${NUM_LAYERS} layers, ${NUM_KV_HEADS} KV heads, head_dim=${HEAD_DIM}"
fi
if [ "$MAX_POS_EMBED" -gt 0 ]; then
    echo -e "  Model max context: ${MAX_POS_EMBED}"
fi
echo -e "${GREEN}  max-model-len: ${MODEL_LEN}${NC}"

TP_ARG=""
[ "$GPU_COUNT" -gt 1 ] && TP_ARG="-tp ${GPU_COUNT}"

# For pre-quantized models: let vLLM auto-detect from config.json (no --quantization flag)
#   BUT pass --allow-deprecated-quantization because vLLM still reads quantization_config
#   from config.json and will reject deprecated methods (e.g. auto-round) without it.
# For non-quantized models: apply FP8 online quantization (Intel spec default)
QUANT_ARGS=""
if [ "$PRE_QUANTIZED" -eq 1 ]; then
    QUANT_ARGS="--allow-deprecated-quantization"
else
    QUANT_ARGS="--quantization fp8"
fi

# ==============================================================================
# STEP 7: Start vLLM server (Intel spec) with OOM auto-retry
# ==============================================================================

start_vllm_server() {
    local cur_model_len=$1

    sudo docker exec "$CONTAINER_NAME" pkill -f "vllm serve" 2>/dev/null || true
    sleep 2
    sudo docker exec "$CONTAINER_NAME" bash -c "> /tmp/vllm_server.log"

    echo -e "${YELLOW}Starting vLLM server (port ${VLLM_PORT}, max-model-len=${cur_model_len})...${NC}"
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
            --max-num-batched-tokens=${cur_model_len} \
            --disable-log-requests \
            --max-model-len=${cur_model_len} \
            --block-size 64 \
            ${QUANT_ARGS} \
            ${TP_ARG} \
        > /tmp/vllm_server.log 2>&1
    "

    echo -e "${CYAN}  Log: sudo docker exec ${CONTAINER_NAME} tail -f /tmp/vllm_server.log${NC}"
    echo -e "${YELLOW}Waiting for server...${NC}"

    local N=0
    while ! curl -sf "http://localhost:${VLLM_PORT}/v1/models" >/dev/null 2>&1; do
        sleep 5; N=$((N+1))

        # Show progress every 30s
        if [ $((N % 6)) -eq 0 ]; then
            LAST_LINE=$(sudo docker exec "$CONTAINER_NAME" tail -1 /tmp/vllm_server.log 2>/dev/null || echo "")
            echo -e "\n  ${CYAN}[${N}0s] ${LAST_LINE}${NC}"
        else
            echo -n "."
        fi

        # Crash detection — check if process died
        if ! sudo docker exec "$CONTAINER_NAME" pgrep -f "vllm" >/dev/null 2>&1; then
            # Check if OOM
            if sudo docker exec "$CONTAINER_NAME" grep -qi "OUT_OF.*MEMORY\|CUDA out of memory\|out of memory\|UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY" /tmp/vllm_server.log 2>/dev/null; then
                echo -e "\n${RED}[OOM] Out of GPU memory at max-model-len=${cur_model_len}${NC}"
                return 2  # OOM exit code
            fi
            echo -e "\n${RED}[FAIL] Server crashed. Full log:${NC}"
            sudo docker exec "$CONTAINER_NAME" cat /tmp/vllm_server.log
            return 1  # non-OOM crash
        fi

        if [ $N -ge 60 ]; then
            echo -e "\n${RED}[FAIL] Timeout (5 min). Log:${NC}"
            sudo docker exec "$CONTAINER_NAME" tail -30 /tmp/vllm_server.log
            return 1
        fi
    done
    echo -e "\n${GREEN}[OK] Server ready (max-model-len=${cur_model_len}).${NC}"
    return 0
}

echo -e "\n${CYAN}--- Starting vLLM Server ---${NC}"

# Try starting with calculated MODEL_LEN, auto-retry with halved value on OOM
VLLM_STARTED=false
CURRENT_MODEL_LEN=$MODEL_LEN
MAX_OOM_RETRIES=3

for attempt in $(seq 1 $((MAX_OOM_RETRIES + 1))); do
    start_vllm_server "$CURRENT_MODEL_LEN"
    rc=$?
    if [ $rc -eq 0 ]; then
        VLLM_STARTED=true
        MODEL_LEN=$CURRENT_MODEL_LEN
        break
    elif [ $rc -eq 2 ]; then
        # OOM — halve max-model-len and retry
        CURRENT_MODEL_LEN=$(( CURRENT_MODEL_LEN / 2 ))
        # Floor at 512
        [ "$CURRENT_MODEL_LEN" -lt 512 ] && CURRENT_MODEL_LEN=512
        if [ $attempt -le $MAX_OOM_RETRIES ]; then
            echo -e "${YELLOW}  Retrying with max-model-len=${CURRENT_MODEL_LEN}...${NC}"
        fi
    else
        # Non-OOM crash — don't retry
        exit 1
    fi
done

if [ "$VLLM_STARTED" = false ]; then
    echo -e "${RED}[FAIL] Could not start vLLM even with max-model-len=${CURRENT_MODEL_LEN}.${NC}"
    echo -e "${RED}  The model is too large for your GPU's ${VRAM_GIB} GiB VRAM.${NC}"
    echo -e "${YELLOW}  Try a smaller model or a more aggressively quantized variant.${NC}"
    exit 1
fi

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
