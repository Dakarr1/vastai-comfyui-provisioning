#!/bin/bash

# Aktywacja środowiska
source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# ==================== ADVANCED CONFIGURATION ====================

MAX_RETRIES=5
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=60

# Aria2 ma limit timeoutu do 600s (10 min)
MIN_TIMEOUT=60
MAX_TIMEOUT=600 

MAX_CONCURRENT_DOWNLOADS=3
PROVISION_LOG="/var/log/provisioning-detailed.log"
DOWNLOAD_SPEEDS_LOG="/tmp/download_speeds.log"

VERIFY_INTEGRITY=true
MIN_FILE_SIZE_BYTES=10485760  # 10MB

# ==================== LOGGING FUNCTIONS (FIXED) ====================
# Przekierowanie na >&2 jest KLUCZOWE, aby funkcje zwracające wartości (stdout) 
# nie zawierały tekstu logów, co psuło matematykę w Twoim poprzednim skrypcie.

function log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$PROVISION_LOG" >&2
}

function log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$PROVISION_LOG" >&2
}

function log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG" >&2
}

# ==================== INSTALL ADVANCED TOOLS ====================

function install_download_tools() {
    log_info "Installing advanced download tools..."
    
    apt-get update -qq
    # Dodajemy build-essential dla kompilacji kiwisolver/av
    apt-get install -y aria2 curl jq bc build-essential pkg-config > /dev/null 2>&1
    
    # Naprawa pip i instalacja narzędzi HF
    pip install --upgrade pip setuptools wheel
    pip install -q huggingface-hub[cli] hf_transfer
    export HF_HUB_ENABLE_HF_TRANSFER=1
}

# ==================== NETWORK INTELLIGENCE ====================

function measure_download_speed() {
    local test_url="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/transformers/model_card/model_card_annotated.png"
    local test_file="/tmp/speed_test_$$"
    
    local start_time=$(date +%s)
    if wget -q -O "$test_file" --timeout=30 "$test_url" 2>/dev/null; then
        local end_time=$(date +%s)
        local file_size=$(stat -c%s "$test_file" 2>/dev/null || echo 0)
        local duration=$((end_time - start_time))
        [[ $duration -lt 1 ]] && duration=1
        
        local speed_mbps=$(( (file_size * 8) / (duration * 1048576) ))
        [[ $speed_mbps -lt 10 ]] && speed_mbps=10
        rm -f "$test_file"
        echo "$speed_mbps"
    else
        echo "50"
    fi
}

function calculate_intelligent_timeout() {
    local file_size_gb="$1"
    local network_speed_mbps="$2"
    
    file_size_gb=${file_size_gb%%.*}
    [[ -z "$file_size_gb" || "$file_size_gb" -eq 0 ]] && file_size_gb=1
    
    local file_size_mb=$((file_size_gb * 8192))
    local expected_seconds=$(( (file_size_mb * 2) / network_speed_mbps ))
    
    if [[ $expected_seconds -lt $MIN_TIMEOUT ]]; then
        echo "$MIN_TIMEOUT"
    elif [[ $expected_seconds -gt $MAX_TIMEOUT ]]; then
        echo "$MAX_TIMEOUT"
    else
        echo "$expected_seconds"
    fi
}

