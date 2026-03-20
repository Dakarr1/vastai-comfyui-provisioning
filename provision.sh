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


# Global: tunnel portion of label — set once in setup_tunnels_and_label,
# then preserved in every subsequent set_status_label call.
TUNNEL_LABEL_PART=""

# ==================== LOGGING ====================

function log_info()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"    | tee -a "$PROVISION_LOG"; }
function log_error()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"   | tee -a "$PROVISION_LOG" >&2; }
function log_warning() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$PROVISION_LOG"; }

# ==================== LABEL / STATUS ====================

function set_instance_label() {
    # Raw label setter — pass full label string.
    # NO log calls inside — called from functions that may be used in $() captures.
    local label="$1"
    [[ -z "$VASTAI_API_TOKEN" || -z "$CONTAINER_ID" ]] && return 1
    curl -s -o /dev/null \
        -X PUT \
        "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
        -H "Authorization: Bearer ${VASTAI_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"label\": \"${label}\"}" 2>/dev/null
}

function set_status_label() {
    # Sets label as "status:MESSAGE|TUNNELS" preserving tunnel info.
    # Use this everywhere to update provisioning status.
    local status="$1"
    local label="status:${status}"
    [[ -n "$TUNNEL_LABEL_PART" ]] && label="${label}|${TUNNEL_LABEL_PART}"
    set_instance_label "$label"
    log_info "◈ Status: ${status}"
}

# ==================== INSTALL TOOLS ====================

function install_download_tools() {
    log_info "Installing download tools (apt)..."
    apt-get update 2>&1 | tee -a "$PROVISION_LOG"
    apt-get install -y aria2 curl jq bc 2>&1 | tee -a "$PROVISION_LOG"
    log_info "✓ aria2/curl/jq/bc installed"

    log_info "Installing pip tools..."
    pip install --no-cache-dir huggingface-hub[cli] hf_transfer 2>&1 | tee -a "$PROVISION_LOG"
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log_info "✓ pip tools installed"
}

# ==================== NETWORK SPEED + AUTO-TERMINATE ====================
function calculate_timeout() {
    local gb="$1" mbs="$2"
    gb=${gb%%.*}
    [[ -z "$gb" || "$gb" -le 0 ]] && gb=1
    [[ "$mbs" -le 0 ]] && mbs=1
    local secs=$(( gb * 1024 * 3 / mbs / 2 ))
    if   [[ $secs -lt $MIN_TIMEOUT ]]; then echo "$MIN_TIMEOUT"
    elif [[ $secs -gt $MAX_TIMEOUT ]]; then echo "$MAX_TIMEOUT"
    else echo "$secs"
    fi
}

# ==================== FILE SIZE + SHA256 ====================
# NO log calls in these functions — used inside $() captures.

function estimate_file_size_bytes() {
    local url="$1"
    local bytes=0

    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}" rev="${BASH_REMATCH[2]}" file="${BASH_REMATCH[3]}"
        bytes=$(curl -s --max-time 10 \
            "https://huggingface.co/api/models/${repo}/tree/${rev}" 2>/dev/null \
            | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fname = '${file}'
    for f in data:
        if f.get('path') == fname:
            print(f.get('size', 0))
            sys.exit(0)
except: pass
print(0)
" 2>/dev/null)
    fi

    if ! [[ "$bytes" =~ ^[0-9]+$ ]] || [[ "$bytes" -eq 0 ]]; then
        bytes=$(curl -sI --max-time 10 "$url" 2>/dev/null \
            | grep -i "^content-length:" | awk '{print $2}' | tr -d '\r')
    fi

    if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
        echo "$bytes"
    else
        echo "5368709120"
    fi
}

function estimate_file_size_gb() {
    local bytes; bytes=$(estimate_file_size_bytes "$1")
    local gb=$(( bytes / 1073741824 ))
    echo $(( gb < 1 ? 1 : gb ))
}

function get_hf_sha256() {
    # Returns the SHA256 hash (without prefix) for a HF file URL.
    # HF API returns lfs.oid as "sha256:abcdef..." — strip the prefix.
    # NO log calls.
    local url="$1"
    if [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]]; then
        local repo="${BASH_REMATCH[1]}" rev="${BASH_REMATCH[2]}" file="${BASH_REMATCH[3]}"
        curl -s --max-time 10 \
            "https://huggingface.co/api/models/${repo}/tree/${rev}" 2>/dev/null \
            | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fname = '${file}'
    for f in data:
        if f.get('path') == fname:
            lfs = f.get('lfs', {})
            oid = lfs.get('oid', lfs.get('sha256', ''))
            # Strip 'sha256:' prefix if present
            print(oid.replace('sha256:', ''))
            sys.exit(0)
except: pass
print('')
" 2>/dev/null
    fi
}

