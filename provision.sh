#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# ==================== ADVANCED CONFIGURATION ====================

# Retry settings
MAX_RETRIES=5
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=60

# Intelligent timeout calculation
MIN_TIMEOUT=60
MAX_TIMEOUT=1800  # 30 minutes

# Concurrent downloads
MAX_CONCURRENT_DOWNLOADS=3

# Logging
PROVISION_LOG="/var/log/provisioning-detailed.log"
DOWNLOAD_SPEEDS_LOG="/tmp/download_speeds.log"

# Integrity checking
VERIFY_INTEGRITY=true
MIN_FILE_SIZE_BYTES=10485760  # 10MB minimum

# ==================== INSTALL ADVANCED TOOLS ====================

function install_download_tools() {
    log_info "Installing advanced download tools..."
    
    # Aria2 - multi-connection downloader
    if ! command -v aria2c &> /dev/null; then
        apt-get update -qq
        apt-get install -y aria2 curl jq bc > /dev/null 2>&1
        log_info "✓ Installed aria2"
    fi
    
    # Hugging Face CLI
    if ! command -v huggingface-cli &> /dev/null; then
        pip install -q huggingface-hub[cli] hf_transfer
        export HF_HUB_ENABLE_HF_TRANSFER=1
        log_info "✓ Installed huggingface-cli with hf_transfer"
    fi
    
    # Speed calculation tools
    touch "$DOWNLOAD_SPEEDS_LOG"
}

# ==================== LOGGING FUNCTIONS ====================

function log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" | tee -a "$PROVISION_LOG"
}

function log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$PROVISION_LOG" >&2
}

function log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG"
}

function log_speed() {
    echo "$*" >> "$DOWNLOAD_SPEEDS_LOG"
}

# ==================== NETWORK INTELLIGENCE ====================

function measure_download_speed() {
    local test_url="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/transformers/model_card/model_card_annotated.png"
    local test_file="/tmp/speed_test_$$"
    
    log_info "Measuring network speed..."
    
    local start_time=$(date +%s)
    if wget -q -O "$test_file" --timeout=30 "$test_url" 2>/dev/null; then
        local end_time=$(date +%s)
        local file_size=$(stat -c%s "$test_file" 2>/dev/null || stat -f%z "$test_file" 2>/dev/null)
        local duration=$((end_time - start_time))
        
        if [[ $duration -lt 1 ]]; then
            duration=1
        fi
        
        local speed_mbs=$((file_size / duration / 1048576))
        local speed_mbps=$((speed_mbs * 8))
        
        if [[ $speed_mbps -lt 10 ]]; then
            speed_mbps=10
        fi
        
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
    
    # Remove decimal if present
    file_size_gb=${file_size_gb%%.*}
    
    # Default to 1 if 0 or empty
    if [[ -z "$file_size_gb" || "$file_size_gb" -eq 0 ]]; then
        file_size_gb=1
    fi
    
    # Convert GB to Mb (1 GB = 8192 Mb)
    local file_size_mb=$((file_size_gb * 8192))
    
    # Calculate expected seconds with 50% buffer
    local expected_seconds=$((file_size_mb * 3 / network_speed_mbps / 2))
    
    # Clamp between MIN and MAX
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
        local size_gb=$((size / 1073741824))
        
        if [[ $size_gb -lt 1 ]]; then
            size_gb=1
        fi
        
        echo "$size_gb"
    else
        echo "5"
    fi
}

# ==================== INTEGRITY VERIFICATION ====================

function verify_file_integrity() {
    local filepath="$1"
    local expected_checksum="$2"
    
    if [[ ! -f "$filepath" ]]; then
        return 1
    fi
    
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
    if [[ $filesize -lt $MIN_FILE_SIZE_BYTES ]]; then
        log_warning "File too small: $(basename "$filepath") - ${filesize} bytes"
        return 1
    fi
    
    if [[ -n "$expected_checksum" && "$VERIFY_INTEGRITY" == "true" ]]; then
        log_info "Verifying checksum for $(basename "$filepath")..."
        local actual_checksum=$(sha256sum "$filepath" | awk '{print $1}')
        
        if [[ "$actual_checksum" == "$expected_checksum" ]]; then
            log_info "✓ Checksum verified"
            return 0
        else
            log_error "✗ Checksum mismatch!"
            return 1
        fi
    fi
    
    log_info "✓ File size check passed: $(basename "$filepath") - ${filesize} bytes"
    return 0
}