function estimate_file_size() {
    local url="$1"
    local size=$(curl -sI "$url" 2>/dev/null | grep -i content-length | awk '{print $2}' | tr -d '\r')
    if [[ -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
        echo "$((size / 1073741824 + 1))"
    else
        echo "5"
    fi
}

# ==================== INTEGRITY & CLEANUP ====================

function verify_file_integrity() {
    local filepath="$1"
    [[ ! -f "$filepath" ]] && return 1
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    [[ $filesize -lt $MIN_FILE_SIZE_BYTES ]] && return 1
    return 0
}

function cleanup_corrupted_files() {
    local dir="$1"
    log_info "Cleaning corrupted files in ${dir}..."
    find "$dir" -name "*.tmp" -delete 2>/dev/null
    find "$dir" -name "*.aria2" -delete 2>/dev/null
}

# ==================== DOWNLOAD ENGINES ====================

function download_with_aria2() {
    local url="$1" local dir="$2" local out="$3" local timeout="$4" local auth="$5"
    local aria2_opts=(
        "--max-connection-per-server=16" "--split=16" "--min-split-size=1M"
        "--timeout=${timeout}" "--dir=${dir}" "--out=${out}" "--continue=true"
        "--console-log-level=error" "--summary-interval=0"
    )
    [[ -n "$auth" ]] && aria2_opts+=("--header=Authorization: Bearer ${auth}")
    aria2c "${aria2_opts[@]}" "$url"
}

function download_with_hf_cli() {
    local url="$1" local dir="$2" local out="$3"
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}" local rev="${BASH_REMATCH[2]}" local file="${BASH_REMATCH[3]}"
        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download "$repo" "$file" --revision "$rev" --local-dir "$dir" --local-dir-use-symlinks False
        [[ -f "${dir}/${file}" && "$file" != "$out" ]] && mv "${dir}/${file}" "${dir}/${out}"
        return 0
    fi
    return 1
}

function provisioning_download_with_retry() {
    local url="$1" local dir="$2"
    local filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"

    if verify_file_integrity "$filepath"; then
        log_info "✓ Exists: ${filename}"
        return 0
    fi

    local net_speed=$(cat /tmp/network_speed_cached 2>/dev/null || measure_download_speed)
    local size_est=$(estimate_file_size "$url")
    local timeout=$(calculate_intelligent_timeout "$size_est" "$net_speed")

    for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
        log_info "Download ${filename} (Attempt $attempt)..."
        if [[ "$url" =~ huggingface\.co ]] && download_with_hf_cli "$url" "$dir" "$filename"; then
            verify_file_integrity "$filepath" && return 0
        fi
        download_with_aria2 "$url" "$dir" "$filename" "$timeout" && verify_file_integrity "$filepath" && return 0
        sleep $BASE_RETRY_DELAY
    done
    return 1
}

# ==================== PACKAGE DEFINITIONS ====================

# KLUCZOWE: Dodane biblioteki -dev dla kompilacji PyAV (audiocraft)
APT_PACKAGES=(
    "ffmpeg" "libavcodec-dev" "libavformat-dev" "libavutil-dev" 
    "libswscale-dev" "libavdevice-dev" "libavfilter-dev" "libswresample-dev"
    "libsm6" "libgl1" "libglib2.0-0" "pkg-config"
)

# KLUCZOWE: Pinowanie protobuf i dodanie zależności dla Foley/WhisperX
PIP_PACKAGES=(
    "protobuf==3.20.3"
    "transformers>=4.48.0"
    "timm"
    "einops"
    "vector-quantize-pytorch"
    "audiocraft"
    "openai-whisper"
    "git+https://github.com/m-bain/whisperx.git"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/flybirdxx/ComfyUI-Qwen-TTS"
    "https://github.com/AIFSH/ComfyUI-WhisperX"
    "https://github.com/if-ai/ComfyUI_HunyuanVideoFoley"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
)

# Modele (Lista bez zmian, skrócona dla przejrzystości odpowiedzi)
LORA_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors")
VAE_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors")
DIFFUSION_MODELS=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors")

# ==================== INSTALLATION LOGIC ====================

function provisioning_start() {
    install_download_tools
    measure_download_speed > /tmp/network_speed_cached
    
    log_info "Installing APT packages..."
    apt-get install -y ${APT_PACKAGES[@]} > /dev/null 2>&1

    log_info "Installing PIP packages..."
    # Najpierw kluczowe zależności, potem reszta
    pip install --no-cache-dir protobuf==3.20.3 setuptools wheel
    pip install --no-cache-dir ${PIP_PACKAGES[@]}

    log_info "Cloning Nodes..."
    for repo in "${NODES[@]}"; do
        local name=$(basename $repo)
        local path="${COMFYUI_DIR}/custom_nodes/${name}"
        if [[ ! -d "$path" ]]; then
            git clone "$repo" "$path" --recursive --quiet
            [[ -f "${path}/requirements.txt" ]] && pip install -r "${path}/requirements.txt"
        fi
    done

    # Specjalny fix dla Foley (często gubi audiocraft)
    pip install audiocraft timm

    log_info "Downloading models..."
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    
    log_info "DONE!"
}

function provisioning_get_files() {
    local dir="$1" shift; local arr=("$@")
    mkdir -p "$dir"
    for url in "${arr[@]}"; do provisioning_download_with_retry "$url" "$dir"; done
}

provisioning_start
