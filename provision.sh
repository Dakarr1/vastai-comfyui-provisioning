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
    # Use a larger test file (~1MB) so date +%s second-level precision is meaningful.
    # The old tiny PNG (~100KB) always completed in <1s → duration forced to 1s
    # → speed_mbs always 0 → clamped to 10 Mbps regardless of real speed.
    local test_url="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/transformers/model_card/model_card_annotated.png"
    local test_file="/tmp/speed_test_$$"

    log_info "Measuring network speed..."

    # Use curl with millisecond timing instead of date +%s for accuracy
    local speed_kbps
    speed_kbps=$(curl -o "$test_file" -w "%{speed_download}" -s --max-time 30 "$test_url" 2>/dev/null)

    rm -f "$test_file"

    if [[ -n "$speed_kbps" && "$speed_kbps" != "0.000000" && "$speed_kbps" != "0" ]]; then
        # curl reports speed in bytes/sec; convert to Mbps
        # speed_mbps = (bytes/sec * 8) / 1000000  → integer: speed_kbps * 8 / 1000000
        # Use awk to avoid floating point issues in bash
        local speed_mbps
        speed_mbps=$(awk "BEGIN { v=int($speed_kbps * 8 / 1000000); print (v<10)?10:v }")
        log_info "Measured speed: ${speed_mbps} Mbps"
        echo "$speed_mbps"
    else
        log_info "Speed test failed, defaulting to 50 Mbps"
        echo "50"
    fi
}

function calculate_intelligent_timeout() {
    local file_size_gb="$1"
    local network_speed_mbps="$2"
    
    # Strip any decimal portion
    file_size_gb=${file_size_gb%%.*}
    
    # Guard against empty/zero
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
    
    # Try to get Content-Length from HEAD request
    local size=$(curl -sI "$url" 2>/dev/null | grep -i content-length | awk '{print $2}' | tr -d '\r')
    
    if [[ -n "$size" && "$size" =~ ^[0-9]+$ ]]; then
        # Convert to GB (integer math)
        local size_gb=$((size / 1073741824))
        
        # Minimum 1 GB
        if [[ $size_gb -lt 1 ]]; then
            size_gb=1
        fi
        
        echo "$size_gb"
    else
        # Default estimate: 5GB for safetensors
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
    
    # Check minimum file size
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
    if [[ $filesize -lt $MIN_FILE_SIZE_BYTES ]]; then
        log_warning "File too small: $(basename "$filepath") - ${filesize} bytes"
        return 1
    fi
    
    # If we have expected checksum, verify
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
    
    # Fallback: file exists and size is reasonable
    log_info "✓ File size check passed: $(basename "$filepath") - ${filesize} bytes"
    return 0
}

# ==================== SMART CLEANUP ====================

function cleanup_corrupted_files() {
    local dir="$1"
    
    log_info "Scanning for corrupted files in ${dir}..."
    
    local cleaned=0
    
    # Remove temp files
    find "$dir" -name "*.tmp" -delete 2>/dev/null
    find "$dir" -name "*.aria2" -delete 2>/dev/null
    
    # Remove files smaller than MIN_FILE_SIZE
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

# ==================== INTELLIGENT DOWNLOAD FUNCTION ====================

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
    
    # Extract HF repo and file path
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo_id="${BASH_REMATCH[1]}"
        local revision="${BASH_REMATCH[2]}"
        local filename="${BASH_REMATCH[3]}"
        
        log_info "Using HF CLI for: ${repo_id}/${filename}"
        
        # HF CLI with hf_transfer (Rust-based, super fast)
        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download \
            "$repo_id" \
            "$filename" \
            --revision "$revision" \
            --local-dir "$output_dir" \
            --local-dir-use-symlinks False \
            --resume-download 2>&1 | grep -v "FutureWarning" | grep -v "⚠️" | tee -a "$PROVISION_LOG"
        
        local exit_code=${PIPESTATUS[0]}
        
        # HF CLI downloads to original path structure
        local downloaded_file="${output_dir}/${filename}"
        
        if [[ $exit_code -eq 0 && -f "$downloaded_file" ]]; then
            # Move to flat structure if needed
            if [[ "$downloaded_file" != "${output_dir}/${output_file}" ]]; then
                mv "$downloaded_file" "${output_dir}/${output_file}" 2>/dev/null || true
                
                # Clean up empty directories
                find "$output_dir" -type d -empty -delete 2>/dev/null || true
            fi
            return 0
        fi
        
        return 1
    fi
    
    return 1
}

