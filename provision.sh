#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# ==================== CONFIGURATION ====================

MAX_RETRIES=5
BASE_RETRY_DELAY=10
MAX_RETRY_DELAY=60
MIN_TIMEOUT=60
MAX_TIMEOUT=1800

PROVISION_LOG="/var/log/provisioning-detailed.log"

# Auto-terminate if measured speed is below this threshold (MB/s).
# Requires VASTAI_API_TOKEN set in your Vast.ai account Settings → Environment Variables.
# $CONTAINER_ID is injected automatically by Vast.ai into every container.
MIN_SPEED_MBS=50

# ==================== LOGGING ====================

function log_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"    | tee -a "$PROVISION_LOG"; }
function log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"   | tee -a "$PROVISION_LOG" >&2; }
function log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG"; }

# ==================== INSTALL TOOLS ====================

function install_download_tools() {
    log_info "Installing download tools (apt)..."
    apt-get update 2>&1 | tee -a "$PROVISION_LOG"
    apt-get install -y aria2 curl jq bc 2>&1 | tee -a "$PROVISION_LOG"
    log_info "✓ aria2/curl/jq/bc installed"

    log_info "Installing huggingface-hub + hf_transfer (pip)..."
    pip install --no-cache-dir huggingface-hub[cli] hf_transfer 2>&1 | tee -a "$PROVISION_LOG"
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log_info "✓ huggingface-cli installed"
}

# ==================== NETWORK SPEED + AUTO-TERMINATE ====================
#
# IMPORTANT: measure_download_speed() uses `echo` to return a value.
# NEVER call log_info/log_warning inside it — those get captured by $()
# and corrupt the return value with timestamp strings.

function measure_download_speed() {
    # Downloads a real HuggingFace file for 15 seconds and reads curl's
    # internal speed_download counter (bytes/sec as a float).
    # We use a known ~170MB safetensors shard — HF is always reachable since
    # we download models from there anyway. Cloudflare speed test CDN is
    # often blocked on Vast.ai networks.
    # NO log calls here — pure echo return value only.
    local test_url="https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

    local raw
    raw=$(curl -o /dev/null -w "%{speed_download}" -s --max-time 15 "$test_url" 2>/dev/null)

    local mbs
    mbs=$(python3 -c "
try:
    v = int(float('${raw}') / 1048576)
    print(max(1, v))
except:
    print(1)
" 2>/dev/null)

    if ! [[ "$mbs" =~ ^[0-9]+$ ]]; then
        mbs=1
    fi

    echo "$mbs"
}

function check_speed_and_maybe_terminate() {
    # NOTE: this function logs — call it AFTER capturing measure_download_speed().
    local speed_mbs="$1"

    log_info "Network speed: ${speed_mbs} MB/s (threshold: ${MIN_SPEED_MBS} MB/s)"

    if [[ "$speed_mbs" -lt "$MIN_SPEED_MBS" ]]; then
        log_error "══════════════════════════════════════════════"
        log_error "  SLOW NETWORK: ${speed_mbs} MB/s < ${MIN_SPEED_MBS} MB/s"
        log_error "  Downloads will be extremely slow."
        log_error "══════════════════════════════════════════════"

        if [[ -n "$VASTAI_API_TOKEN" ]]; then
            # $CONTAINER_ID is a Vast.ai built-in env var — always present, no API call needed.
            if [[ -z "$CONTAINER_ID" ]]; then
                log_error "CONTAINER_ID not set — cannot auto-terminate"
                return
            fi
            log_warning "Auto-terminating instance ${CONTAINER_ID} due to slow network..."
            local response
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
                -H "Authorization: Bearer ${VASTAI_API_TOKEN}")
            if [[ "$response" == "200" ]]; then
                log_info "✓ Termination request accepted (HTTP 200). Halting provisioning."
            else
                log_error "Termination request returned HTTP ${response}"
            fi
            # Sleep so the delete has time to propagate before the process exits
            sleep 30
            exit 1
        else
            log_warning "VASTAI_API_TOKEN not set — skipping auto-terminate."
            log_warning "Set it in Vast.ai account Settings → Environment Variables."
        fi
    else
        log_info "══════════════════════════════════════════════"
        log_info "  ✓ NETWORK SPEED OK: ${speed_mbs} MB/s"
        log_info "══════════════════════════════════════════════"
    fi
}

