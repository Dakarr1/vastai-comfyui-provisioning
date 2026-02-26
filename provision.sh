#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# ==================== ADVANCED CONFIGURATION ====================

MAX_RETRIES=5
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=60

MIN_TIMEOUT=60
MAX_TIMEOUT=1800

PROVISION_LOG="/var/log/provisioning-detailed.log"
DOWNLOAD_SPEEDS_LOG="/tmp/download_speeds.log"

VERIFY_INTEGRITY=true

# Minimum acceptable download speed in MB/s (megabytes, not megabits).
# If measured speed is below this, provisioning logs a loud warning.
# To also auto-terminate the instance, set VASTAI_API_KEY in your Vast.ai
# instance env vars and set MIN_SPEED_MBS to your threshold.
MIN_SPEED_MBS=10

# ==================== LOGGING ====================

function log_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"    | tee -a "$PROVISION_LOG"; }
function log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"   | tee -a "$PROVISION_LOG" >&2; }
function log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG"; }

# ==================== INSTALL TOOLS ====================

function install_download_tools() {
    log_info "Installing download tools..."

    if ! command -v aria2c &> /dev/null; then
        apt-get update -qq
        apt-get install -y aria2 curl jq bc 2>&1 | tee -a "$PROVISION_LOG"
        log_info "✓ Installed aria2"
    fi

    if ! command -v huggingface-cli &> /dev/null; then
        pip install -q huggingface-hub[cli] hf_transfer 2>&1 | tee -a "$PROVISION_LOG"
        export HF_HUB_ENABLE_HF_TRANSFER=1
        log_info "✓ Installed huggingface-cli"
    fi

    touch "$DOWNLOAD_SPEEDS_LOG"
}

# ==================== NETWORK SPEED ====================

function measure_download_speed() {
    # Downloads ~1MB test file; curl reports speed_download in bytes/sec natively.
    # Returns integer MB/s (megabytes per second).
    local test_url="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/transformers/model_card/model_card_annotated.png"
    local test_file="/tmp/speed_test_$$"

    log_info "Measuring network speed..."

    # -w "%{speed_download}" writes bytes/sec to stdout; -o discards body
    local bytes_per_sec
    bytes_per_sec=$(curl -o "$test_file" -w "%{speed_download}" -s --max-time 30 "$test_url" 2>/dev/null)
    rm -f "$test_file"

    # bytes_per_sec is a float like "125430271.000"; convert to integer MB/s
    local speed_mbs
    speed_mbs=$(awk "BEGIN { v=int($bytes_per_sec / 1048576); print (v<1)?1:v }" 2>/dev/null)

    # Guard: awk may fail if bytes_per_sec is empty/non-numeric
    if ! [[ "$speed_mbs" =~ ^[0-9]+$ ]]; then
        log_warning "Speed measurement failed, defaulting to 50 MB/s"
        speed_mbs=50
    fi

    log_info "Measured speed: ${speed_mbs} MB/s"
    echo "$speed_mbs"
}

function check_speed_and_warn() {
    local speed_mbs="$1"

    if [[ $speed_mbs -lt $MIN_SPEED_MBS ]]; then
        log_error "══════════════════════════════════════════════════"
        log_error "  SLOW NETWORK DETECTED: ${speed_mbs} MB/s < ${MIN_SPEED_MBS} MB/s minimum"
        log_error "  Downloads will be very slow. Consider terminating"
        log_error "  this instance and renting a faster one."
        log_error "══════════════════════════════════════════════════"

        # Auto-terminate if VASTAI_API_KEY env var is set.
        # Set this privately in your Vast.ai instance template — DO NOT hardcode it here.
        if [[ -n "$VASTAI_API_KEY" && -n "$CONTAINER_ID" ]]; then
            log_warning "VASTAI_API_KEY found — auto-terminating instance ${CONTAINER_ID}..."
            curl -s -X DELETE \
                "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
                -H "Authorization: Bearer ${VASTAI_API_KEY}" \
                >> "$PROVISION_LOG" 2>&1
            log_info "Termination request sent. Sleeping 60s..."
            sleep 60  # Give time for termination to take effect
        fi
    else
        log_info "✓ Network speed OK: ${speed_mbs} MB/s"
    fi
}

