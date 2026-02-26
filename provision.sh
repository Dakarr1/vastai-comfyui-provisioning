#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# ==================== ADVANCED CONFIGURATION (YOUR ORIGINAL) ====================
MAX_RETRIES=5
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=60
MIN_TIMEOUT=60
MAX_TIMEOUT=1800
MAX_CONCURRENT_DOWNLOADS=3
PROVISION_LOG="/var/log/provisioning-detailed.log"
DOWNLOAD_SPEEDS_LOG="/tmp/download_speeds.log"
VERIFY_INTEGRITY=true
MIN_FILE_SIZE_BYTES=10485760

# ==================== LOGGING FUNCTIONS (FIXED FOR MATH) ====================
# Dodano >&2 aby logi nie zakłócały przechwytywania wartości numerycznych przez Bash
function log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$PROVISION_LOG" >&2; }
function log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$PROVISION_LOG" >&2; }
function log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG" >&2; }
function log_speed() { echo "$*" >> "$DOWNLOAD_SPEEDS_LOG"; }

# ==================== PYTHON 3.12 COMPATIBILITY FIX ====================
function fix_python_env() {
    log_info "Fixing Python 3.12 build environment for thinc/kiwisolver..."
    pip install --upgrade pip setuptools wheel Cython > /dev/null 2>&1
    # Wymuszamy thinc który wspiera 3.12
    pip install --no-cache-dir "thinc>=8.2.0" "pydantic>=2.0" > /dev/null 2>&1
}

# ==================== NETWORK INTELLIGENCE (YOUR ORIGINAL) ====================
function measure_download_speed() {
    local test_url="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/transformers/model_card/model_card_annotated.png"
    local test_file="/tmp/speed_test_$$"
    log_info "Measuring network speed..."
    local start_time=$(date +%s)
    if wget -q -O "$test_file" --timeout=30 "$test_url" 2>/dev/null; then
        local end_time=$(date +%s)
        local file_size=$(stat -c%s "$test_file" 2>/dev/null || stat -f%z "$test_file" 2>/dev/null)
        local duration=$((end_time - start_time))
        [[ $duration -lt 1 ]] && duration=1
        local speed_mbs=$((file_size / duration / 1048576))
        local speed_mbps=$((speed_mbs * 8))
        [[ $speed_mbps -lt 10 ]] && speed_mbps=10
        rm -f "$test_file"
        echo "$speed_mbps"
    else
        rm -f "$test_file"
        echo "50"
    fi
}

function calculate_intelligent_timeout() {
    local file_size_gb="$1"
    local network_speed_mbps="$2"
    file_size_gb=${file_size_gb%%.*}
    [[ -z "$file_size_gb" || "$file_size_gb" -eq 0 ]] && file_size_gb=1
    local file_size_mb=$((file_size_gb * 8192))
    local expected_seconds=$((file_size_mb * 3 / network_speed_mbps / 2))
    if [[ $expected_seconds -lt $MIN_TIMEOUT ]]; then echo "$MIN_TIMEOUT"
    elif [[ $expected_seconds -gt $MAX_TIMEOUT ]]; then echo "$MAX_TIMEOUT"
    else echo "$expected_seconds"; fi
}

function estimate_file_size() {
    local url="$1"
    local size=$(curl -sI "$url" 2>/dev/null | grep -i content-length | awk '{print $2}' | tr -d '\r')
    if [[ -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
        local size_gb=$((size / 1073741824))
        [[ $size_gb -lt 1 ]] && size_gb=1
        echo "$size_gb"
    else echo "5"; fi
}

# ==================== DOWNLOAD ENGINES (HF-CLI + ARIA2) ====================
function install_download_tools() {
    log_info "Installing advanced download tools..."
    apt-get update -qq && apt-get install -y aria2 curl jq bc > /dev/null 2>&1
    pip install -q huggingface-hub[cli] hf_transfer
    export HF_HUB_ENABLE_HF_TRANSFER=1
    touch "$DOWNLOAD_SPEEDS_LOG"
}

function download_with_hf_cli() {
    local url="$1" local output_dir="$2" local output_file="$3"
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo_id="${BASH_REMATCH[1]}"
        local revision="${BASH_REMATCH[2]}"
        local filename="${BASH_REMATCH[3]}"
        log_info "Using HF CLI for: ${repo_id}/${filename}"
        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download "$repo_id" "$filename" --revision "$revision" --local-dir "$output_dir" --local-dir-use-symlinks False --resume-download > /dev/null 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 0 && -f "${output_dir}/${filename}" ]]; then
            [[ "$filename" != "$output_file" ]] && mv "${output_dir}/${filename}" "${output_dir}/${output_file}" 2>/dev/null
            return 0
        fi
    fi
    return 1
}

function download_with_aria2() {
    local url="$1" local output_dir="$2" local output_file="$3" local timeout="$4" local auth_token="$5"
    local aria2_opts=("--max-connection-per-server=16" "--split=16" "--min-split-size=1M" "--timeout=${timeout}" "--dir=${output_dir}" "--out=${output_file}" "--continue=true" "--console-log-level=error")
    [[ -n "$auth_token" ]] && aria2_opts+=("--header=Authorization: Bearer ${auth_token}")
    aria2c "${aria2_opts[@]}" "$url"
}