# ==================== MASTER DOWNLOAD FUNCTION WITH RETRY ====================

function provisioning_download_with_retry() {
    local url="$1"
    local dir="$2"
    local filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"
    local temp_filepath="${filepath}.tmp"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Target: ${filename}"
    
    # Check if already exists and valid
    if [[ -f "$filepath" ]] && verify_file_integrity "$filepath"; then
        log_info "✓ Already exists: ${filename}"
        return 0
    fi
    
    # Clean up any existing corrupted versions
    rm -f "$filepath" "$temp_filepath" "${filepath}.aria2"
    
    # Determine auth token
    local auth_token=""
    if [[ -n "$HF_TOKEN" && "$url" =~ huggingface\.co ]]; then
        auth_token="$HF_TOKEN"
    elif [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    
    # Measure network speed (cached after first measurement)
    if [[ ! -f /tmp/network_speed_cached ]]; then
        local network_speed=$(measure_download_speed)
        echo "$network_speed" > /tmp/network_speed_cached
        log_info "Network: ${network_speed} Mbps"
    else
        local network_speed=$(cat /tmp/network_speed_cached)
    fi
    
    # Estimate file size and calculate intelligent timeout
    local estimated_size=$(estimate_file_size "$url")
    local intelligent_timeout=$(calculate_intelligent_timeout "$estimated_size" "$network_speed")
    log_info "Size: ~${estimated_size}GB | Timeout: ${intelligent_timeout}s"
    
    # Retry loop with exponential backoff
    local attempt=1
    local retry_delay=$BASE_RETRY_DELAY
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt ${attempt}/${MAX_RETRIES}"
        
        local download_start=$(date +%s)
        local success=false
        
        # Try HF CLI first if HuggingFace URL
        if [[ "$url" =~ huggingface\.co ]]; then
            if download_with_hf_cli "$url" "$dir" "$filename"; then
                success=true
            fi
        fi
        
        # Fallback to aria2
        if [[ "$success" == "false" ]]; then
            log_info "Fallback: aria2c"
            if download_with_aria2 "$url" "$dir" "$filename" "$intelligent_timeout" "$auth_token"; then
                success=true
            fi
        fi
        
        local download_end=$(date +%s)
        local download_duration=$((download_end - download_start))
        
        # Verify download
        if [[ "$success" == "true" ]] && verify_file_integrity "$filepath"; then
            local filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
            local size_mb=$((filesize / 1048576))
            
            log_info "✅ SUCCESS: ${filename} (${size_mb}MB in ${download_duration}s)"
            
            # Clean up temp files
            rm -f "$temp_filepath" "${filepath}.aria2"
            
            return 0
        fi
        
        # Download failed or corrupted
        log_warning "Attempt ${attempt} failed"
        rm -f "$filepath" "$temp_filepath" "${filepath}.aria2"
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Retry in ${retry_delay}s..."
            sleep $retry_delay
            
            # Exponential backoff with cap
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
    "ffmpeg"  # required by ComfyUI-WhisperX
)

PIP_PACKAGES=(
    "transformers==4.57.3"
    "openai-whisper"  # used below to pre-download Whisper large-v3 weights at provision time
    "omegaconf"       # required by pyannote when loading the VAD model checkpoint
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/flybirdxx/ComfyUI-Qwen-TTS"
    "https://github.com/AIFSH/ComfyUI-WhisperX"
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

# ==================== WHISPERX SETUP ====================

function provisioning_setup_whisperx() {
    log_info "Setting up WhisperX..."

    local whisperx_path="${COMFYUI_DIR}/custom_nodes/ComfyUI-WhisperX"
    if [[ ! -d "$whisperx_path" ]]; then
        log_warning "ComfyUI-WhisperX not found, skipping model pre-download"
        return
    fi

    # The AIFSH node's bundled vad.py expects pytorch_model.bin at a hardcoded local path
    # AND verifies its SHA256. The original S3 download URL is dead (301 with no Location).
    # The pip-installed whisperx package ships the correct file with the right checksum
    # directly inside its assets/ directory — copy from there, no download needed.
    local vad_model_path="${whisperx_path}/whisperx/assets/pytorch_model.bin"
    local vad_sha256="0b5b3216d60a2d32fc086b47ea8c67589aaeb26b7e07fcbe620d6d0b83e209ea"

    local need_copy=true
    if [[ -f "$vad_model_path" ]]; then
        local actual_sha=$(sha256sum "$vad_model_path" | awk '{print $1}')
        if [[ "$actual_sha" == "$vad_sha256" ]]; then
            log_info "✓ VAD model already present and verified"
            need_copy=false
        else
            log_warning "VAD model checksum mismatch, replacing..."
            rm -f "$vad_model_path"
        fi
    fi

    if [[ "$need_copy" == "true" ]]; then
        mkdir -p "${whisperx_path}/whisperx/assets"
        # The model is shipped directly in the main whisperX GitHub repo assets/
        # S3 URL is permanently dead; this is the canonical source used by the upstream project
        wget -q -O "$vad_model_path" \
            "https://github.com/m-bain/whisperX/raw/main/whisperx/assets/pytorch_model.bin" \
            && log_info "✓ VAD model downloaded from whisperX GitHub" \
            || log_error "❌ VAD model download failed — WhisperX will not work"
    fi

    # Persist model cache on /workspace so it survives instance restarts
    export HF_HOME="/workspace/.cache/huggingface"
    export TORCH_HOME="/workspace/.cache/torch"
    mkdir -p /workspace/.cache/huggingface /workspace/.cache/whisper /workspace/.cache/torch

    # Pre-download Whisper large-v3 weights so first inference isn't slow
    log_info "Pre-downloading Whisper large-v3..."
    python3 - << 'PYEOF'
import os, sys
os.environ['HF_HOME'] = '/workspace/.cache/huggingface'
os.environ['TORCH_HOME'] = '/workspace/.cache/torch'
try:
    import whisper
    whisper.load_model("large-v3", download_root="/workspace/.cache/whisper")
    print("✓ Whisper large-v3 ready")
except Exception as e:
    print(f"⚠ Whisper pre-download failed (will download on first use): {e}")
PYEOF

    # Pre-download pyannote models for speaker diarization (needs HF_TOKEN + licence accepted)
    if [[ -n "$HF_TOKEN" ]]; then
        log_info "Pre-downloading pyannote diarization models..."
        python3 - << 'PYEOF'
import os, sys
os.environ['HF_HOME'] = '/workspace/.cache/huggingface'
token = os.environ.get('HF_TOKEN', '')
try:
    from pyannote.audio import Pipeline
    Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=token)
    print("✓ pyannote speaker-diarization-3.1 ready")
except Exception as e:
    print(f"⚠ pyannote pre-download failed (needs licence accepted at hf.co): {e}")
PYEOF
    else
        log_info "HF_TOKEN not set — skipping pyannote pre-download (set token and accept licences at hf.co/pyannote)"
    fi

    log_info "✓ WhisperX setup complete"
}

# ==================== MAIN PROVISIONING ====================

function provisioning_start() {
    log_info "=========================================="
    log_info "  PROVISIONING START"
    log_info "=========================================="
    
    install_download_tools
    setup_output_http_server
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_setup_whisperx
    
    # Clean corrupted files before downloading
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
        pip install --no-cache-dir ${PIP_PACKAGES[@]} > /dev/null 2>&1
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
                pip install --no-cache-dir -r "${path}/requirements.txt" > /dev/null 2>&1
            fi
        fi
    done

    # The AIFSH/ComfyUI-WhisperX bundled vad.py uses pyannote.audio 2.x API.
    # pyannote.audio 3.x dropped use_auth_token from Inference.__init__() and
    # Model.from_pretrained(). pyannote.audio 2.1.1 requires torchaudio<1.0 which
    # is incompatible with this environment. Fix: patch vad.py to drop the removed args.
    local vad_py="${COMFYUI_DIR}/custom_nodes/ComfyUI-WhisperX/whisperx/vad.py"
    if [[ -f "$vad_py" ]]; then
        log_info "Patching vad.py for pyannote.audio 3.x compatibility..."
        # Remove use_auth_token from Model.from_pretrained() call
        sed -i 's/vad_model = Model.from_pretrained(model_fp, use_auth_token=use_auth_token)/vad_model = Model.from_pretrained(model_fp)/' "$vad_py"
        # Remove use_auth_token from VoiceActivitySegmentation super().__init__() call
        sed -i 's/super().__init__(segmentation=segmentation, fscore=fscore, use_auth_token=use_auth_token, \*\*inference_kwargs)/super().__init__(segmentation=segmentation, fscore=fscore, **inference_kwargs)/' "$vad_py"
        log_info "OK vad.py patched"
    fi
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