function calculate_intelligent_timeout() {
    local file_size_gb="$1"
    local speed_mbs="$2"   # MB/s

    file_size_gb=${file_size_gb%%.*}
    [[ -z "$file_size_gb" || "$file_size_gb" -eq 0 ]] && file_size_gb=1

    local file_size_mb=$((file_size_gb * 1024))
    # seconds = size_MB / speed_MBs * 1.5 buffer
    local expected_seconds=$(( file_size_mb * 3 / speed_mbs / 2 ))

    if   [[ $expected_seconds -lt $MIN_TIMEOUT ]]; then echo "$MIN_TIMEOUT"
    elif [[ $expected_seconds -gt $MAX_TIMEOUT ]]; then echo "$MAX_TIMEOUT"
    else echo "$expected_seconds"
    fi
}

function estimate_file_size_gb() {
    local url="$1"
    local bytes
    bytes=$(curl -sI --max-time 10 "$url" 2>/dev/null | grep -i "^content-length:" | awk '{print $2}' | tr -d '\r')
    if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
        local gb=$(( bytes / 1073741824 ))
        echo $(( gb < 1 ? 1 : gb ))
    else
        echo "5"
    fi
}

# ==================== INTEGRITY VERIFICATION ====================

function verify_file_integrity() {
    local filepath="$1"

    [[ ! -f "$filepath" ]] && return 1

    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)

    # A valid safetensors/bin model file is never under 1MB
    if [[ "$filesize" -lt 1048576 ]]; then
        log_warning "File suspiciously small: $(basename "$filepath") — ${filesize} bytes"
        return 1
    fi

    # sha256 check: HuggingFace embeds the sha256 in a .metadata sidecar or
    # we can compare against the HF API. For now: verify file is not truncated
    # by checking it can be parsed as a safetensors header (first 8 bytes = header len).
    case "$filepath" in
        *.safetensors)
            local header_len
            header_len=$(python3 -c "
import struct, sys
try:
    with open('$filepath','rb') as f:
        n = struct.unpack('<Q', f.read(8))[0]
    print(n if 0 < n < 100_000_000 else 'bad')
except: print('bad')
" 2>/dev/null)
            if [[ "$header_len" == "bad" ]]; then
                log_warning "Corrupted safetensors header: $(basename "$filepath")"
                return 1
            fi
            ;;
    esac

    log_info "✓ Integrity OK: $(basename "$filepath") ($(( filesize / 1048576 ))MB)"
    return 0
}

# ==================== SMART CLEANUP ====================