function provisioning_download_with_retry() {
    local url="$1" local dir="$2"
    local filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"
    
    [[ -f "$filepath" ]] && verify_file_integrity "$filepath" && return 0
    
    local network_speed=$(cat /tmp/network_speed_cached 2>/dev/null || measure_download_speed)
    echo "$network_speed" > /tmp/network_speed_cached
    
    local estimated_size=$(estimate_file_size "$url")
    local timeout=$(calculate_intelligent_timeout "$estimated_size" "$network_speed")
    
    local attempt=1
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ "$url" =~ huggingface\.co ]] && download_with_hf_cli "$url" "$dir" "$filename"; then
            verify_file_integrity "$filepath" && return 0
        fi
        if download_with_aria2 "$url" "$dir" "$filename" "$timeout"; then
            verify_file_integrity "$filepath" && return 0
        fi
        ((attempt++))
        sleep $BASE_RETRY_DELAY
    done
    return 1
}

# ==================== UTILS (INTEGRITY, CLEANUP, SERVER) ====================
function verify_file_integrity() {
    local filepath="$1"
    [[ ! -f "$filepath" ]] && return 1
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
    [[ $filesize -lt $MIN_FILE_SIZE_BYTES ]] && return 1
    return 0
}

function cleanup_corrupted_files() {
    find "$1" -name "*.tmp" -delete 2>/dev/null
    find "$1" -name "*.aria2" -delete 2>/dev/null
}

function setup_output_http_server() {
    mkdir -p ${COMFYUI_DIR}/output
    cat > /etc/supervisor/conf.d/comfyui-output-server.conf << 'EOF'
[program:comfyui-output-server]
command=/usr/bin/python3 -m http.server 8081 --bind 0.0.0.0
directory=/workspace/ComfyUI/output
autostart=true
autorestart=true
EOF
    supervisorctl update > /dev/null 2>&1
}

# ==================== PACKAGE DEFINITIONS ====================
APT_PACKAGES=("ffmpeg" "libsm6" "libgl1" "libglib2.0-0" "pkg-config" "libavcodec-dev" "libavformat-dev" "libavutil-dev" "build-essential")
PIP_PACKAGES=("protobuf==3.20.3" "transformers>=4.48.0" "timm" "openai-whisper" "audiocraft" "git+https://github.com/m-bain/whisperx.git@main")

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/flybirdxx/ComfyUI-Qwen-TTS"
    "https://github.com/AIFSH/ComfyUI-WhisperX"
    "https://github.com/if-ai/ComfyUI_HunyuanVideoFoley"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/Kijai/ComfyUI-WanVideo"
)

LORA_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
)
VAE_MODELS=(
    "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/vae/ae.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
)
TEXT_ENCODER_MODELS=(
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
)
DIFFUSION_MODELS=(
    "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/z_image_bf16.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"
)

# ==================== POST-INSTALLS ====================
function provisioning_post_install_foley() {
    local foley_path="${COMFYUI_DIR}/custom_nodes/ComfyUI_HunyuanVideoFoley"
    if [[ -d "$foley_path" ]]; then
        pip install --no-cache-dir timm audiocraft
        [[ -f "${foley_path}/install.py" ]] && python "${foley_path}/install.py"
    fi
}

function provisioning_setup_whisperx() {
    mkdir -p /workspace/.cache/whisper
    python3 -c "import whisper; whisper.load_model('large-v3', download_root='/workspace/.cache/whisper')" 2>/dev/null || true
}

# ==================== MAIN PROVISIONING START ====================
function provisioning_start() {
    log_info "=== PROVISIONING START ==="
    
    fix_python_env
    install_download_tools
    setup_output_http_server
    
    log_info "Installing APT packages..."
    apt-get update -qq && apt-get install -y ${APT_PACKAGES[@]} > /dev/null 2>&1
    
    log_info "Installing Custom Nodes..."
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        if [[ ! -d $path ]]; then
            git clone "${repo}" "${path}" --recursive --quiet
            [[ -f "${path}/requirements.txt" ]] && pip install --no-cache-dir -r "${path}/requirements.txt"
        fi
    done
    
    provisioning_post_install_foley
    
    log_info "Installing PIP packages..."
    pip install --no-cache-dir ${PIP_PACKAGES[@]}
    
    provisioning_setup_whisperx
    cleanup_corrupted_files "${COMFYUI_DIR}/models"
    
    log_info "Downloading models..."
    for url in "${LORA_MODELS[@]}"; do provisioning_download_with_retry "$url" "${COMFYUI_DIR}/models/loras"; done
    for url in "${VAE_MODELS[@]}"; do provisioning_download_with_retry "$url" "${COMFYUI_DIR}/models/vae"; done
    for url in "${TEXT_ENCODER_MODELS[@]}"; do provisioning_download_with_retry "$url" "${COMFYUI_DIR}/models/text_encoders"; done
    for url in "${DIFFUSION_MODELS[@]}"; do provisioning_download_with_retry "$url" "${COMFYUI_DIR}/models/diffusion_models"; done
    
    log_info "=== PROVISIONING COMPLETE ==="
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