# ==================== SMART CLEANUP ====================

function cleanup_corrupted_files() {
    local dir="$1"
    
    log_info "Scanning for corrupted files in ${dir}..."
    
    local cleaned=0
    
    find "$dir" -name "*.tmp" -delete 2>/dev/null
    find "$dir" -name "*.aria2" -delete 2>/dev/null
    
    while IFS= read -r file; do
        local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
        if [[ $size -lt $MIN_FILE_SIZE_BYTES ]]; then
            log_warning "Removing corrupted file: $(basename "$file") (${size} bytes)"
            rm -f "$file"
            ((cleaned++))
        fi
    done < <(find "$dir" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" \) 2>/dev/null)
    
    if [[ $cleaned -gt 0 ]]; then
        log_info "Cleaned ${cleaned} corrupted file(s)"
    fi
}

# ==================== INTELLIGENT DOWNLOAD FUNCTIONS ====================

function download_with_aria2() {
    local url="$1"
    local output_dir="$2"
    local output_file="$3"
    local timeout="$4"
    local auth_token="$5"
    
    local aria2_opts=(
        "--max-connection-per-server=16"
        "--split=16"
        "--min-split-size=1M"
        "--max-tries=3"
        "--retry-wait=3"
        "--timeout=${timeout}"
        "--connect-timeout=30"
        "--max-file-not-found=3"
        "--console-log-level=error"
        "--summary-interval=0"
        "--dir=${output_dir}"
        "--out=${output_file}"
        "--allow-overwrite=true"
        "--auto-file-renaming=false"
        "--continue=true"
    )
    
    if [[ -n "$auth_token" ]]; then
        aria2_opts+=("--header=Authorization: Bearer ${auth_token}")
    fi
    
    aria2c "${aria2_opts[@]}" "$url" 2>&1 | grep -v "INFO" | tee -a "$PROVISION_LOG"
    return ${PIPESTATUS[0]}
}

function download_with_hf_cli() {
    local url="$1"
    local output_dir="$2"
    local output_file="$3"
    
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo_id="${BASH_REMATCH[1]}"
        local revision="${BASH_REMATCH[2]}"
        local filename="${BASH_REMATCH[3]}"
        
        log_info "Using HF CLI for: ${repo_id}/${filename}"
        
        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download \
            "$repo_id" \
            "$filename" \
            --revision "$revision" \
            --local-dir "$output_dir" \
            --local-dir-use-symlinks False \
            --resume-download 2>&1 | grep -v "FutureWarning" | grep -v "⚠️" | tee -a "$PROVISION_LOG"
        
        local exit_code=${PIPESTATUS[0]}
        
        local downloaded_file="${output_dir}/${filename}"
        
        if [[ $exit_code -eq 0 && -f "$downloaded_file" ]]; then
            if [[ "$downloaded_file" != "${output_dir}/${output_file}" ]]; then
                mv "$downloaded_file" "${output_dir}/${output_file}" 2>/dev/null || true
                find "$output_dir" -type d -empty -delete 2>/dev/null || true
            fi
            return 0
        fi
        
        return 1
    fi
    
    return 1
}

# ==================== MASTER DOWNLOAD FUNCTION ====================

function provisioning_download_with_retry() {
    local url="$1"
    local dir="$2"
    local filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"
    local temp_filepath="${filepath}.tmp"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Target: ${filename}"
    
    if [[ -f "$filepath" ]] && verify_file_integrity "$filepath"; then
        log_info "✓ Already exists: ${filename}"
        return 0
    fi
    
    rm -f "$filepath" "$temp_filepath" "${filepath}.aria2"
    
    local auth_token=""
    if [[ -n "$HF_TOKEN" && "$url" =~ huggingface\.co ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    
    if [[ ! -f /tmp/network_speed_cached ]]; then
        local network_speed=$(measure_download_speed)
        echo "$network_speed" > /tmp/network_speed_cached
        log_info "Network: ${network_speed} Mbps"
    else
        local network_speed=$(cat /tmp/network_speed_cached)
    fi
    
    local estimated_size=$(estimate_file_size "$url")
    local intelligent_timeout=$(calculate_intelligent_timeout "$estimated_size" "$network_speed")
    log_info "Size: ~${estimated_size}GB | Timeout: ${intelligent_timeout}s"
    
    local attempt=1
    local retry_delay=$BASE_RETRY_DELAY
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt ${attempt}/${MAX_RETRIES}"
        
        local download_start=$(date +%s)
        local success=false
        
        if [[ "$url" =~ huggingface\.co ]]; then
            if download_with_hf_cli "$url" "$dir" "$filename"; then
                success=true
            fi
        fi
        
        if [[ "$success" == "false" ]]; then
            log_info "Fallback: aria2c"
            if download_with_aria2 "$url" "$dir" "$filename" "$intelligent_timeout" "$auth_token"; then
                success=true
            fi
        fi
        
        local download_end=$(date +%s)
        local download_duration=$((download_end - download_start))
        
        if [[ "$success" == "true" ]] && verify_file_integrity "$filepath"; then
            local filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
            local size_mb=$((filesize / 1048576))
            
            log_info "✅ SUCCESS: ${filename} (${size_mb}MB in ${download_duration}s)"
            
            rm -f "$temp_filepath" "${filepath}.aria2"
            
            return 0
        fi
        
        log_warning "Attempt ${attempt} failed"
        rm -f "$filepath" "$temp_filepath" "${filepath}.aria2"
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Retry in ${retry_delay}s..."
            sleep $retry_delay
            
            retry_delay=$((retry_delay * 2))
            if [[ $retry_delay -gt $MAX_RETRY_DELAY ]]; then
                retry_delay=$MAX_RETRY_DELAY
            fi
        fi
        
        ((attempt++))
    done
    
    log_error "❌ FAILED: ${filename}"
    return 1
}

# ==================== PYTHON HTTP SERVER SETUP ====================

function setup_output_http_server() {
    log_info "Setting up HTTP server..."
    
    mkdir -p ${COMFYUI_DIR}/output
    
    cat > /etc/supervisor/conf.d/comfyui-output-server.conf << 'EOF'
[program:comfyui-output-server]
command=/usr/bin/python3 -m http.server 8081 --bind 0.0.0.0
directory=/workspace/ComfyUI/output
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/comfyui-output-server.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
priority=999
EOF

    supervisorctl reread > /dev/null 2>&1
    supervisorctl update > /dev/null 2>&1
    supervisorctl start comfyui-output-server > /dev/null 2>&1
    
    sleep 2
    
    if supervisorctl status comfyui-output-server 2>/dev/null | grep -q RUNNING; then
        log_info "✅ HTTP server: port 8081"
    fi
}

# ==================== PACKAGE DEFINITIONS ====================

APT_PACKAGES=(
    "ffmpeg"
    # ffmpeg dev headers required so av==11.0.0 can build from source when no
    # pre-built manylinux wheel matches this environment's Python/platform tags.
    "libavformat-dev"
    "libavcodec-dev"
    "libavdevice-dev"
    "libavutil-dev"
    "libavfilter-dev"
    "libswscale-dev"
    "libswresample-dev"
    "libsm6"
    "libgl1"
    "libglib2.0-0"
    "pkg-config"
)

# NOTE - protobuf: intentionally NOT pinned here.
# The base vast.ai image ships protobuf 6.x. The Foley node's install.py detects
# the descript-audio-codec conflict and skips gracefully with a warning — it does
# NOT break provisioning. Pinning protobuf would risk downgrading it and breaking
# transformers or other already-installed packages in the base image.
#
# NOTE - whisperx: intentionally NOT installed via pip.
# AIFSH/ComfyUI-WhisperX bundles a local whisperx/ package inside the node repo.
# Installing a separate pip whisperx on top creates a shadowing conflict where the
# wrong copy is imported. The node's own requirements.txt (run by provisioning_get_nodes)
# covers all runtime dependencies whisperx needs (faster-whisper, pyannote, etc.).
PIP_PACKAGES=(
    "transformers==4.57.3"
    "timm"
    # openai-whisper is used by provisioning_setup_whisperx to pre-download model weights
    "openai-whisper"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/flybirdxx/ComfyUI-Qwen-TTS"
    "https://github.com/AIFSH/ComfyUI-WhisperX"
    "https://github.com/if-ai/ComfyUI_HunyuanVideoFoley"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
)

CHECKPOINT_MODELS=()
UNET_MODELS=()

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

ESRGAN_MODELS=()
CONTROLNET_MODELS=()
LATENT_UPSCALE_MODELS=()
WORKFLOWS=()

# ==================== POST-INSTALL FOR SPECIAL NODES ====================

function provisioning_post_install_foley() {
    log_info "Running HunyuanVideoFoley post-install..."
    
    local foley_path="${COMFYUI_DIR}/custom_nodes/ComfyUI_HunyuanVideoFoley"
    
    if [[ -d "$foley_path" ]]; then
        cd "$foley_path"
        
        log_info "Installing Foley dependencies..."

        # STEP 1 - Install the node's own requirements.txt first.
        if [[ -f "requirements.txt" ]]; then
            pip install --no-cache-dir -r requirements.txt 2>&1 | tee -a "$PROVISION_LOG" \
                || log_warning "Foley requirements.txt had issues (may be normal)"
        fi

        # STEP 2 - Pre-install a Python 3.12-compatible spacy BEFORE audiocraft.
        #
        # Problem: audiocraft 1.3.0 requires spacy>=3.6.1. When pip resolves this
        # on Python 3.12 it may back-track to spacy 3.5.x, which requires
        # thinc<8.2.0. thinc 8.1.x has no pre-built cp312 wheel so pip compiles
        # it from source. The Cython-generated code references _PyCFrame->use_tracing
        # which was removed in Python 3.12 → hard compile error, spacy never installs,
        # audiocraft fails entirely.
        #
        # Fix: pre-install spacy>=3.7.4 which ships a cp312-cp312-manylinux wheel
        # (no compilation). It pulls in thinc>=8.3.0,<8.4.0 which also has cp312
        # wheels. Pip then sees spacy already satisfied and never touches old thinc.
        log_info "Pre-installing Python 3.12-compatible spacy (prevents thinc build failure)..."
        pip install --no-cache-dir "spacy>=3.7.4" 2>&1 | tee -a "$PROVISION_LOG" \
            || log_warning "spacy pre-install had issues"

        # STEP 3 - Install audiocraft.
        # With spacy already satisfied at >=3.7.4, the resolver won't pull in
        # old thinc. With ffmpeg dev headers in APT_PACKAGES, av==11.0.0 can
        # build from source if the manylinux wheel is unavailable here.
        log_info "Installing audiocraft..."
        pip install --no-cache-dir audiocraft 2>&1 | tee -a "$PROVISION_LOG" \
            || log_warning "audiocraft install had issues"

        # STEP 4 - Run the node's install.py (creates dirs, validates deps).
        if [[ -f "install.py" ]]; then
            python install.py 2>&1 | tee -a "$PROVISION_LOG" \
                || log_warning "Foley install.py had issues (may be normal)"
        fi
        
        cd "$COMFYUI_DIR"
        log_info "✓ HunyuanVideoFoley post-install complete"
    else
        log_warning "Foley path not found, skipping post-install"
    fi
}

function provisioning_setup_whisperx() {
    log_info "Setting up WhisperX models..."
    
    local whisperx_path="${COMFYUI_DIR}/custom_nodes/ComfyUI-WhisperX"
    
    if [[ ! -d "$whisperx_path" ]]; then
        log_warning "WhisperX path not found, skipping"
        return
    fi
    
    # Create cache directories
    mkdir -p /workspace/.cache/huggingface
    mkdir -p /workspace/.cache/whisper
    mkdir -p /workspace/.cache/torch/hub/checkpoints
    
    # Set environment variables for cache
    export HF_HOME="/workspace/.cache/huggingface"
    export TRANSFORMERS_CACHE="/workspace/.cache/huggingface"
    export TORCH_HOME="/workspace/.cache/torch"
    
    # Download Whisper models (large-v3)
    log_info "Downloading Whisper large-v3..."
    python3 << 'PYTHON_SCRIPT'
import os
import sys

os.environ['HF_HOME'] = '/workspace/.cache/huggingface'
os.environ['TORCH_HOME'] = '/workspace/.cache/torch'

try:
    import whisper
    print("Loading Whisper large-v3...")
    model = whisper.load_model("large-v3", download_root="/workspace/.cache/whisper")
    print("✓ Whisper large-v3 downloaded")
except Exception as e:
    print(f"✗ Whisper download failed: {e}")
    sys.exit(0)  # Don't fail provisioning
PYTHON_SCRIPT
    
    # Try to download pyannote models (will fail if not accepted, that's OK)
    log_info "Attempting to download pyannote models (requires HF token with access)..."
    python3 << 'PYTHON_SCRIPT'
import os
import sys

hf_token = os.environ.get('HF_TOKEN', '')

if not hf_token:
    print("⚠ HF_TOKEN not set, skipping pyannote download")
    print("  Models will auto-download on first use if token is set at runtime")
    sys.exit(0)

os.environ['HF_HOME'] = '/workspace/.cache/huggingface'

try:
    from pyannote.audio import Model
    
    print("Downloading pyannote/segmentation-3.0...")
    model = Model.from_pretrained(
        "pyannote/segmentation-3.0",
        token=hf_token
    )
    print("✓ Segmentation model downloaded")
    
    print("Downloading pyannote/speaker-diarization-3.1...")
    from pyannote.audio import Pipeline
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=hf_token
    )
    print("✓ Diarization model downloaded")
    
except Exception as e:
    print(f"⚠ Pyannote download failed: {e}")
    print("  This is expected if you haven't accepted the license at:")
    print("  - https://huggingface.co/pyannote/segmentation-3.0")
    print("  - https://huggingface.co/pyannote/speaker-diarization-3.1")
    print("  Models will auto-download on first use after accepting licenses")
    sys.exit(0)  # Don't fail provisioning
PYTHON_SCRIPT
    
    log_info "✓ WhisperX setup complete"
}

# ==================== MAIN PROVISIONING ====================

function provisioning_start() {
    log_info "=========================================="
    log_info "  PROVISIONING START"
    log_info "=========================================="
    
    install_download_tools
    setup_output_http_server
    provisioning_get_apt_packages   # ffmpeg runtime + dev headers installed first
    provisioning_get_nodes          # clone nodes + install their requirements.txt
    provisioning_post_install_foley # spacy>=3.7.4 → audiocraft → install.py
    provisioning_get_pip_packages   # transformers, timm, openai-whisper
    provisioning_setup_whisperx     # pre-download whisper large-v3 weights
    
    cleanup_corrupted_files "${COMFYUI_DIR}/models"
    
    provisioning_get_files "${COMFYUI_DIR}/models/loras" "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"
    
    log_info "=========================================="
    log_info "  PROVISIONING COMPLETE"
    log_info "=========================================="
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing APT packages..."
        apt-get update -qq && apt-get install -y ${APT_PACKAGES[@]} > /dev/null 2>&1
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing PIP packages..."
        pip install --no-cache-dir ${PIP_PACKAGES[@]} 2>&1 | tee -a "$PROVISION_LOG"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        
        if [[ -d $path ]]; then
            log_info "Node exists: ${dir}"
        else
            log_info "Cloning: ${dir}"
            git clone "${repo}" "${path}" --recursive --quiet 2>&1 | tee -a "$PROVISION_LOG"
            
            if [[ -f "${path}/requirements.txt" ]]; then
                pip install --no-cache-dir -r "${path}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 0; fi
    
    local dir="$1"
    mkdir -p "$dir"
    shift
    local arr=("$@")
    
    if [[ ${#arr[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Target dir: ${dir} (${#arr[@]} files)"
    
    for url in "${arr[@]}"; do
        provisioning_download_with_retry "$url" "$dir"
    done
}

# Start provisioning
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