function calculate_timeout() {
    # Args: file_size_gb  speed_mbs
    # Returns seconds, clamped between MIN_TIMEOUT and MAX_TIMEOUT.
    local gb="$1"
    local mbs="$2"

    gb=${gb%%.*}
    [[ -z "$gb" || "$gb" -le 0 ]] && gb=1
    [[ "$mbs" -le 0 ]] && mbs=1

    # seconds = (gb * 1024 MB) / speed_mbs * 1.5 safety buffer
    local secs=$(( gb * 1024 * 3 / mbs / 2 ))

    if   [[ $secs -lt $MIN_TIMEOUT ]]; then echo "$MIN_TIMEOUT"
    elif [[ $secs -gt $MAX_TIMEOUT ]]; then echo "$MAX_TIMEOUT"
    else echo "$secs"
    fi
}

function estimate_file_size_bytes() {
    # Returns exact file size in bytes using three methods in order:
    # 1. HuggingFace metadata API (most accurate for HF URLs)
    # 2. HTTP HEAD Content-Length
    # 3. Fallback: 5GB
    # NO log calls — this function is used inside $() captures.
    local url="$1"
    local bytes=0

    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}"
        local rev="${BASH_REMATCH[2]}"
        local file="${BASH_REMATCH[3]}"
        # HF metadata API returns JSON with "size" field in bytes
        local api_url="https://huggingface.co/api/models/${repo}/tree/${rev}"
        bytes=$(curl -s --max-time 10 "$api_url" 2>/dev/null             | python3 -c "
import sys, json
data = json.load(sys.stdin)
fname = '${file}'
for f in data:
    if f.get('path') == fname:
        print(f.get('size', 0))
        sys.exit(0)
print(0)
" 2>/dev/null)
    fi

    # Fallback to HEAD if API gave nothing
    if ! [[ "$bytes" =~ ^[0-9]+$ ]] || [[ "$bytes" -eq 0 ]]; then
        bytes=$(curl -sI --max-time 10 "$url" 2>/dev/null             | grep -i "^content-length:" | awk '{print $2}' | tr -d '
')
    fi

    if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
        echo "$bytes"
    else
        echo "5368709120"  # 5GB default
    fi
}

function estimate_file_size_gb() {
    local bytes
    bytes=$(estimate_file_size_bytes "$1")
    local gb=$(( bytes / 1073741824 ))
    echo $(( gb < 1 ? 1 : gb ))
}

# ==================== INTEGRITY VERIFICATION ====================

function get_hf_sha256() {
    # Fetch expected SHA256 from HuggingFace API for a given URL.
    # Returns the hash string or empty string if unavailable.
    # NO log calls — used inside $() captures.
    local url="$1"
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}"
        local rev="${BASH_REMATCH[2]}"
        local file="${BASH_REMATCH[3]}"
        curl -s --max-time 10             "https://huggingface.co/api/models/${repo}/tree/${rev}" 2>/dev/null             | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fname = '${file}'
    for f in data:
        if f.get('path') == fname:
            lfs = f.get('lfs', {})
            print(lfs.get('sha256', ''))
            sys.exit(0)
except: pass
print('')
" 2>/dev/null
    fi
}

function verify_file_integrity() {
    local filepath="$1"
    local expected_sha="$2"   # optional: pass expected SHA256 to verify against

    [[ ! -f "$filepath" ]] && return 1

    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)

    if [[ "$filesize" -lt 1048576 ]]; then
        log_warning "File too small (${filesize} bytes): $(basename "$filepath")"
        return 1
    fi

    # If expected SHA256 provided, verify it
    if [[ -n "$expected_sha" ]]; then
        log_info "Verifying SHA256: $(basename "$filepath")..."
        local actual_sha
        actual_sha=$(sha256sum "$filepath" | awk '{print $1}')
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            log_info "✓ SHA256 match: $(basename "$filepath") ($(( filesize / 1048576 ))MB)"
            return 0
        else
            log_error "✗ SHA256 MISMATCH: $(basename "$filepath")"
            log_error "  Expected: ${expected_sha}"
            log_error "  Actual:   ${actual_sha}"
            return 1
        fi
    fi

    # No SHA256 provided — fall back to safetensors header check
    case "$filepath" in
        *.safetensors)
            local ok
            ok=$(python3 -c "
import struct
try:
    with open('$filepath','rb') as f:
        n = struct.unpack('<Q', f.read(8))[0]
    print('ok' if 0 < n < 100_000_000 else 'bad')
except:
    print('bad')
" 2>/dev/null)
            if [[ "$ok" != "ok" ]]; then
                log_warning "Corrupted safetensors header: $(basename "$filepath")"
                return 1
            fi
            ;;
    esac

    log_info "✓ $(basename "$filepath") OK ($(( filesize / 1048576 ))MB)"
    return 0
}

# ==================== CLEANUP ====================

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

# ==================== DOWNLOAD ====================