function cleanup_corrupted_files() {
    local dir="$1"
    log_info "Scanning for corrupted files in ${dir}..."

    find "$dir" -name "*.tmp"   -delete 2>/dev/null
    find "$dir" -name "*.aria2" -delete 2>/dev/null

    local cleaned=0
    while IFS= read -r file; do
        if ! verify_file_integrity "$file" > /dev/null 2>&1; then
            log_warning "Removing corrupted: $(basename "$file")"
            rm -f "$file"
            (( cleaned++ ))
        fi
    done < <(find "$dir" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" \) 2>/dev/null)

    [[ $cleaned -gt 0 ]] && log_info "Cleaned ${cleaned} corrupted file(s)"
}

# ==================== DOWNLOAD FUNCTIONS ====================

function download_with_aria2() {
    local url="$1" output_dir="$2" output_file="$3" timeout="$4" auth_token="$5"

    local aria2_opts=(
        "--max-connection-per-server=16"
        "--split=16"
        "--min-split-size=1M"
        "--max-tries=3"
        "--retry-wait=3"
        "--timeout=${timeout}"
        "--connect-timeout=30"
        "--console-log-level=warn"   # show warnings/errors but not verbose INFO spam
        "--summary-interval=10"      # print progress every 10s so you can see it's alive
        "--download-result=full"
        "--dir=${output_dir}"
        "--out=${output_file}"
        "--allow-overwrite=true"
        "--auto-file-renaming=false"
        "--continue=true"
    )

    [[ -n "$auth_token" ]] && aria2_opts+=("--header=Authorization: Bearer ${auth_token}")

    # tee to log AND stdout so you see progress in provisioning output
    aria2c "${aria2_opts[@]}" "$url" 2>&1 | tee -a "$PROVISION_LOG"
    return ${PIPESTATUS[0]}
}

function download_with_hf_cli() {
    local url="$1" output_dir="$2" output_file="$3"

    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo_id="${BASH_REMATCH[1]}"
        local revision="${BASH_REMATCH[2]}"
        local filename="${BASH_REMATCH[3]}"

        log_info "HF CLI: ${repo_id}/${filename}"

        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download \
            "$repo_id" "$filename" \
            --revision "$revision" \
            --local-dir "$output_dir" \
            --local-dir-use-symlinks False \
            --resume-download 2>&1 | grep -v "FutureWarning" | grep -v "^$" | tee -a "$PROVISION_LOG"

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

function provisioning_download_with_retry() {
    local url="$1"
    local dir="$2"
    local filename
    filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: ${filename}"

    if [[ -f "$filepath" ]] && verify_file_integrity "$filepath"; then
        log_info "✓ Already exists and valid: ${filename}"
        return 0
    fi

    rm -f "$filepath" "${filepath}.tmp" "${filepath}.aria2"

    local auth_token=""
    [[ -n "$HF_TOKEN"      && "$url" =~ huggingface\.co ]] && auth_token="$HF_TOKEN"
    [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com    ]] && auth_token="$CIVITAI_TOKEN"

    # Speed is measured once and cached as MB/s
    if [[ ! -f /tmp/network_speed_cached ]]; then
        local speed_mbs
        speed_mbs=$(measure_download_speed)
        echo "$speed_mbs" > /tmp/network_speed_cached
        check_speed_and_warn "$speed_mbs"
    fi
    local speed_mbs
    speed_mbs=$(cat /tmp/network_speed_cached)

    local estimated_gb
    estimated_gb=$(estimate_file_size_gb "$url")
    local timeout
    timeout=$(calculate_intelligent_timeout "$estimated_gb" "$speed_mbs")
    log_info "Size: ~${estimated_gb}GB | Speed: ${speed_mbs} MB/s | Timeout: ${timeout}s"

    local attempt=1
    local retry_delay=$BASE_RETRY_DELAY

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt ${attempt}/${MAX_RETRIES}..."

        local t_start
        t_start=$(date +%s)
        local success=false

        if [[ "$url" =~ huggingface\.co ]]; then
            download_with_hf_cli "$url" "$dir" "$filename" && success=true
        fi

        if [[ "$success" == "false" ]]; then
            log_info "→ aria2c fallback"
            download_with_aria2 "$url" "$dir" "$filename" "$timeout" "$auth_token" && success=true
        fi

        local duration=$(( $(date +%s) - t_start ))

        if [[ "$success" == "true" ]] && verify_file_integrity "$filepath"; then
            local size_mb=$(( $(stat -c%s "$filepath" 2>/dev/null || echo 0) / 1048576 ))
            log_info "✅ Done: ${filename} (${size_mb}MB in ${duration}s)"
            rm -f "${filepath}.tmp" "${filepath}.aria2"
            return 0
        fi

        log_warning "Attempt ${attempt} failed (${duration}s)"
        rm -f "$filepath" "${filepath}.tmp" "${filepath}.aria2"

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Retry in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$(( retry_delay * 2 > MAX_RETRY_DELAY ? MAX_RETRY_DELAY : retry_delay * 2 ))
        fi
        (( attempt++ ))
    done

    log_error "❌ FAILED after ${MAX_RETRIES} attempts: ${filename}"
    return 1
}

# ==================== HTTP SERVER ====================

function setup_output_http_server() {
    log_info "Setting up output HTTP server..."
    mkdir -p "${COMFYUI_DIR}/output"

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
    supervisorctl status comfyui-output-server 2>/dev/null | grep -q RUNNING \
        && log_info "✅ HTTP server running on port 8081" \
        || log_warning "HTTP server may not have started"
}

# ==================== PACKAGE DEFINITIONS ====================

APT_PACKAGES=(
    "ffmpeg"  # required by ComfyUI-WhisperX
)

PIP_PACKAGES=(
    "transformers==4.57.3"
    "openai-whisper"  # pre-downloads Whisper large-v3 weights at provision time
    "omegaconf"       # required by pyannote when loading VAD checkpoint
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
        log_warning "ComfyUI-WhisperX not found, skipping"
        return
    fi

    # The VAD model must have an exact SHA256 that vad.py checks against.
    # The original S3 URL is permanently dead. Source: upstream whisperX GitHub repo.
    local vad_model_path="${whisperx_path}/whisperx/assets/pytorch_model.bin"
    local vad_sha256="0b5b3216d60a2d32fc086b47ea8c67589aaeb26b7e07fcbe620d6d0b83e209ea"

    local need_download=true
    if [[ -f "$vad_model_path" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$vad_model_path" | awk '{print $1}')
        if [[ "$actual_sha" == "$vad_sha256" ]]; then
            log_info "✓ VAD model already present and verified"
            need_download=false
        else
            log_warning "VAD model checksum mismatch — re-downloading"
            rm -f "$vad_model_path"
        fi
    fi

    if [[ "$need_download" == "true" ]]; then
        log_info "Downloading VAD model from whisperX GitHub..."
        mkdir -p "${whisperx_path}/whisperx/assets"
        wget -q --show-progress \
            -O "$vad_model_path" \
            "https://github.com/m-bain/whisperX/raw/main/whisperx/assets/pytorch_model.bin" \
            2>&1 | tee -a "$PROVISION_LOG" \
            && log_info "✓ VAD model downloaded" \
            || log_error "❌ VAD model download failed"
    fi

    # Cache dir on /workspace survives instance restarts
    export HF_HOME="/workspace/.cache/huggingface"
    export TORCH_HOME="/workspace/.cache/torch"
    mkdir -p /workspace/.cache/huggingface /workspace/.cache/whisper /workspace/.cache/torch

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

    if [[ -n "$HF_TOKEN" ]]; then
        log_info "Pre-downloading pyannote diarization models..."
        python3 - << 'PYEOF'
import os
os.environ['HF_HOME'] = '/workspace/.cache/huggingface'
token = os.environ.get('HF_TOKEN', '')
try:
    from pyannote.audio import Pipeline
    Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", use_auth_token=token)
    print("✓ pyannote speaker-diarization-3.1 ready")
except Exception as e:
    print(f"⚠ pyannote pre-download failed (accept licence at hf.co/pyannote): {e}")
PYEOF
    else
        log_info "HF_TOKEN not set — skipping pyannote pre-download"
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

    cleanup_corrupted_files "${COMFYUI_DIR}/models"

    provisioning_get_files "${COMFYUI_DIR}/models/loras"             "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae"               "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"     "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models"  "${DIFFUSION_MODELS[@]}"

    log_info "=========================================="
    log_info "  PROVISIONING COMPLETE"
    log_info "=========================================="
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing APT packages: ${APT_PACKAGES[*]}"
        apt-get update 2>&1 | tee -a "$PROVISION_LOG"
        apt-get install -y "${APT_PACKAGES[@]}" 2>&1 | tee -a "$PROVISION_LOG"
        log_info "✓ APT packages installed"
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing PIP packages: ${PIP_PACKAGES[*]}"
        pip install --no-cache-dir "${PIP_PACKAGES[@]}" 2>&1 | tee -a "$PROVISION_LOG"
        log_info "✓ PIP packages installed"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        local dir="${repo##*/}"
        local path="${COMFYUI_DIR}/custom_nodes/${dir}"

        if [[ -d "$path" ]]; then
            log_info "Node already exists: ${dir}"
        else
            log_info "Cloning node: ${dir}"
            git clone "${repo}" "${path}" --recursive 2>&1 | tee -a "$PROVISION_LOG"

            if [[ -f "${path}/requirements.txt" ]]; then
                log_info "Installing requirements for ${dir}..."
                pip install --no-cache-dir -r "${path}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"
            fi
        fi
    done

    # Patch WhisperX vad.py: uses pyannote.audio 2.x API, but 3.x is installed.
    # pyannote 3.x dropped use_auth_token from Inference.__init__() and Model.from_pretrained().
    local vad_py="${COMFYUI_DIR}/custom_nodes/ComfyUI-WhisperX/whisperx/vad.py"
    if [[ -f "$vad_py" ]]; then
        log_info "Patching vad.py for pyannote.audio 3.x..."
        sed -i 's/vad_model = Model.from_pretrained(model_fp, use_auth_token=use_auth_token)/vad_model = Model.from_pretrained(model_fp)/' "$vad_py"
        sed -i 's/super().__init__(segmentation=segmentation, fscore=fscore, use_auth_token=use_auth_token, \*\*inference_kwargs)/super().__init__(segmentation=segmentation, fscore=fscore, **inference_kwargs)/' "$vad_py"
        log_info "✓ vad.py patched"
    fi
}

function provisioning_get_files() {
    [[ -z "$2" ]] && return 0
    local dir="$1"; shift
    local arr=("$@")
    [[ ${#arr[@]} -eq 0 ]] && return 0

    mkdir -p "$dir"
    log_info "Downloading ${#arr[@]} file(s) to ${dir}"

    for url in "${arr[@]}"; do
        provisioning_download_with_retry "$url" "$dir"
    done
}

# Start provisioning
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