# ==================== INTEGRITY VERIFICATION ====================

function verify_file_integrity() {
    local filepath="$1"
    local expected_sha="$2"

    [[ ! -f "$filepath" ]] && return 1

    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)

    if [[ "$filesize" -lt 1048576 ]]; then
        log_warning "File too small (${filesize} bytes): $(basename "$filepath")"
        return 1
    fi

    if [[ -n "$expected_sha" ]]; then
        log_info "Verifying SHA256: $(basename "$filepath")..."
        local actual_sha
        actual_sha=$(sha256sum "$filepath" | awk '{print $1}')
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            log_info "✓ SHA256 OK: $(basename "$filepath") ($(( filesize / 1048576 ))MB)"
            return 0
        else
            log_error "✗ SHA256 MISMATCH: $(basename "$filepath")"
            log_error "  Expected: ${expected_sha}"
            log_error "  Actual:   ${actual_sha}"
            return 1
        fi
    fi

    # No SHA256 — safetensors header check
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

        # Detect hf CLI version to use correct flags
        # New versions (>=0.24) removed --local-dir-use-symlinks and --resume-download
        local hf_ver
        hf_ver=$(hf version 2>/dev/null | grep -oP '[\d]+\.[\d]+' | head -1)
        local major minor
        major=$(echo "$hf_ver" | cut -d. -f1)
        minor=$(echo "$hf_ver" | cut -d. -f2)

        local extra_flags=""
        if [[ -z "$hf_ver" || "$major" -lt 1 && "$minor" -lt 24 ]] 2>/dev/null; then
            # Old CLI — use legacy flags
            extra_flags="--local-dir-use-symlinks False --resume-download"
        fi

        HF_HUB_ENABLE_HF_TRANSFER=1 hf download             "$repo" "$file" --revision "$rev"             --local-dir "$dir"             $extra_flags 2>&1             | grep -v "FutureWarning" | grep -v "^$"             | tee -a "$PROVISION_LOG"

        local ec=${PIPESTATUS[0]}
        # hf download places file at dir/file (may include subdirs from repo)
        local dl="${dir}/${file}"
        if [[ $ec -eq 0 && -f "$dl" ]]; then
            [[ "$dl" != "${dir}/${filename}" ]] && mv "$dl" "${dir}/${filename}" 2>/dev/null
            find "$dir" -type d -empty -delete 2>/dev/null
            return 0
        fi
        # Fallback: search for the file anywhere under dir
        local found
        found=$(find "$dir" -name "$filename" -type f 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            [[ "$found" != "${dir}/${filename}" ]] && mv "$found" "${dir}/${filename}" 2>/dev/null
            find "$dir" -type d -empty -delete 2>/dev/null
            return 0
        fi
        return 1
    fi
    return 1
}

