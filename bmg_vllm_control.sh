#!/bin/bash
# ==============================================================================
# BMG vLLM Ultimate Control Center (Intel Spec)
# - Integrated GPU Hardware Monitor (C-based, discrete card aware)
# - Smart max-model-len calculator (VRAM x Quant x Model Size)
# - Official Intel vLLM Benchmark mode
# ==============================================================================
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
MONITOR_BIN="/usr/local/bin/bmg_monitor"
MONITOR_SRC="/tmp/bmg_monitor.c"
# ==============================================================================
# SECTION A: Embed & Compile the C GPU Monitor
# ==============================================================================
embed_monitor() {
cat << 'MONITOR_EOF' > "$MONITOR_SRC"
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>
#include <dirent.h>
#include <time.h>
#define MAX_GPUS 8
typedef struct {
    char card_name[16];
    char pci_id[64];
    char root_port[64];
    char pci_speed[16];
    char pci_width[16];
    char hwmon_dir[64];
    int xpu_id;
    int card_num;
    char path_vram[256];
    char path_power[256];
    char path_fan[256];
    long long power_prev;
    struct timespec ts_prev;
} GPUInfo;
void get_all_xpu_smi_values(int m_flag, double *values_array, int max_devices) {
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "xpu-smi dump -m %d -n 1 2>/dev/null", m_flag);
    FILE *fp = popen(cmd, "r");
    char buffer[256];
    for (int i = 0; i < max_devices; i++) values_array[i] = -1.0;
    if (fp) {
        while (fgets(buffer, sizeof(buffer), fp)) {
            char *first_comma = strchr(buffer, ',');
            if (first_comma) {
                char *second_comma = strchr(first_comma + 1, ',');
                if (second_comma) {
                    int dev_id; double val;
                    if (sscanf(first_comma + 1, "%d", &dev_id) == 1 &&
                        dev_id >= 0 && dev_id < max_devices)
                        if (sscanf(second_comma + 1, "%lf", &val) == 1)
                            values_array[dev_id] = val;
                }
            }
        }
        pclose(fp);
    }
}
int main() {
    GPUInfo gpus[MAX_GPUS];
    int gpu_count = 0;
    printf("Scanning PCIe Device and Address...\n");
    for (int i = 0; i < 32 && gpu_count < MAX_GPUS; i++) {
        char vendor_path[256];
        snprintf(vendor_path, sizeof(vendor_path),
                 "/sys/class/drm/card%d/device/vendor", i);
        FILE *fp = fopen(vendor_path, "r");
        if (!fp) continue;
        char vendor[16] = {0};
        fscanf(fp, "%s", vendor);
        fclose(fp);
        if (strcmp(vendor, "0x8086") != 0) continue;
        char device_link[256], resolved_path[PATH_MAX];
        snprintf(device_link, sizeof(device_link),
                 "/sys/class/drm/card%d/device", i);
        if (realpath(device_link, resolved_path) == NULL) continue;
        GPUInfo *gpu = &gpus[gpu_count];
        snprintf(gpu->card_name, sizeof(gpu->card_name), "card%d", i);
        gpu->card_num = i;
        char *last_slash = strrchr(resolved_path, '/');
        if (last_slash) strcpy(gpu->pci_id, last_slash + 1);
        /* Top-down Root Port parse */
        char root_port[64] = "Unknown";
        char *pci_str = strstr(resolved_path, "/pci");
        if (pci_str) {
            char *first_slash = strchr(pci_str + 1, '/');
            if (first_slash) {
                char *rp_start = first_slash + 1;
                char *rp_end   = strchr(rp_start, '/');
                if (rp_end && (rp_end - rp_start < (int)sizeof(root_port))) {
                    strncpy(root_port, rp_start, rp_end - rp_start);
                    root_port[rp_end - rp_start] = '\0';
                }
            }
        }
        strcpy(gpu->root_port, root_port);
        /* PCIe speed/width — prefer root port, fall back to device */
        char speed_path[256], width_path[256];
        snprintf(speed_path, sizeof(speed_path),
                 "/sys/bus/pci/devices/%s/current_link_speed", gpu->root_port);
        snprintf(width_path, sizeof(width_path),
                 "/sys/bus/pci/devices/%s/current_link_width", gpu->root_port);
        FILE *fs = fopen(speed_path, "r");
        if (!fs) {
            snprintf(speed_path, sizeof(speed_path),
                     "/sys/bus/pci/devices/%s/current_link_speed", gpu->pci_id);
            fs = fopen(speed_path, "r");
        }
        if (fs) {
            fgets(gpu->pci_speed, sizeof(gpu->pci_speed), fs);
            gpu->pci_speed[strcspn(gpu->pci_speed, "\n")] = 0;
            fclose(fs);
        } else strcpy(gpu->pci_speed, "N/A");
        FILE *fw = fopen(width_path, "r");
        if (!fw) {
            snprintf(width_path, sizeof(width_path),
                     "/sys/bus/pci/devices/%s/current_link_width", gpu->pci_id);
            fw = fopen(width_path, "r");
        }
        if (fw) {
            fgets(gpu->pci_width, sizeof(gpu->pci_width), fw);
            gpu->pci_width[strcspn(gpu->pci_width, "\n")] = 0;
            fclose(fw);
        } else strcpy(gpu->pci_width, "N/A");
        /* hwmon */
        char hwmon_base[256];
        snprintf(hwmon_base, sizeof(hwmon_base),
                 "/sys/class/drm/card%d/device/hwmon/", i);
        DIR *dir = opendir(hwmon_base);
        struct dirent *entry;
        gpu->hwmon_dir[0] = '\0';
        if (dir) {
            while ((entry = readdir(dir)) != NULL)
                if (strncmp(entry->d_name, "hwmon", 5) == 0) {
                    strcpy(gpu->hwmon_dir, entry->d_name); break;
                }
            closedir(dir);
        }
        /* BUG FIX: vram0_mm uses card number (integer), not PCI BDF address */
        snprintf(gpu->path_vram, sizeof(gpu->path_vram),
                 "/sys/kernel/debug/dri/%d/vram0_mm", i);
        if (strlen(gpu->hwmon_dir) > 0) {
            snprintf(gpu->path_power, sizeof(gpu->path_power),
                     "/sys/class/drm/card%d/device/hwmon/%s/energy1_input",
                     i, gpu->hwmon_dir);
            snprintf(gpu->path_fan, sizeof(gpu->path_fan),
                     "/sys/class/drm/card%d/device/hwmon/%s/fan1_input",
                     i, gpu->hwmon_dir);
        } else { gpu->path_power[0] = '\0'; gpu->path_fan[0] = '\0'; }
        gpu->power_prev = -1;
        clock_gettime(CLOCK_MONOTONIC, &gpu->ts_prev);
        gpu_count++;
    }
    if (gpu_count == 0) {
        printf("No compatible Intel discrete GPU found.\n"); return 1;
    }
    /* Sort by BDF */
    for (int i = 0; i < gpu_count - 1; i++)
        for (int j = 0; j < gpu_count - i - 1; j++)
            if (strcmp(gpus[j].pci_id, gpus[j+1].pci_id) > 0) {
                GPUInfo tmp = gpus[j]; gpus[j] = gpus[j+1]; gpus[j+1] = tmp;
            }
    for (int i = 0; i < gpu_count; i++) gpus[i].xpu_id = i;
    while (1) {
        double temps[MAX_GPUS], freqs[MAX_GPUS], usages[MAX_GPUS];
        get_all_xpu_smi_values(3,  temps,  MAX_GPUS);
        get_all_xpu_smi_values(2,  freqs,  MAX_GPUS);
        get_all_xpu_smi_values(32, usages, MAX_GPUS);
        printf("\033[2J\033[H");
        printf("=================================================================\n");
        printf(" BMG Monitor Dashboard (Battlemage Intel ARC)\n");
        printf("=================================================================\n");
        for (int i = 0; i < gpu_count; i++) {
            GPUInfo *gpu = &gpus[i];
            long long power_now = -1;
            int fan = -1, vram_free = -1;
            long long vram_size = -1, vram_usage = -1;
            double vram_pct = -1.0;
            if (strlen(gpu->path_power) > 0) {
                FILE *fp = fopen(gpu->path_power, "r");
                if (fp) { fscanf(fp, "%lld", &power_now); fclose(fp); }
            }
            if (strlen(gpu->path_fan) > 0) {
                FILE *fp = fopen(gpu->path_fan, "r");
                if (fp) { fscanf(fp, "%d", &fan); fclose(fp); }
            }
            FILE *fp_vram = fopen(gpu->path_vram, "r");
            if (fp_vram) {
                char line[256];
                while (fgets(line, sizeof(line), fp_vram)) {
                    if      (strstr(line, "size:"))
                        sscanf(strstr(line,"size:"),         "size: %lld",        &vram_size);
                    else if (strstr(line, "usage:"))
                        sscanf(strstr(line,"usage:"),        "usage: %lld",       &vram_usage);
                    else if (strstr(line, "visible_avail:"))
                        sscanf(strstr(line,"visible_avail:"),"visible_avail: %d", &vram_free);
                }
                fclose(fp_vram);
            }
            if (vram_size > 0 && vram_usage >= 0)
                vram_pct = (double)vram_usage / (double)vram_size * 100.0;
            struct timespec ts_now;
            clock_gettime(CLOCK_MONOTONIC, &ts_now);
            double power_w = -1.0;
            if (power_now != -1 && gpu->power_prev != -1) {
                double dt = (ts_now.tv_sec  - gpu->ts_prev.tv_sec) +
                            (ts_now.tv_nsec - gpu->ts_prev.tv_nsec) / 1e9;
                if (dt > 0)
                    power_w = (double)(power_now - gpu->power_prev) / 1e6 / dt;
            }
            printf(" [GPU %d] %s | PCIe: %s | %s\n",
                   gpu->xpu_id, gpu->card_name, gpu->pci_id,
                   strlen(gpu->hwmon_dir) > 0 ? gpu->hwmon_dir : "HWMon: N/A");
            printf("  +-- Root Port : %-15s| PCIe Link: %s x%s\n",
                   gpu->root_port, gpu->pci_speed, gpu->pci_width);
            printf("  +----------------------------+-----------------------------\n");
            printf("  +-- GPU Render Usage : ");
            if (usages[gpu->xpu_id] >= 0) printf("%6.1f %%    ", usages[gpu->xpu_id]);
            else                          printf("   [N/A]    ");
            printf("| Core Freq : ");
            if (freqs[gpu->xpu_id] >= 0)  printf("%6.0f MHz\n", freqs[gpu->xpu_id]);
            else                          printf("  [N/A]\n");
            printf("  +-- VRAM Usage       : ");
            if (vram_pct >= 0)            printf("%6.1f %%    ", vram_pct);
            else                          printf("   [N/A]    ");
            printf("| VRAM Free : ");
            if (vram_free >= 0)           printf("%6d MiB\n", vram_free);
            else                          printf("  [N/A]\n");
            printf("  +-- GPU Power        : ");
            if (power_w >= 0)             printf("%6.2f W     ", power_w);
            else                          printf("  Calc...    ");
            printf("| Temp      : ");
            if (temps[gpu->xpu_id] >= 0)  printf("%6.1f C\n", temps[gpu->xpu_id]);
            else                          printf("  [N/A]\n");
            printf("  +-- Fan Speed        : ");
            if (fan >= 0)                 printf("%6d RPM\n", fan);
            else                          printf("   [N/A]\n");
            printf("=================================================================\n");
            if (power_now != -1) {
                gpu->power_prev = power_now;
                gpu->ts_prev    = ts_now;
            }
        }
        usleep(2000000);
    }
    return 0;
}
MONITOR_EOF
}
compile_monitor() {
    if [ ! -f "$MONITOR_BIN" ]; then
        echo -e "${YELLOW}[Monitor] Compiling bmg_monitor for the first time...${NC}"
        embed_monitor
        if sudo gcc -O2 -o "$MONITOR_BIN" "$MONITOR_SRC" 2>&1; then
            echo -e "${GREEN}[OK] Monitor compiled -> ${MONITOR_BIN}${NC}"
        else
            echo -e "${RED}[FAIL] Monitor compile failed (is gcc installed?). Monitor disabled.${NC}"
            MONITOR_BIN=""
        fi
    fi
}
launch_monitor_tmux() {
    [ -z "$MONITOR_BIN" ] && return
    # Option 1: already inside tmux -> split pane
    if command -v tmux &>/dev/null; then
        if [ -n "$TMUX" ]; then
            tmux split-window -h "sudo $MONITOR_BIN"
            tmux select-pane -t 0
        else
            tmux new-session -d -s bmg_session 2>/dev/null || true
            tmux split-window -h -t bmg_session "sudo $MONITOR_BIN" 2>/dev/null || true
            tmux select-pane -t bmg_session:0.0
            tmux attach -t bmg_session &
            sleep 1
        fi
        echo -e "${GREEN}[OK] Monitor running in right tmux pane.${NC}"
        return
    fi
    # Option 2: detect a GUI terminal emulator
    local launched=0
    local TERM_LIST=("gnome-terminal" "xterm" "konsole" "xfce4-terminal" "lxterminal" "mate-terminal" "tilix" "alacritty" "kitty")
    declare -A TERM_ARGS
    TERM_ARGS["gnome-terminal"]="-- sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["xterm"]="-title BMG_Monitor -e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["konsole"]="--new-tab -e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["xfce4-terminal"]="-e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["lxterminal"]="-e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["mate-terminal"]="-e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["tilix"]="-e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["alacritty"]="-e sudo MONITOR_BIN_PLACEHOLDER"
    TERM_ARGS["kitty"]="sudo MONITOR_BIN_PLACEHOLDER"
    for term in "${TERM_LIST[@]}"; do
        if command -v "$term" &>/dev/null; then
            local args="${TERM_ARGS[$term]//MONITOR_BIN_PLACEHOLDER/$MONITOR_BIN}"
            eval "$term $args" &
            sleep 1
            echo -e "${GREEN}[OK] Monitor launched in ${term} window.${NC}"
            launched=1
            break
        fi
    done
    # Option 3: background + log file fallback
    if [ "$launched" -eq 0 ]; then
        echo -e "${YELLOW}[Monitor] No GUI terminal or tmux found. Starting monitor in background.${NC}"
        sudo "$MONITOR_BIN" > /tmp/bmg_monitor.log 2>&1 &
        MONITOR_PID=$!
        echo -e "${GREEN}[OK] Monitor PID=${MONITOR_PID} running in background.${NC}"
        echo -e "${CYAN}    Live view : tail -f /tmp/bmg_monitor.log${NC}"
        echo -e "${CYAN}    Stop      : sudo kill ${MONITOR_PID}${NC}"
    fi
}
# ==============================================================================
# SECTION B: Actual VRAM Detection
# ==============================================================================
detect_vram_per_gpu() {
    # xpu-smi discovery reports physical memory size
    local mib
    mib=$(xpu-smi discovery 2>/dev/null \
          | grep -i "memory size" | head -1 \
          | grep -oE '[0-9]+' | tail -1)
    if [ -n "$mib" ] && [ "$mib" -gt 512 ]; then
        echo $(( mib / 1024 )); return
    fi
    # Fallback: sysfs vram0_mm (size field = pages, page = 4 KiB)
    local pages
    pages=$(sudo cat /sys/kernel/debug/dri/*/vram0_mm 2>/dev/null \
            | awk '/^size:/{print $2; exit}')
    if [ -n "$pages" ] && [ "$pages" -gt 0 ]; then
        echo $(( pages * 4 / 1024 / 1024 )); return
    fi
    echo 16   # safe default for B580/B770
}
# ==============================================================================
# SECTION C: Smart max-model-len Calculator
#
# Formula:
#   model_mem_GB  = param_B  x  (quant_bits / 8)  x  1.05  (5% overhead)
#   kv_per_tok_MB = param_B  x  0.20               (fp16 KV cache, empirical)
#   kv_avail_GB   = (vram_per_gpu x gpu_count x 0.90) - model_mem_GB
#   max_len       = (kv_avail_GB x 1024) / kv_per_tok_MB
#   Clamp:        [2048 .. 131072], rounded to nearest 512
# ==============================================================================
calculate_model_len() {
    local model_name="$1"
    local vram_gb="$2"
    local gpu_count="$3"
    local mn
    mn=$(echo "$model_name" | tr '[:upper:]' '[:lower:]')
    # --- Quantization detection ---
    local quant_bits=16 quant_label="FP16/BF16"
    if   echo "$mn" | grep -qE 'q3|3bit|3_bit';               then quant_bits=3;  quant_label="Q3"
    elif echo "$mn" | grep -qE 'q4|4bit|4_bit|int4|w4a';      then quant_bits=4;  quant_label="Q4"
    elif echo "$mn" | grep -qE 'q5|5bit|5_bit';               then quant_bits=5;  quant_label="Q5"
    elif echo "$mn" | grep -qE 'q6|6bit|6_bit';               then quant_bits=6;  quant_label="Q6"
    elif echo "$mn" | grep -qE 'q8|8bit|8_bit|int8|w8a';      then quant_bits=8;  quant_label="Q8/INT8"
    elif echo "$mn" | grep -qE 'fp32|float32';                then quant_bits=32; quant_label="FP32"
    fi
    # --- Model size in billions ---
    local param_b
    # Use tail -1 to pick the LAST B-suffixed number (e.g. "Qwen3.5-0.5B" -> 0.5)
    param_b=$(echo "$model_name" | grep -ioE '[0-9]+(\.[0-9]+)?[bB]' \
              | grep -ioE '[0-9]+(\.[0-9]+)?' | tail -1)
    param_b=${param_b:-7}
    param_b=$(awk "BEGIN{printf \"%.0f\", $param_b}")
    # --- Compute via awk (float arithmetic) ---
    local result
    result=$(awk -v vram="$vram_gb" -v gpus="$gpu_count" \
                 -v qbits="$quant_bits" -v pb="$param_b" '
    BEGIN {
        total_usable  = vram * gpus * 0.90
        model_gb      = pb * (qbits / 8.0) * 1.05
        kv_avail_gb   = total_usable - model_gb
        if (kv_avail_gb < 0.5) kv_avail_gb = 0.5
        kv_mb_per_tok = pb * 0.20
        raw           = (kv_avail_gb * 1024) / kv_mb_per_tok
        if (raw < 2048)   raw = 2048
        if (raw > 131072) raw = 131072
        max_len = int(raw / 512) * 512
        printf "%d %.2f %.2f", max_len, model_gb, kv_avail_gb
    }')
    local max_len model_gb kv_avail
    max_len=$(echo  "$result" | awk '{print $1}')
    model_gb=$(echo "$result" | awk '{print $2}')
    kv_avail=$(echo "$result" | awk '{print $3}')
    echo -e "${CYAN}[Smart Model Profiler]${NC}"
    printf "  %-22s %dB params\n"          "Model size:"    "$param_b"
    printf "  %-22s %s (%d bits/weight)\n" "Quantization:"  "$quant_label" "$quant_bits"
    printf "  %-22s %s GB x %d GPU(s) x 90%% = %s GB usable\n" \
           "Total VRAM:" "$vram_gb" "$gpu_count" \
           "$(awk "BEGIN{printf \"%.1f\", $vram_gb*$gpu_count*0.9}")"
    printf "  %-22s ~%s GB\n"              "Model memory:"  "$model_gb"
    printf "  %-22s ~%s GB\n"              "KV headroom:"   "$kv_avail"
    echo -e "  ${GREEN}Recommended max-model-len: ${max_len}${NC}\n"
    RECOMMENDED_LEN=$max_len
}
# ==============================================================================
# MAIN
# ==============================================================================
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}     BMG vLLM Ultimate Control Center (Intel Spec)    ${NC}"
echo -e "${CYAN}======================================================${NC}"
compile_monitor
# ------------------------------------------------------------------------------
# STEP 1: Driver Check
# ------------------------------------------------------------------------------
if ! command -v xpu-smi &>/dev/null && [ ! -f "/usr/bin/xpu-smi" ]; then
    echo -e "${RED}[!] xpu-smi not found -- Intel drivers missing.${NC}"
    read -p "Have offline installer ready? (y/n): " HAS_INSTALLER
    if [[ "$HAS_INSTALLER" =~ ^[Yy]$ ]]; then
        read -e -p "Path to installer folder: " INSTALLER_PATH
        if [ -d "$INSTALLER_PATH" ] && [ -f "$INSTALLER_PATH/installer.sh" ]; then
            cd "$INSTALLER_PATH" && sudo ./installer.sh
            echo -e "${YELLOW}Reboot required.${NC}"
            read -n 1 -s -r -p "Press any key to reboot..."
            sudo reboot; exit 0
        fi
    fi
    echo -e "${YELLOW}Install Arc GPU drivers and rerun.${NC}"; exit 1
fi
# ------------------------------------------------------------------------------
# STEP 2: Docker
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}--- Docker Setup ---${NC}"
mkdir -p /home/intel/LLM
# Prompt for image version per Intel README (avoid using "latest")
echo -e "${YELLOW}[!] Intel README recommends using a specific release version, not 'latest'.${NC}"
echo -e "${YELLOW}    Check available versions at: https://github.com/intel/llm-scaler/releases${NC}"
read -p "Docker image version (e.g. 0.6.6.post1, or press Enter for 'latest'): " IMG_VERSION
IMG_VERSION=${IMG_VERSION:-latest}
DOCKER_IMAGE="intel/llm-scaler-vllm:${IMG_VERSION}"
if ! sudo docker ps -a --format '{{.Names}}' | grep -q "^lsv-container$"; then
    echo -e "${YELLOW}Creating lsv-container (Intel official spec)...${NC}"
    sudo docker pull "${DOCKER_IMAGE}"
    sudo docker run -td \
        --privileged --net=host --device=/dev/dri \
        --name=lsv-container \
        -v /home/intel/LLM:/llm/models/ \
        -e no_proxy=localhost,127.0.0.1 \
        -e http_proxy="$http_proxy" \
        -e https_proxy="$https_proxy" \
        --shm-size="32g" \
        --entrypoint /bin/bash \
        "${DOCKER_IMAGE}"
else
    echo -e "${GREEN}[OK] Container ready.${NC}"
    sudo docker start lsv-container >/dev/null
fi
# Ensure transformers is up-to-date inside the container.
# New HuggingFace models (e.g. Qwen3.5) add new architecture types that
# older transformers versions don't recognize, causing vLLM to crash with:
#   "model type `qwen3_5` but Transformers does not recognize this architecture"
echo -e "${YELLOW}[Container] Upgrading transformers (for newest model support)...${NC}"
sudo docker exec lsv-container pip install --upgrade transformers 2>&1 | tail -1
echo -e "${GREEN}[OK] Container dependencies up to date.${NC}"
# ------------------------------------------------------------------------------
# STEP 3: Model Selection
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}--- Model Selection ---${NC}"
echo "Models already in /home/intel/LLM/:"
ls -1 /home/intel/LLM/ | grep -v '^\.' || echo "(none)"
echo "----------------------------------------------"
echo -e "To download a new model, paste the git clone command from HuggingFace:"
echo -e "  ${GREEN}git clone https://huggingface.co/Qwen/Qwen3.5-9B${NC}"
echo -e "Or enter a local folder name if already downloaded:"
echo -e "  ${GREEN}Qwen3.5-9B${NC}"
read -p "Model: " USER_INPUT

# Strip trailing slashes and whitespace
USER_INPUT=$(echo "$USER_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
USER_INPUT="${USER_INPUT%/}"

# Strip "git clone " prefix if user pasted a full git clone command
USER_INPUT="${USER_INPUT#git clone }"

# Parse input: extract model name and build clone URL
if [[ "$USER_INPUT" == https://huggingface.co/* ]]; then
    # Full URL provided -- extract model name from URL
    REPO_PATH="${USER_INPUT#https://huggingface.co/}"
    MODEL_NAME=$(basename "$REPO_PATH")
    CLONE_URL="$USER_INPUT"
else
    # Local folder name -- no download needed
    MODEL_NAME="$USER_INPUT"
    CLONE_URL=""
fi

# Download via git clone if needed
if [ -n "$CLONE_URL" ]; then
    if [ -d "/home/intel/LLM/${MODEL_NAME}" ]; then
        echo -e "${GREEN}[OK] /home/intel/LLM/${MODEL_NAME} already exists, skipping download.${NC}"
    else
        # Auto-install git-lfs if missing (required for HF model weights)
        if ! command -v git-lfs &>/dev/null; then
            echo -e "${YELLOW}[!] git-lfs not found. Installing...${NC}"
            sudo apt install -y git-lfs && git lfs install
            if [ $? -ne 0 ]; then
                echo -e "${RED}[FAIL] Could not install git-lfs. Install manually:${NC}"
                echo -e "${YELLOW}    sudo apt install git-lfs && git lfs install${NC}"
                exit 1
            fi
        fi
        echo -e "\n${YELLOW}Cloning ${CLONE_URL} into /home/intel/LLM/${MODEL_NAME} ...${NC}"
        echo -e "${YELLOW}(This may take a while for large models)${NC}"
        git clone "$CLONE_URL" "/home/intel/LLM/${MODEL_NAME}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}[FAIL] git clone failed. Check the URL and your network connection.${NC}"
            exit 1
        fi
        echo -e "${GREEN}[OK] Model downloaded to /home/intel/LLM/${MODEL_NAME}${NC}"
    fi
fi

# Verify model folder exists
if [ ! -d "/home/intel/LLM/${MODEL_NAME}" ]; then
    echo -e "${RED}[!] /home/intel/LLM/${MODEL_NAME} does not exist.${NC}"
    exit 1
fi
# Pre-flight: check if the model architecture is supported by this container's vLLM
echo -e "${YELLOW}[Check] Verifying model compatibility with container vLLM...${NC}"
MODEL_CHECK=$(sudo docker exec lsv-container python3 -c "
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
            print('UNSUPPORTED:' + a)
            sys.exit(0)
    print('OK')
except Exception as e:
    print('WARN:' + str(e))
" 2>/dev/null || echo "SKIP")
if [[ "$MODEL_CHECK" == UNSUPPORTED:* ]]; then
    BAD_ARCH="${MODEL_CHECK#UNSUPPORTED:}"
    echo -e "${RED}[FAIL] Model architecture '${BAD_ARCH}' is NOT supported by this container's vLLM.${NC}"
    echo -e "${YELLOW}  This model is too new for the installed vLLM version.${NC}"
    echo -e "${YELLOW}  Options:${NC}"
    echo -e "${YELLOW}    1) Use a supported model (e.g. DeepSeek-R1-Distill-Qwen-7B, Qwen2.5-14B-Instruct)${NC}"
    echo -e "${YELLOW}    2) Upgrade the container: docker pull intel/llm-scaler-vllm:<newer-version>${NC}"
    exit 1
elif [[ "$MODEL_CHECK" == OK ]]; then
    echo -e "${GREEN}[OK] Model architecture supported.${NC}"
else
    echo -e "${YELLOW}[WARN] Could not verify model compatibility (continuing anyway).${NC}"
fi
# ------------------------------------------------------------------------------
# STEP 4: Hardware Profiling + Smart Model Len
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}--- Hardware Profiling ---${NC}"
# BUG FIX: grep -rl only lists files that actually match, not all files
GPU_COUNT=$(grep -rl "0x8086" /sys/class/drm/card*/device/vendor 2>/dev/null | wc -l)
[ "$GPU_COUNT" -eq 0 ] && GPU_COUNT=1
VRAM_PER_GPU=$(detect_vram_per_gpu)
echo -e "${GREEN}[OK] ${GPU_COUNT} Intel GPU(s) detected, ~${VRAM_PER_GPU} GB VRAM each.${NC}\n"
calculate_model_len "$MODEL_NAME" "$VRAM_PER_GPU" "$GPU_COUNT"
read -p "Accept recommended max-model-len (${RECOMMENDED_LEN})? [Enter] or type custom: " USER_LEN
MODEL_LEN=${USER_LEN:-$RECOMMENDED_LEN}
echo -e "${GREEN}[OK] max-model-len = ${MODEL_LEN}${NC}"
TP_ARG=""
[ "$GPU_COUNT" -gt 1 ] && TP_ARG="-tp ${GPU_COUNT}"
# ==============================================================================
# Shared server start function (matches Intel llm-scaler spec)
# ==============================================================================
start_vllm_server() {
    local port="$1"
    echo -e "${YELLOW}[vLLM] Starting server on port ${port}...${NC}"
    echo -e "${YELLOW}       --enforce-eager  : skip XPU graph compile (prevents hang)${NC}"
    echo -e "${YELLOW}       --block-size 64  : Intel-specific KV cache block size${NC}"
    echo -e "${YELLOW}       SPAWN method     : required for Intel XPU workers${NC}"
    sudo docker exec lsv-container pkill -f "vllm serve" 2>/dev/null
    sleep 2
    # Clear old log
    sudo docker exec lsv-container bash -c "> /tmp/vllm_server.log"
    # Detect which optional flags the container's vLLM version supports.
    # Flags like --disable-sliding-window and --max-num-batched-tokens
    # don't exist in all versions and cause immediate crash if unsupported.
    local EXTRA_ARGS=""
    local VLLM_HELP
    VLLM_HELP=$(sudo docker exec lsv-container vllm serve --help 2>&1 || true)
    if echo "$VLLM_HELP" | grep -q "disable-sliding-window"; then
        EXTRA_ARGS="${EXTRA_ARGS} --disable-sliding-window"
    fi
    if echo "$VLLM_HELP" | grep -q "max-num-batched-tokens"; then
        EXTRA_ARGS="${EXTRA_ARGS} --max-num-batched-tokens ${MODEL_LEN}"
    fi
    # Start server in background. Use direct file redirect (not pipe/tee)
    # so the detached process reliably writes logs.
    sudo docker exec -d lsv-container bash -c "
        source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
        VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 \
        VLLM_WORKER_MULTIPROC_METHOD=spawn \
        vllm serve /llm/models/${MODEL_NAME} \
            --served-model-name ${MODEL_NAME} \
            --dtype float16 \
            --max-model-len ${MODEL_LEN} \
            --port ${port} \
            --host 0.0.0.0 \
            --enforce-eager \
            --trust-remote-code \
            --gpu-memory-util 0.9 \
            --block-size 64 \
            --disable-log-requests \
            ${TP_ARG} \
            ${EXTRA_ARGS} \
        > /tmp/vllm_server.log 2>&1
    "
    echo -e "${YELLOW}Waiting for server (5 min timeout)...${NC}"
    echo -e "${CYAN}    Log: sudo docker exec lsv-container tail -f /tmp/vllm_server.log${NC}"
    local n=0
    while ! curl -sf "http://localhost:${port}/v1/models" >/dev/null 2>&1; do
        sleep 5; n=$((n+1))
        # Every 6 ticks (30s) show the last log line so user sees progress
        if [ $((n % 6)) -eq 0 ]; then
            echo ""
            echo -e "${CYAN}  [${n}s] $(sudo docker exec lsv-container tail -1 /tmp/vllm_server.log 2>/dev/null)${NC}"
        else
            echo -n "."
        fi
        # Detect if the server process crashed (no more infinite dots)
        if ! sudo docker exec lsv-container pgrep -f "vllm serve" >/dev/null 2>&1; then
            echo -e "\n${RED}[FAIL] Server process died. Log output:${NC}"
            sudo docker exec lsv-container cat /tmp/vllm_server.log
            exit 1
        fi
        if [ $n -ge 60 ]; then
            echo -e "\n${RED}[FAIL] Timeout (5 min). Last 30 lines of server log:${NC}"
            sudo docker exec lsv-container tail -30 /tmp/vllm_server.log
            exit 1
        fi
    done
    echo -e "\n${GREEN}[OK] Server ready on port ${port}.${NC}"
}
# ------------------------------------------------------------------------------
# STEP 5: Mode Selection
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}======================================================${NC}"
echo -e "${CYAN}              Select Execution Mode                   ${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}1) Online API + Web GUI${NC}     (Live Chat + Stress Test)"
echo -e "${YELLOW}2) Offline Batch Inference${NC}  (.txt / .csv max throughput)"
echo -e "${CYAN}3) Official Intel Benchmark${NC} (vllm bench serve -- matches Intel spec)"
echo -e "${RED}4) GPU Hardware Monitor${NC}     (BMG live dashboard -- standalone)"
read -p "Choose mode (1/2/3/4): " EXEC_MODE
# ==============================================================================
# MODE 1: Online API + Gradio GUI
# ==============================================================================
if [ "$EXEC_MODE" == "1" ]; then
    read -p "API Port   (Default 8000): " VLLM_PORT; VLLM_PORT=${VLLM_PORT:-8000}
    read -p "Web GUI Port (Default 7860): " GUI_PORT;  GUI_PORT=${GUI_PORT:-7860}
    if curl -s "http://localhost:${VLLM_PORT}/v1/models" | grep -q "$MODEL_NAME"; then
        echo -e "${GREEN}[OK] Server already running with this model.${NC}"
    else
        start_vllm_server "$VLLM_PORT"
    fi
    read -p "Launch GPU monitor in tmux split? (y/n) [y]: " DO_MON
    [[ "${DO_MON:-y}" =~ ^[Yy]$ ]] && launch_monitor_tmux
    echo -e "${YELLOW}Installing gradio / openai...${NC}"
    pip install -q gradio openai
    cat << 'EOF' > /tmp/web_gui.py