function download_with_aria2() {
    local url="$1" dir="$2" filename="$3" timeout="$4" auth_token="$5"

    local aria2_opts=(
        "--max-connection-per-server=16"
        "--split=16"
        "--min-split-size=1M"
        "--max-tries=3"
        "--retry-wait=3"
        "--timeout=${timeout}"
        "--connect-timeout=30"
        "--console-log-level=warn"
        "--summary-interval=10"
        "--download-result=full"
        "--dir=${dir}"
        "--out=${filename}"
        "--allow-overwrite=true"
        "--auto-file-renaming=false"
        "--continue=true"
    )
    [[ -n "$auth_token" ]] && aria2_opts+=("--header=Authorization: Bearer ${auth_token}")

    aria2c "${aria2_opts[@]}" "$url" 2>&1 | tee -a "$PROVISION_LOG"
    return ${PIPESTATUS[0]}
}

function download_with_hf_cli() {
    local url="$1" dir="$2" filename="$3"

    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}" rev="${BASH_REMATCH[2]}" file="${BASH_REMATCH[3]}"
        log_info "HF CLI: ${repo}/${file}"

        HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download \
            "$repo" "$file" --revision "$rev" \
            --local-dir "$dir" --local-dir-use-symlinks False \
            --resume-download 2>&1 \
            | grep -v "FutureWarning" | grep -v "^$" \
            | tee -a "$PROVISION_LOG"

        local ec=${PIPESTATUS[0]}
        local dl="${dir}/${file}"
        if [[ $ec -eq 0 && -f "$dl" ]]; then
            [[ "$dl" != "${dir}/${filename}" ]] && mv "$dl" "${dir}/${filename}" 2>/dev/null
            find "$dir" -type d -empty -delete 2>/dev/null
            return 0
        fi
        return 1
    fi
    return 1
}

function provisioning_download_with_retry() {
    local url="$1" dir="$2"
    local filename; filename=$(basename "$url" | sed 's/?.*//')
    local filepath="${dir}/${filename}"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: ${filename}"

    # Fetch expected SHA256 from HF API before doing anything else
    local expected_sha=""
    if [[ "$url" =~ huggingface\.co ]]; then
        log_info "Fetching SHA256 from HF API..."
        expected_sha=$(get_hf_sha256 "$url")
        if [[ -n "$expected_sha" ]]; then
            log_info "Expected SHA256: ${expected_sha}"
        else
            log_warning "SHA256 unavailable from HF API — will use header check only"
        fi
    fi

    if [[ -f "$filepath" ]] && verify_file_integrity "$filepath" "$expected_sha"; then
        log_info "✓ Already valid — skipping"
        return 0
    fi
    rm -f "$filepath" "${filepath}.tmp" "${filepath}.aria2"

    local auth_token=""
    [[ -n "$HF_TOKEN"      && "$url" =~ huggingface\.co ]] && auth_token="$HF_TOKEN"
    [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com    ]] && auth_token="$CIVITAI_TOKEN"

    local speed_mbs; speed_mbs=$(cat /tmp/_provision_speed 2>/dev/null || echo 50)

    log_info "Fetching exact file size from HF API..."
    local file_bytes; file_bytes=$(estimate_file_size_bytes "$url")
    local gb=$(( file_bytes / 1073741824 ))
    [[ $gb -lt 1 ]] && gb=1
    local size_mb=$(( file_bytes / 1048576 ))
    local timeout; timeout=$(calculate_timeout "$gb" "$speed_mbs")
    log_info "Size: ${size_mb}MB (~${gb}GB) | Speed: ${speed_mbs} MB/s | Timeout: ${timeout}s"

    local attempt=1 retry_delay=$BASE_RETRY_DELAY
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt ${attempt}/${MAX_RETRIES}..."
        local t0; t0=$(date +%s)
        local ok=false

        if [[ "$url" =~ huggingface\.co ]]; then
            download_with_hf_cli "$url" "$dir" "$filename" && ok=true
        fi
        if [[ "$ok" == "false" ]]; then
            log_info "→ Falling back to aria2c..."
            download_with_aria2 "$url" "$dir" "$filename" "$timeout" "$auth_token" && ok=true
        fi

        local elapsed=$(( $(date +%s) - t0 ))

        if [[ "$ok" == "true" ]] && verify_file_integrity "$filepath" "$expected_sha"; then
            local mb=$(( $(stat -c%s "$filepath" 2>/dev/null || echo 0) / 1048576 ))
            log_info "✅ ${filename} done (${mb}MB in ${elapsed}s)"
            rm -f "${filepath}.tmp" "${filepath}.aria2"
            return 0
        fi

        log_warning "Attempt ${attempt} failed after ${elapsed}s"
        rm -f "$filepath" "${filepath}.tmp" "${filepath}.aria2"

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_info "Waiting ${retry_delay}s before retry..."
            sleep $retry_delay
            retry_delay=$(( retry_delay * 2 > MAX_RETRY_DELAY ? MAX_RETRY_DELAY : retry_delay * 2 ))
        fi
        (( attempt++ ))
    done

    log_error "❌ FAILED: ${filename}"
    return 1
}