function provisioning_download_with_retry() {
    local url="$1" dir="$2" override_name="${3:-}"
    local filename; filename=$(basename "$url" | sed 's/?.*//'); [[ -n "$override_name" ]] && filename="$override_name"
    local filepath="${dir}/${filename}"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: ${filename}"
    set_status_label "Downloading:${filename}"

    # Fetch SHA256 from HF API
    local expected_sha=""
    if [[ "$url" =~ huggingface\.co ]]; then
        log_info "Fetching SHA256 from HF API..."
        expected_sha=$(get_hf_sha256 "$url")
        if [[ -n "$expected_sha" ]]; then
            log_info "Expected SHA256: ${expected_sha}"
        else
            log_warning "SHA256 not available — will use header check only"
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

    local speed_mbs=100  # no speed test — use generous default

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

# ==================== API WRAPPER TIMEOUT FIX ====================

function fix_api_wrapper_timeout() {
    local worker="/opt/comfyui-api-wrapper/workers/generation_worker.py"

    if [[ ! -f "$worker" ]]; then
        log_warning "api-wrapper worker not found at ${worker} — skipping timeout fix"
        return
    fi

    log_info "Patching api-wrapper WEBSOCKET_MESSAGE_TIMEOUT..."

    # Inject 'import os' after 'import asyncio' if not already present
    if ! grep -q "^import os" "$worker"; then
        sed -i 's/^import asyncio/import asyncio\nimport os/' "$worker"
    fi

    # Replace hardcoded timeout with env var (default 600s)
    sed -i 's/message_timeout = [0-9.]*/message_timeout = float(os.getenv("WEBSOCKET_MESSAGE_TIMEOUT", "600.0"))/' "$worker"

    log_info "Timeout patched — restarting api-wrapper..."

    # Kill existing uvicorn
    kill $(ps aux | grep uvicorn | grep -v grep | awk '{print $2}') 2>/dev/null || true
    sleep 2

    # Restart on correct port
    cd /opt/comfyui-api-wrapper && .venv/bin/uvicorn main:app --port 8288 &
    log_info "api-wrapper restarted on port 8288 (PID: $!)"
}

# ==================== HTTP SERVER ====================

function setup_output_http_server() {
    log_info "Setting up output HTTP server on port 8081..."
    mkdir -p "${COMFYUI_DIR}/output"
    cat > /etc/supervisor/conf.d/comfyui-output-server.conf << 'SUPEOF'
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
SUPEOF
    supervisorctl reread > /dev/null 2>&1
    supervisorctl update > /dev/null 2>&1
    supervisorctl start comfyui-output-server > /dev/null 2>&1
    sleep 2
    supervisorctl status comfyui-output-server 2>/dev/null | grep -q RUNNING \
        && log_info "✅ HTTP server running on port 8081" \
        || log_warning "HTTP server may not have started"
}

# ==================== TUNNEL DISCOVERY + LABEL ====================

function setup_tunnels_and_label() {
    local logfile="/var/log/tunnel_manager.log"
    local cf_log="/tmp/cloudflared_8081.log"

    # ── Step 1: count expected ports from PORTAL_CONFIG ──────────
    local expected_count=0
    if [[ -n "$PORTAL_CONFIG" ]]; then
        expected_count=$(echo "$PORTAL_CONFIG" \
            | tr '|' '\n' \
            | grep -oP 'localhost:\K\d+' \
            | sort -u \
            | wc -l)
        log_info "Expecting ${expected_count} tunnel(s) from PORTAL_CONFIG"
    fi
    [[ $expected_count -lt 1 ]] && expected_count=1

    # ── Step 2: wait until we have enough "Default Tunnel started" lines ─
    # tunnel_manager writes these lines when tunnels are ready.
    # By the time provision.sh runs, most/all are already written.
    # We just wait in case some are still coming (e.g. slow CF response).
    log_info "Waiting for 'Default Tunnel started' lines in log..."
    local waited=0
    local found=0
    while [[ $waited -lt 45 ]]; do
        found=$(grep -c 'Default Tunnel started for' "$logfile" 2>/dev/null || true)
        found="${found//[^0-9]/}"; found="${found:-0}"
        if [[ $found -ge $expected_count ]]; then
            log_info "✓ ${found}/${expected_count} tunnel lines found after ${waited}s"
            break
        fi
        # If we have some and count hasn't grown for 9s, CF probably 429'd the rest
        if [[ $waited -ge 9 && $found -gt 0 ]]; then
            local prev=$found
            sleep 3
            local now; now=$(grep -c 'Default Tunnel started for' "$logfile" 2>/dev/null || true)
            now="${now//[^0-9]/}"; now="${now:-0}"
            if [[ $now -eq $prev ]]; then
                log_warning "Count stable at ${found}/${expected_count} — likely 429 on rest, proceeding"
                found=$now
                break
            fi
            (( waited += 3 ))
            continue
        fi
        log_info "Found ${found}/${expected_count} — waiting... (${waited}s)"
        sleep 3
        (( waited += 3 ))
    done

    [[ $found -eq 0 ]] && log_warning "No 'Default Tunnel started' lines found after ${waited}s"

    # ── Step 3: extract ALL "Default Tunnel started" lines ───────
    # Format: "Default Tunnel started for http(s)://localhost:PORT - https://URL?token=..."
    local tunnels=""
    local seen_ports=""

    while IFS= read -r line; do
        local port="" url=""
        if [[ "$line" =~ Default\ Tunnel\ started\ for\ https?://localhost:([0-9]+)\ -\ (https://[a-z0-9-]+\.trycloudflare\.com) ]]; then
            port="${BASH_REMATCH[1]}"
            url="${BASH_REMATCH[2]}"
            if [[ -n "$port" && -n "$url" && "$seen_ports" != *"|${port}|"* ]]; then
                seen_ports="${seen_ports}|${port}|"
                [[ -n "$tunnels" ]] && tunnels="${tunnels},"
                tunnels="${tunnels}${port}:${url}"
                log_info "✓ Tunnel: ${port} → ${url}"
            fi
        fi
    done < <(grep 'Default Tunnel started for' "$logfile" 2>/dev/null)

    # ── Step 4: cloudflared tunnel for port 8081 ─────────────────
    log_info "Starting cloudflared tunnel for port 8081..."
    rm -f "$cf_log"
    cloudflared tunnel --url http://localhost:8081 > "$cf_log" 2>&1 &
    local cf_pid=$!
    log_info "cloudflared PID: ${cf_pid}"

    local cf_url=""
    for i in {1..20}; do
        cf_url=$(grep -o 'https://[-a-z0-9.]*\.trycloudflare\.com' "$cf_log" 2>/dev/null | head -1)
        if [[ -n "$cf_url" ]]; then
            log_info "✓ cloudflared 8081 tunnel: ${cf_url}"
            [[ -n "$tunnels" ]] && tunnels="${tunnels},"
            tunnels="${tunnels}8081:${cf_url}"
            break
        fi
        if grep -q '429\|Too Many Requests\|failed to\|context deadline' "$cf_log" 2>/dev/null; then
            log_warning "cloudflared 8081 failed (429 or timeout) — skipping"
            kill "$cf_pid" 2>/dev/null
            break
        fi
        sleep 2
    done

    [[ -z "$cf_url" ]] && kill "$cf_pid" 2>/dev/null

    # ── Step 5: set label ─────────────────────────────────────────
    TUNNEL_LABEL_PART="$tunnels"

    if [[ -n "$tunnels" ]]; then
        set_status_label "Provisioning:started"
        log_info "✓ Label set: ${tunnels}"
    else
        log_warning "No tunnels found — label set without tunnels"
        set_status_label "Provisioning:started"
    fi
}
# ==================== PACKAGE DEFINITIONS ====================

APT_PACKAGES=(
    "ffmpeg"
    "portaudio19-dev"   # required by sounddevice (TTS-Audio-Suite voice recording)
)

PIP_PACKAGES=(
    "transformers==4.57.3"
)

NODES=(
    "https://github.com/diodiogod/TTS-Audio-Suite"
    "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation"
    "https://github.com/kijai/ComfyUI-KJNodes"
)

CHECKPOINT_MODELS=()
UNET_MODELS=()

LORA_MODELS=(
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
)

# clip_vision: pipe-separated "url|target_filename"
CLIP_VISION_MODELS=(
    "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors|clip_vision_h.safetensors"
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

ESRGAN_MODELS=(
    "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
)
CONTROLNET_MODELS=()
LATENT_UPSCALE_MODELS=()
WORKFLOWS=()


# ==================== MAIN ====================

function provisioning_start() {
    log_info "=========================================="
    log_info "  PROVISIONING START"
    log_info "=========================================="

    install_download_tools

    setup_output_http_server
    fix_api_wrapper_timeout
    setup_tunnels_and_label   # sets TUNNEL_LABEL_PART, sets first label with tunnels

    set_status_label "Provisioning:apt_packages"
    provisioning_get_apt_packages

    set_status_label "Provisioning:cloning_nodes"
    provisioning_get_nodes

    set_status_label "Provisioning:pip_packages"
    provisioning_get_pip_packages


    set_status_label "Provisioning:loras"
    provisioning_get_files "${COMFYUI_DIR}/models/loras"            "${LORA_MODELS[@]}"

    set_status_label "Provisioning:clip_vision"
    provisioning_get_clip_vision "${COMFYUI_DIR}/models/clip_vision" "${CLIP_VISION_MODELS[@]}"

    set_status_label "Provisioning:vae"
    provisioning_get_files "${COMFYUI_DIR}/models/vae"              "${VAE_MODELS[@]}"

    set_status_label "Provisioning:text_encoders"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"    "${TEXT_ENCODER_MODELS[@]}"

    set_status_label "Provisioning:diffusion_models"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"

    set_status_label "Provisioning:upscale_models"
    provisioning_get_files "${COMFYUI_DIR}/models/upscale_models"   "${ESRGAN_MODELS[@]}"

    set_status_label "Provisioning:scanning_models"
    cleanup_corrupted_files "${COMFYUI_DIR}/models"

    set_status_label "READY"

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
            set_status_label "Provisioning:cloning_${dir}"
            git clone "${repo}" "${path}" --recursive 2>&1 | tee -a "$PROVISION_LOG"
            log_info "✓ Cloned: ${dir}"

            if [[ -f "${path}/install.py" ]]; then
                log_info "Running install.py for ${dir}..."
                set_status_label "Provisioning:pip_${dir}"
                cd "${path}" && python install.py 2>&1 | tee -a "$PROVISION_LOG"
                cd - > /dev/null
                log_info "✓ install.py done for ${dir}"
            elif [[ -f "${path}/requirements.txt" ]]; then
                log_info "Installing requirements for ${dir}..."
                set_status_label "Provisioning:pip_${dir}"
                pip install --no-cache-dir -r "${path}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"
                log_info "✓ Requirements installed for ${dir}"
            fi
        fi
    done


}

function provisioning_get_clip_vision() {
    local dir="$1"; shift
    local arr=("$@")
    [[ ${#arr[@]} -eq 0 ]] && return 0
    mkdir -p "$dir"
    for entry in "${arr[@]}"; do
        local url="${entry%%|*}"
        local target="${entry##*|}"
        [[ "$url" == "$target" ]] && target=""  # no pipe = no rename
        provisioning_download_with_retry "$url" "$dir" "$target"
    done
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