import gradio as gr, time, sys, concurrent.futures
from openai import OpenAI
MODEL_NAME = sys.argv[1]
VLLM_PORT  = sys.argv[2]
GUI_PORT   = int(sys.argv[3])
client     = OpenAI(base_url=f"http://localhost:{VLLM_PORT}/v1", api_key="EMPTY")
def chat_stream(message, history):
    msgs = []
    for h in history:
        msgs.append({"role": "user",      "content": h[0]})
        msgs.append({"role": "assistant", "content": h[1]})
    msgs.append({"role": "user", "content": message})
    t0 = time.time(); ttft = None; tokens = 0
    try:
        stream = client.chat.completions.create(
            model=MODEL_NAME, messages=msgs, stream=True,
            stream_options={"include_usage": True})
        out = ""
        for chunk in stream:
            if chunk.choices and chunk.choices[0].delta.content:
                out += chunk.choices[0].delta.content; tokens += 1
                if ttft is None: ttft = time.time()
                yield out
        t1   = time.time()
        ttft_s = (ttft - t0) if ttft else 0
        tps    = tokens / (t1 - ttft) if ttft and (t1 - ttft) > 0 else 0
        yield out + (f"\n\n---\n**TTFT:** {ttft_s:.3f}s | "
                     f"**Speed:** {tps:.2f} t/s | "
                     f"**Total:** {t1-t0:.2f}s")
    except Exception as e:
        yield f"**Error:** {e}"