# ==================== HTTP SERVER ====================

function setup_output_http_server() {
    log_info "Setting up output HTTP server on port 8081..."
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
    "ffmpeg"
)

PIP_PACKAGES=(
    "transformers==4.57.3"
    "openai-whisper"
    "omegaconf"
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

    local wx="${COMFYUI_DIR}/custom_nodes/ComfyUI-WhisperX"
    [[ ! -d "$wx" ]] && { log_warning "ComfyUI-WhisperX not found, skipping"; return; }

    local vad="${wx}/whisperx/assets/pytorch_model.bin"
    local vad_sha="0b5b3216d60a2d32fc086b47ea8c67589aaeb26b7e07fcbe620d6d0b83e209ea"

    local need_dl=true
    if [[ -f "$vad" ]]; then
        local actual; actual=$(sha256sum "$vad" | awk '{print $1}')
        if [[ "$actual" == "$vad_sha" ]]; then
            log_info "✓ VAD model already present and verified"
            need_dl=false
        else
            log_warning "VAD checksum mismatch — re-downloading"
            rm -f "$vad"
        fi
    fi

    if [[ "$need_dl" == "true" ]]; then
        log_info "Downloading VAD model from whisperX GitHub..."
        mkdir -p "${wx}/whisperx/assets"
        wget --progress=bar:force \
            -O "$vad" \
            "https://github.com/m-bain/whisperX/raw/main/whisperx/assets/pytorch_model.bin" \
            2>&1 | tee -a "$PROVISION_LOG" \
            && log_info "✓ VAD model downloaded" \
            || log_error "❌ VAD model download failed"
    fi

    export HF_HOME="/workspace/.cache/huggingface"
    export TORCH_HOME="/workspace/.cache/torch"
    mkdir -p /workspace/.cache/huggingface /workspace/.cache/whisper /workspace/.cache/torch

    log_info "Pre-downloading Whisper large-v3..."
    python3 - << 'PYEOF'
import os
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

# ==================== MAIN ====================

function provisioning_start() {
    log_info "=========================================="
    log_info "  PROVISIONING START"
    log_info "=========================================="

    install_download_tools

    # ── Speed check: must happen BEFORE any heavy work ──────────────────
    # measure_download_speed() has NO log calls (pure echo return value).
    # Logging only happens inside check_speed_and_maybe_terminate().
    log_info "Measuring network speed..."
    local NET_SPEED_MBS
    NET_SPEED_MBS=$(measure_download_speed)
    echo "$NET_SPEED_MBS" > /tmp/_provision_speed
    check_speed_and_maybe_terminate "$NET_SPEED_MBS"
    # ─────────────────────────────────────────────────────────────────────

    setup_output_http_server
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_setup_whisperx

    cleanup_corrupted_files "${COMFYUI_DIR}/models"

    provisioning_get_files "${COMFYUI_DIR}/models/loras"            "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae"              "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"    "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"

    log_info "=========================================="
    log_info "  PROVISIONING COMPLETE"
    log_info "=========================================="
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing APT packages: ${APT_PACKAGES[*]}"
        apt-get update 2>&1 | tee -a "$PROVISION_LOG"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}" 2>&1 | tee -a "$PROVISION_LOG"
        log_info "✓ APT done"
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        log_info "Installing PIP packages: ${PIP_PACKAGES[*]}"
        pip install --no-cache-dir "${PIP_PACKAGES[@]}" 2>&1 | tee -a "$PROVISION_LOG"
        log_info "✓ PIP done"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        local dir="${repo##*/}"
        local path="${COMFYUI_DIR}/custom_nodes/${dir}"

        if [[ -d "$path" ]]; then
            log_info "Node already cloned: ${dir}"
        else
            log_info "──────────────────────────────────────"
            log_info "Cloning node: ${dir}"
            log_info "From: ${repo}"
            # No --quiet: show real git output so you can see progress
            git clone "${repo}" "${path}" --recursive 2>&1 | tee -a "$PROVISION_LOG"
            log_info "✓ Cloned: ${dir}"

            if [[ -f "${path}/requirements.txt" ]]; then
                log_info "Installing pip requirements for ${dir}..."
                pip install --no-cache-dir -r "${path}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"
                log_info "✓ Requirements installed for ${dir}"
            fi
        fi
    done

    # Patch WhisperX vad.py: pyannote.audio 3.x removed use_auth_token arg
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
    log_info "Downloading ${#arr[@]} file(s) → ${dir}"
    for url in "${arr[@]}"; do
        provisioning_download_with_retry "$url" "$dir"
    done
}

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