def run_benchmark(concurrency, total_requests, max_tokens, prompt):
    yield f"Starting benchmark (concurrency={concurrency}, requests={total_requests})..."
    t0 = time.time(); results = []
    def make_request():
        t_req = time.time(); ttft = None; tokens = 0
        try:
            r = client.chat.completions.create(
                model=MODEL_NAME,
                messages=[{"role": "user", "content": prompt}],
                max_tokens=max_tokens, stream=True)
            for c in r:
                if c.choices and c.choices[0].delta.content:
                    if ttft is None: ttft = time.time() - t_req
                    tokens += 1
            return {"ok": True, "ttft": ttft, "tokens": tokens}
        except:
            return {"ok": False}
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as ex:
        futs = [ex.submit(make_request) for _ in range(total_requests)]
        for n, f in enumerate(concurrent.futures.as_completed(futs), 1):
            results.append(f.result())
            if n % max(1, total_requests // 10) == 0:
                yield f"Progress: {n} / {total_requests}"
    ok      = [r for r in results if r.get("ok")]
    if not ok: yield "All requests failed."; return
    elapsed = time.time() - t0
    avg_ttft = sum(r["ttft"] for r in ok if r["ttft"]) / len(ok)
    tot_toks = sum(r["tokens"] for r in ok)
    yield (f"### Benchmark Results\n"
           f"- Successful : {len(ok)} / {total_requests}\n"
           f"- Total time : {elapsed:.2f}s\n"
           f"- Req/s      : {len(ok)/elapsed:.2f}\n"
           f"- Tokens/s   : {tot_toks/elapsed:.2f}\n"
           f"- Avg TTFT   : {avg_ttft:.3f}s")
with gr.Blocks(title="BMG Control Center") as demo:
    gr.Markdown(f"# BMG vLLM Control Center  |  Model: `{MODEL_NAME}`")
    with gr.Tabs():
        with gr.TabItem("Live Chat"):
            gr.ChatInterface(fn=chat_stream)
        with gr.TabItem("Stress Benchmark"):
            c   = gr.Slider(1, 100, 10,   label="Concurrency")
            r   = gr.Slider(10, 500, 50,  label="Total Requests")
            t   = gr.Slider(10, 1024, 256, label="Max Output Tokens")
            p   = gr.Textbox(value="What is a GPU?", label="Prompt")
            btn = gr.Button("Start")
            out = gr.Markdown("Waiting...")
            btn.click(fn=run_benchmark, inputs=[c, r, t, p], outputs=[out])
demo.launch(server_name="0.0.0.0", server_port=GUI_PORT)
EOF
    python3 /tmp/web_gui.py "$MODEL_NAME" "$VLLM_PORT" "$GUI_PORT"
# ==============================================================================
# MODE 2: Offline Batch Inference
# ==============================================================================
elif [ "$EXEC_MODE" == "2" ]; then
    echo -e "\n${CYAN}--- Offline Batch Configuration ---${NC}"
    echo -e "Place input file in ${YELLOW}/home/intel/LLM/${NC}  (one prompt per line)"
    read -p "Filename (blank = built-in test prompts): " INPUT_FILE
    read -p "Max tokens (Default 256):  " BATCH_TOKENS; BATCH_TOKENS=${BATCH_TOKENS:-256}
    read -p "Temperature (Default 0.7): " BATCH_TEMP;   BATCH_TEMP=${BATCH_TEMP:-0.7}
    sudo docker exec -i lsv-container bash -c "cat << 'PYEOF' > /llm/offline_batch.py
import time, os
from vllm import LLM, SamplingParams
max_tokens  = int('${BATCH_TOKENS}')
temperature = float('${BATCH_TEMP}')
input_file  = '${INPUT_FILE}'
prompts = []
if input_file and os.path.exists(f'/llm/models/{input_file}'):
    print(f'[Info] Reading /llm/models/{input_file}')
    with open(f'/llm/models/{input_file}', 'r', encoding='utf-8') as f:
        prompts = [l.strip() for l in f if l.strip()]
else:
    print('[Info] No file -- using built-in test prompts.')
    prompts = [
        'Explain the architecture of a GPU in detail.',
        'Write a C snippet demonstrating pointer arithmetic.',
        'What is the capital of Japan and why is it significant?',
    ]
print(f'\n[Loading] enforce_eager=True  (required for Intel XPU -- prevents hang)')
llm = LLM(
    model='/llm/models/${MODEL_NAME}',
    max_model_len=int('${MODEL_LEN}'),
    dtype='float16',
    enforce_eager=True,
    trust_remote_code=True,
    gpu_memory_utilization=0.9,
    block_size=64,
)
sampling_params = SamplingParams(temperature=temperature, max_tokens=max_tokens)
print(f'\n[Running] {len(prompts)} prompt(s)...')
t0 = time.time()
outputs = llm.generate(prompts, sampling_params)
elapsed = time.time() - t0
print('\n' + '='*60)
total_tokens = 0
for out in outputs:
    total_tokens += len(out.outputs[0].token_ids)
    print(f'Q: {out.prompt[:80]}')
    print(f'A: {out.outputs[0].text.strip()[:120]}\n')
print('='*60)
print(f'BATCH SUMMARY | Time: {elapsed:.2f}s | Tokens: {total_tokens} | TPS: {total_tokens/elapsed:.2f}')
PYEOF"
    sudo docker exec lsv-container pkill -f "vllm serve" 2>/dev/null
    sudo docker exec -it lsv-container bash -c "
        source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
        python3 /llm/offline_batch.py
    "
# ==============================================================================
# MODE 3: Official Intel vLLM Benchmark  (vllm bench serve)
# ==============================================================================
elif [ "$EXEC_MODE" == "3" ]; then
    echo -e "\n${CYAN}--- Official Intel llm-scaler Benchmark ---${NC}"
    read -p "API Port (Default 8000): " VLLM_PORT; VLLM_PORT=${VLLM_PORT:-8000}
    if ! curl -s "http://localhost:${VLLM_PORT}/v1/models" | grep -q "$MODEL_NAME"; then
        start_vllm_server "$VLLM_PORT"
    else
        echo -e "${GREEN}[OK] Server already running.${NC}"
    fi
    read -p "Launch GPU monitor in tmux split? (y/n) [y]: " DO_MON
    [[ "${DO_MON:-y}" =~ ^[Yy]$ ]] && launch_monitor_tmux
    echo -e "\n${CYAN}--- Benchmark Parameters ---${NC}"
    read -p "Input  token length (Default 1024): " IN_LEN;      IN_LEN=${IN_LEN:-1024}
    read -p "Output token length (Default 512):  " OUT_LEN;     OUT_LEN=${OUT_LEN:-512}
    read -p "Number of prompts   (Default 10):   " NUM_PROMPTS; NUM_PROMPTS=${NUM_PROMPTS:-10}
    read -p "Request rate (inf=max, Default inf): " REQ_RATE;   REQ_RATE=${REQ_RATE:-inf}
    # Guard: input + output + chat-template overhead must fit in context window
    TEMPLATE_OVERHEAD=256   # headroom for chat-template special tokens / role tags
    MAX_TOTAL=$(( MODEL_LEN - TEMPLATE_OVERHEAD ))
    [ "$MAX_TOTAL" -lt 512 ] && MAX_TOTAL=512
    if [ "$(( IN_LEN + OUT_LEN ))" -gt "$MAX_TOTAL" ]; then
        # Scale both proportionally so they fit
        OUT_LEN=$(( MAX_TOTAL * OUT_LEN / (IN_LEN + OUT_LEN) ))
        IN_LEN=$((  MAX_TOTAL - OUT_LEN ))
        # Round down to multiples of 128 for tidiness
        IN_LEN=$((  (IN_LEN  / 128) * 128 ))
        OUT_LEN=$(( (OUT_LEN / 128) * 128 ))
        [ "$IN_LEN"  -lt 128 ] && IN_LEN=128
        [ "$OUT_LEN" -lt 128 ] && OUT_LEN=128
        echo -e "${YELLOW}[!] IN+OUT exceeds max-model-len (${MODEL_LEN}).${NC}"
        echo -e "${YELLOW}    Adjusted -> input=${IN_LEN}, output=${OUT_LEN} (template overhead=${TEMPLATE_OVERHEAD})${NC}"
    fi
    # BUG FIX: Match the exact official Intel benchmark command from the README.
    # Removed: --tokenizer, --tokenizer-mode, --endpoint (not in official spec)
    # Removed: HF_DATASETS_OFFLINE / TRANSFORMERS_OFFLINE (blocks tokenizer loading)
    # Fixed:   --num-prompt (singular, matching Intel README)
    echo -e "\n${YELLOW}Running vllm bench serve (Intel official method)...${NC}"
    sudo docker exec -it lsv-container bash -c "
        source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
        vllm bench serve \
            --model /llm/models/${MODEL_NAME} \
            --dataset-name random \
            --served-model-name ${MODEL_NAME} \
            --random-input-len ${IN_LEN} \
            --random-output-len ${OUT_LEN} \
            --ignore-eos \
            --num-prompt ${NUM_PROMPTS} \
            --trust-remote-code \
            --request-rate ${REQ_RATE} \
            --backend vllm \
            --port ${VLLM_PORT}
    "
    echo -e "\n${GREEN}[OK] Benchmark complete.${NC}"
# ==============================================================================
# MODE 4: Standalone GPU Monitor
# ==============================================================================
elif [ "$EXEC_MODE" == "4" ]; then
    if [ -n "$MONITOR_BIN" ]; then
        echo -e "${GREEN}Launching BMG GPU Monitor... (Ctrl+C to quit)${NC}"
        sudo "$MONITOR_BIN"
    else
        echo -e "${RED}Monitor binary unavailable. Ensure gcc is installed and rerun.${NC}"
    fi
else
    echo -e "${RED}Invalid mode.${NC}"
fi
