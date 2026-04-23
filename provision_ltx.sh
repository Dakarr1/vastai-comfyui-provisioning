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

# ==================== HELPERS ====================

# Safe integer: strips non-digits, defaults to 0. Never causes syntax errors.
function safe_int() { local v="${1//[^0-9]/}"; echo "${v:-0}"; }

# Count lines matching a pattern in a file. Always returns a number, never fails.
function count_lines() { grep -c "$1" "$2" 2>/dev/null | tr -dc '0-9' | grep -qE '^[0-9]+$' && grep -c "$1" "$2" 2>/dev/null || echo 0; }
# Simpler version using wc -l — always succeeds regardless of grep exit code:
function count_matching() { local pat="$1" file="$2"; grep -- "$pat" "$file" 2>/dev/null | wc -l; }

# ==================== LABEL / STATUS ====================

function set_instance_label() {
    local label="$1"
    [[ -z "$VASTAI_API_TOKEN" || -z "$CONTAINER_ID" ]] && return 0
    curl -s -o /dev/null \
        -X PUT \
        "https://console.vast.ai/api/v0/instances/${CONTAINER_ID}/" \
        -H "Authorization: Bearer ${VASTAI_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"label\": \"${label}\"}" 2>/dev/null || true
}

function set_status_label() {
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
    pip install --no-cache-dir "huggingface-hub[cli]" hf_transfer 2>&1 | tee -a "$PROVISION_LOG"
    export HF_HUB_ENABLE_HF_TRANSFER=1
    log_info "✓ pip tools installed"
}

# ==================== TIMEOUT CALCULATION ====================

function calculate_timeout() {
    local gb="$1" mbs="$2"
    gb=$(safe_int "$gb"); [[ $gb -le 0 ]] && gb=1
    mbs=$(safe_int "$mbs"); [[ $mbs -le 0 ]] && mbs=1
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

    # Try HF API first for HF URLs
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
" 2>/dev/null || echo 0)
    fi

    bytes=$(safe_int "$bytes")

    # Fallback: HEAD request Content-Length
    if [[ $bytes -eq 0 ]]; then
        local cl
        cl=$(curl -sI --max-time 10 "$url" 2>/dev/null \
            | grep -i "^content-length:" | tr -dc '0-9' | head -c 20)
        bytes=$(safe_int "$cl")
    fi

    # Final fallback: assume 5GB
    [[ $bytes -le 0 ]] && bytes=5368709120
    echo "$bytes"
}

function get_hf_sha256() {
    # Returns SHA256 hash (no prefix) for a HF file URL. NO log calls.
    local url="$1"
    [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]] || return 0
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
            print(oid.replace('sha256:', ''))
            sys.exit(0)
except: pass
print('')
" 2>/dev/null || echo ""
}

# ==================== INTEGRITY VERIFICATION ====================

function verify_file_integrity() {
    local filepath="$1"
    local expected_sha="${2:-}"

    [[ ! -f "$filepath" ]] && return 1

    local filesize
    filesize=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null || echo 0)
    filesize=$(safe_int "$filesize")

    if [[ $filesize -lt 1048576 ]]; then
        log_warning "File too small (${filesize} bytes): $(basename "$filepath")"
        return 1
    fi

    if [[ -n "$expected_sha" ]]; then
        log_info "Verifying SHA256: $(basename "$filepath")..."
        local actual_sha
        actual_sha=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')
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
import struct, sys
try:
    with open('$filepath','rb') as f:
        n = struct.unpack('<Q', f.read(8))[0]
    print('ok' if 0 < n < 100_000_000 else 'bad')
except:
    print('bad')
" 2>/dev/null || echo "bad")
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
    find "$dir" -name "*.tmp"   -delete 2>/dev/null || true
    find "$dir" -name "*.aria2" -delete 2>/dev/null || true

    local cleaned=0
    while IFS= read -r file; do
        if ! verify_file_integrity "$file" > /dev/null 2>&1; then
            log_warning "Removing corrupted: $(basename "$file")"
            rm -f "$file"
            (( cleaned++ )) || true
        fi
    done < <(find "$dir" -type f \( -name "*.safetensors" -o -name "*.bin" -o -name "*.ckpt" \) 2>/dev/null)

    [[ $cleaned -gt 0 ]] && log_info "Cleaned ${cleaned} corrupted file(s)"
}

# ==================== DOWNLOAD ====================

function download_with_aria2() {
    local url="$1" dir="$2" filename="$3" timeout="$4" auth_token="${5:-}"

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

    [[ "$url" =~ huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+) ]] || return 1
    local repo="${BASH_REMATCH[1]}" rev="${BASH_REMATCH[2]}" file="${BASH_REMATCH[3]}"
    log_info "HF CLI: ${repo}/${file}"

    # Try modern API first (no legacy flags), fall back to old flags if it fails.
    # We don't parse version strings — just try and check the result.
    local ec=1
    HF_HUB_ENABLE_HF_TRANSFER=1 hf download \
        "$repo" "$file" --revision "$rev" \
        --local-dir "$dir" \
        2>&1 | grep -v "FutureWarning" | grep -v "^$" | tee -a "$PROVISION_LOG"
    ec=${PIPESTATUS[0]}

    if [[ $ec -ne 0 ]]; then
        log_info "Modern hf CLI failed, retrying with legacy flags..."
        HF_HUB_ENABLE_HF_TRANSFER=1 hf download \
            "$repo" "$file" --revision "$rev" \
            --local-dir "$dir" \
            --local-dir-use-symlinks False --resume-download \
            2>&1 | grep -v "FutureWarning" | grep -v "^$" | tee -a "$PROVISION_LOG"
        ec=${PIPESTATUS[0]}
    fi

    # hf download may place the file in a subdirectory — find and move it
    local expected="${dir}/${filename}"
    if [[ $ec -eq 0 ]]; then
        if [[ ! -f "$expected" ]]; then
            local found
            found=$(find "$dir" -name "$filename" -type f 2>/dev/null | head -1)
            if [[ -n "$found" && "$found" != "$expected" ]]; then
                mv "$found" "$expected" 2>/dev/null || true
            fi
        fi
        # Clean up empty subdirs left by hf download
        find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        [[ -f "$expected" ]] && return 0
    fi
    return 1
}

function provisioning_download_with_retry() {
    local url="$1" dir="$2" override_name="${3:-}"

    # Derive filename from URL (strip query string), apply override if given
    local filename
    filename=$(basename "$url" | sed 's/?.*//')
    [[ -n "$override_name" ]] && filename="$override_name"
    local filepath="${dir}/${filename}"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "File: ${filename}"
    set_status_label "Downloading:${filename}"

    # Fetch expected SHA256 (HF only)
    local expected_sha=""
    if [[ "$url" =~ huggingface\.co ]]; then
        log_info "Fetching SHA256 from HF API..."
        expected_sha=$(get_hf_sha256 "$url" || echo "")
        if [[ -n "$expected_sha" ]]; then
            log_info "Expected SHA256: ${expected_sha}"
        else
            log_warning "SHA256 not available — will use header check only"
        fi
    fi

    # Skip if already valid
    if [[ -f "$filepath" ]] && verify_file_integrity "$filepath" "$expected_sha"; then
        log_info "✓ Already valid — skipping"
        return 0
    fi
    rm -f "$filepath" "${filepath}.tmp" "${filepath}.aria2"

    local auth_token=""
    [[ -n "$HF_TOKEN"      && "$url" =~ huggingface\.co ]] && auth_token="$HF_TOKEN"
    [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com    ]] && auth_token="$CIVITAI_TOKEN"

    local file_bytes; file_bytes=$(estimate_file_size_bytes "$url")
    file_bytes=$(safe_int "$file_bytes")
    local gb=$(( file_bytes / 1073741824 ))
    [[ $gb -lt 1 ]] && gb=1
    local size_mb=$(( file_bytes / 1048576 ))
    local timeout; timeout=$(calculate_timeout "$gb" 100)
    log_info "Size: ${size_mb}MB (~${gb}GB) | Timeout: ${timeout}s"

    local attempt=1
    local retry_delay=$BASE_RETRY_DELAY
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
            sleep "$retry_delay"
            retry_delay=$(( retry_delay * 2 > MAX_RETRY_DELAY ? MAX_RETRY_DELAY : retry_delay * 2 ))
        fi
        (( attempt++ )) || true
    done

    log_error "❌ FAILED: ${filename}"
    return 1
}

# ==================== API WRAPPER TIMEOUT FIX ====================

function fix_api_wrapper_timeout() {
    local worker="/opt/comfyui-api-wrapper/workers/generation_worker.py"

    if [[ ! -f "$worker" ]]; then
        log_warning "api-wrapper worker not found at ${worker} — skipping timeout fix"
        return 0
    fi

    log_info "Patching api-wrapper WEBSOCKET_MESSAGE_TIMEOUT..."

    # Inject 'import os' after 'import asyncio' if not already present
    if ! grep -q "^import os" "$worker"; then
        sed -i 's/^import asyncio/import asyncio\nimport os/' "$worker"
    fi

    # Replace hardcoded timeout with env var (default 600s)
    sed -i 's/message_timeout = [0-9.]*/message_timeout = float(os.getenv("WEBSOCKET_MESSAGE_TIMEOUT", "600.0"))/' "$worker"

    log_info "Timeout patched — restarting api-wrapper..."

    # Kill existing uvicorn safely (pkill -f is format-agnostic)
    pkill -f "uvicorn" 2>/dev/null || true
    sleep 3

    # Restart on correct port
    cd /opt/comfyui-api-wrapper && .venv/bin/uvicorn main:app --port 8288 &
    log_info "api-wrapper restarted on port 8288 (PID: $!)"
    cd - > /dev/null
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
    supervisorctl reread  > /dev/null 2>&1 || true
    supervisorctl update  > /dev/null 2>&1 || true
    supervisorctl start comfyui-output-server > /dev/null 2>&1 || true
    sleep 2
    supervisorctl status comfyui-output-server 2>/dev/null | grep -q RUNNING \
        && log_info "✅ HTTP server running on port 8081" \
        || log_warning "HTTP server may not have started"
}

# ==================== TUNNEL DISCOVERY + LABEL ====================

function setup_tunnels_and_label() {
    local logfile="/var/log/tunnel_manager.log"
    local cf_log="/tmp/cloudflared_8081.log"

    # ── Step 1: count expected unique ports from PORTAL_CONFIG ────
    local expected_count=0
    if [[ -n "$PORTAL_CONFIG" ]]; then
        expected_count=$(echo "$PORTAL_CONFIG" \
            | tr '|' '\n' \
            | grep -oP 'localhost:\K\d+' \
            | sort -u \
            | wc -l)
        expected_count=$(safe_int "$expected_count")
        log_info "Expecting ${expected_count} tunnel(s) from PORTAL_CONFIG"
    fi
    [[ $expected_count -lt 1 ]] && expected_count=1

    # ── Step 2: wait for tunnel log to accumulate enough URLs ─────
    # We count lines that contain BOTH 'localhost:' AND 'trycloudflare.com'
    # on the same line. This is format-agnostic — works regardless of how
    # tunnel_manager formats the log message around the URL.
    #
    # Stop early when:
    #   a) we have enough (>= expected_count), or
    #   b) count has been stable for 9s and we have at least 1 (CF 429'd the rest)
    # Hard cap: 90s.
    log_info "Waiting for tunnel URLs in log (max 90s)..."
    local waited=0
    local prev_count=-1
    local stable_for=0
    local cur_count=0

    while [[ $waited -lt 90 ]]; do
        # Count UNIQUE ports that have a trycloudflare URL on the same line.
        # Each tunnel produces multiple matching lines (banner + summary),
        # so we must deduplicate by port — not count raw lines.
        cur_count=$(grep 'localhost:' "$logfile" 2>/dev/null \
                    | grep 'trycloudflare\.com' \
                    | grep -oP '(?<=localhost:)\d+' \
                    | sort -u \
                    | wc -l)
        cur_count=$(safe_int "$cur_count")

        if [[ $cur_count -ge $expected_count ]]; then
            log_info "✓ Got ${cur_count}/${expected_count} tunnel lines after ${waited}s"
            break
        fi

        if [[ $cur_count -eq $prev_count ]]; then
            (( stable_for += 3 )) || true
            if [[ $cur_count -gt 0 && $stable_for -ge 9 ]]; then
                log_warning "Stable at ${cur_count}/${expected_count} for 9s — CF likely 429'd rest, proceeding"
                break
            fi
        else
            stable_for=0
        fi

        log_info "Tunnel lines: ${cur_count}/${expected_count} — waiting... (${waited}s)"
        prev_count=$cur_count
        sleep 3
        (( waited += 3 )) || true
    done

    # Final read — unique ports
    cur_count=$(grep 'localhost:' "$logfile" 2>/dev/null \
                | grep 'trycloudflare\.com' \
                | grep -oP '(?<=localhost:)\d+' \
                | sort -u \
                | wc -l)
    cur_count=$(safe_int "$cur_count")
    log_info "Proceeding with ${cur_count} unique tunnel port(s) in log"

    # ── Step 3: extract port:url pairs ───────────────────────────
    # For each line that has both localhost:PORT and a trycloudflare URL,
    # extract them independently. We do NOT match on the surrounding text
    # so log format changes don't matter.
    local tunnels=""
    local seen_ports=""

    while IFS= read -r line; do
        # Extract the port number after 'localhost:'
        local port
        port=$(echo "$line" | grep -oP '(?<=localhost:)\d+' | head -1)
        # Extract the trycloudflare URL
        local url
        url=$(echo "$line" | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1)

        port=$(safe_int "$port")
        [[ $port -eq 0 ]] && continue
        [[ -z "$url" ]] && continue

        # Deduplicate by port
        if [[ "$seen_ports" != *"|${port}|"* ]]; then
            seen_ports="${seen_ports}|${port}|"
            [[ -n "$tunnels" ]] && tunnels="${tunnels},"
            tunnels="${tunnels}${port}:${url}"
            log_info "✓ Tunnel: ${port} → ${url}"
        fi
    done < <(grep 'localhost:' "$logfile" 2>/dev/null | grep 'trycloudflare\.com')

    # ── Step 4: our own cloudflared for port 8081 ─────────────────
    log_info "Starting cloudflared tunnel for port 8081..."
    rm -f "$cf_log"
    cloudflared tunnel --url http://localhost:8081 > "$cf_log" 2>&1 &
    local cf_pid=$!
    log_info "cloudflared PID: ${cf_pid}"

    local cf_url=""
    local i=0
    while [[ $i -lt 20 ]]; do
        cf_url=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$cf_log" 2>/dev/null | head -1)
        if [[ -n "$cf_url" ]]; then
            log_info "✓ cloudflared 8081 tunnel: ${cf_url}"
            [[ -n "$tunnels" ]] && tunnels="${tunnels},"
            tunnels="${tunnels}8081:${cf_url}"
            break
        fi
        # Detect fast failure (429 / timeout / error)
        if grep -qE '429|Too Many Requests|failed to request|context deadline exceeded' "$cf_log" 2>/dev/null; then
            log_warning "cloudflared 8081 failed (rate-limited or timeout) — skipping"
            kill "$cf_pid" 2>/dev/null || true
            cf_pid=""
            break
        fi
        sleep 2
        (( i++ )) || true
    done

    if [[ -z "$cf_url" && -n "$cf_pid" ]]; then
        log_warning "cloudflared 8081 timed out — killing"
        kill "$cf_pid" 2>/dev/null || true
    fi

    # ── Step 5: set label ─────────────────────────────────────────
    TUNNEL_LABEL_PART="$tunnels"

    if [[ -n "$tunnels" ]]; then
        set_status_label "Provisioning:started"
        log_info "✓ Label set: ${tunnels}"
    else
        log_warning "No tunnel URLs found — setting label without tunnels"
        set_status_label "Provisioning:started"
    fi
}

# ==================== COMFYUI VERSION CHECK + UPDATE ====================

function update_comfyui_if_needed() {
    local required_major=0 required_minor=17 required_patch=1
    local version_file="${COMFYUI_DIR}/comfyui_version.py"

    # ── Read current version ──────────────────────────────────────
    if [[ ! -f "$version_file" ]]; then
        log_warning "comfyui_version.py not found at ${COMFYUI_DIR} — skipping update check"
        return 0
    fi

    local version
    version=$(python3 - "$version_file" << 'PYEOF_INNER'
import sys, re
try:
    with open(sys.argv[1]) as f:
        txt = f.read()
    # Match: __version__ = "0.17.1" or version = "0.17.1" etc.
    m = re.search(r'["\x27]([0-9]+\.[0-9]+\.?[0-9]*)["\x27]', txt)
    print(m.group(1) if m else '')
except:
    print('')
PYEOF_INNER
)

    if [[ -z "$version" ]]; then
        # Fallback: try git log — vastai/comfy embeds version in commit message
        version=$(git -C "${COMFYUI_DIR}" log -1 --oneline 2>/dev/null \
                  | grep -oP '[0-9]+\.[0-9]+\.?[0-9]*' | head -1)
    fi

    if [[ -z "$version" ]]; then
        log_warning "Cannot determine ComfyUI version — skipping update check"
        return 0
    fi
    log_info "ComfyUI version: ${version}"

    # ── Compare versions ──────────────────────────────────────────
    local cur_major cur_minor cur_patch
    IFS='.' read -r cur_major cur_minor cur_patch <<< "$version"
    cur_major=$(safe_int "$cur_major")
    cur_minor=$(safe_int "$cur_minor")
    cur_patch=$(safe_int "${cur_patch:-0}")

    local needs_update=false
    if   [[ $cur_major -lt $required_major ]]; then needs_update=true
    elif [[ $cur_major -eq $required_major && $cur_minor -lt $required_minor ]]; then needs_update=true
    elif [[ $cur_major -eq $required_major && $cur_minor -eq $required_minor && $cur_patch -lt $required_patch ]]; then needs_update=true
    fi

    if [[ "$needs_update" == "false" ]]; then
        log_info "✓ ComfyUI ${version} >= ${required_major}.${required_minor}.${required_patch} — no update needed"
        return 0
    fi

    log_info "ComfyUI ${version} < ${required_major}.${required_minor}.${required_patch} — updating..."

    # ── Git update ────────────────────────────────────────────────
    if [[ ! -d "${COMFYUI_DIR}/.git" ]]; then
        log_warning "COMFYUI_DIR is not a git repo — cannot update"
        return 0
    fi

    # Fetch latest, then reset --hard to avoid dirty-tree failures
    local default_branch
    default_branch=$(git -C "${COMFYUI_DIR}" remote show origin 2>/dev/null \
                     | grep 'HEAD branch' | awk '{print $NF}')
    [[ -z "$default_branch" ]] && default_branch="master"
    log_info "Updating branch: ${default_branch}"

    git -C "${COMFYUI_DIR}" fetch --all --tags 2>&1 | tee -a "$PROVISION_LOG"
    git -C "${COMFYUI_DIR}" reset --hard "origin/${default_branch}" 2>&1 | tee -a "$PROVISION_LOG"

    # Re-install requirements after update
    log_info "Reinstalling ComfyUI requirements..."
    pip install -r "${COMFYUI_DIR}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"

    # ── Verify update ─────────────────────────────────────────────
    local new_version
    new_version=$(python3 - "$version_file" << 'PYEOF_INNER'
import sys, re
try:
    with open(sys.argv[1]) as f:
        txt = f.read()
    m = re.search(r'["\x27]([0-9]+\.[0-9]+\.?[0-9]*)["\x27]', txt)
    print(m.group(1) if m else 'unknown')
except:
    print('unknown')
PYEOF_INNER
)
    log_info "✓ ComfyUI updated: ${version} → ${new_version}"
}

# ==================== CLEANUP UNWANTED AUTO-INSTALLED MODELS ====================

function remove_unwanted_models() {
    local checkpoints_dir="${COMFYUI_DIR}/models/checkpoints"
    log_info "Removing unwanted auto-installed models..."

    local patterns=(
        "*v1-5*pruned*emaonly*"
        "*v1.5*pruned*emaonly*"
        "*sd-v1-5*"
    )
    local removed=0
    for pat in "${patterns[@]}"; do
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            log_info "Removing unwanted model: $(basename "$f")"
            rm -f "$f"
            (( removed++ )) || true
        done < <(find "$checkpoints_dir" -maxdepth 1 -iname "$pat" -type f 2>/dev/null)
    done

    if [[ $removed -eq 0 ]]; then
        log_info "No unwanted models found"
    else
        log_info "Removed ${removed} unwanted model(s)"
    fi
}

# ==================== PACKAGE DEFINITIONS ====================

APT_PACKAGES=(
    "ffmpeg"
    "portaudio19-dev"   # required by sounddevice (TTS-Audio-Suite)
)

PIP_PACKAGES=(
    "transformers==4.57.3"
)

NODES=(
    "https://github.com/diodiogod/TTS-Audio-Suite"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts"
    "https://github.com/melMass/comfy_mtb"
    "https://github.com/Lightricks/ComfyUI-LTXVideo"
    "https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes"
)

CHECKPOINT_MODELS=(
    # LTX-2.3 audio VAE (goes in checkpoints per Lightricks convention)
    "https://huggingface.co/vantagewithai/LTX-2.3-Split/resolve/main/audio_vae/ltx-2-3-22b-audio_vae.safetensors"
)
UNET_MODELS=()

LORA_MODELS=(
    # LTX-2.3 distilled lora
    "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384.safetensors"
    # LTX-2.3 transition lora
    "https://huggingface.co/vantagewithai/LTX-2.3-Split/resolve/main/loras/ltx2.3-transition.safetensors"
    # Slimey character lora (private repo — requires HF_TOKEN)
    "https://huggingface.co/Eldaroo/slimey-lora/resolve/main/slimey_lora_v1_copy.safetensors"
)

CLIP_VISION_MODELS=()

VAE_MODELS=(
    # LTX-2.3 VAE
    "https://huggingface.co/vantagewithai/LTX-2.3-Split/resolve/main/vae/ltx-2-3-22b-VAE.safetensors"
    # Z-Image VAE
    "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/vae/ae.safetensors"
)

TEXT_ENCODER_MODELS=(
    # LTX-2.3 text encoders
    "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it.safetensors"
    "https://huggingface.co/vantagewithai/LTX-2.3-Split/resolve/main/text_encoder/ltx-2-3-22b-text_encoder.safetensors"
    # Z-Image text encoder
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors"
)

DIFFUSION_MODELS=(
    # LTX-2.3 transformer (fp8 scaled)
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/diffusion_models/ltx-2.3-22b-dev_transformer_only_fp8_scaled.safetensors"
    # Z-Image diffusion model
    "https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files/diffusion_models/z_image_bf16.safetensors"
)

ESRGAN_MODELS=()

CONTROLNET_MODELS=()
LATENT_UPSCALE_MODELS=(
    # LTX-2.3 spatial upscaler v1.1
    "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
)
WORKFLOWS=()

# ==================== MAIN ====================

function provisioning_start() {
    log_info "=========================================="
    log_info "  PROVISIONING START"
    log_info "=========================================="

    install_download_tools

    update_comfyui_if_needed
    remove_unwanted_models

    setup_output_http_server
    fix_api_wrapper_timeout
    setup_tunnels_and_label   # sets TUNNEL_LABEL_PART + first label

    set_status_label "Provisioning:apt_packages"
    provisioning_get_apt_packages

    set_status_label "Provisioning:cloning_nodes"
    provisioning_get_nodes

    set_status_label "Provisioning:pip_packages"
    provisioning_get_pip_packages

    set_status_label "Provisioning:checkpoints"
    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints"      "${CHECKPOINT_MODELS[@]}"

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

    set_status_label "Provisioning:latent_upscale_models"
    provisioning_get_files "${COMFYUI_DIR}/models/latent_upscale_models"           "${LATENT_UPSCALE_MODELS[@]}"

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

            set_status_label "Provisioning:pip_${dir}"
            if [[ -f "${path}/install.py" ]]; then
                log_info "Running install.py for ${dir}..."
                # Use subshell so cd doesn't affect parent shell
                ( cd "${path}" && python install.py 2>&1 | tee -a "$PROVISION_LOG" )
                log_info "✓ install.py done for ${dir}"
            elif [[ -f "${path}/requirements.txt" ]]; then
                log_info "Installing requirements for ${dir}..."
                pip install --no-cache-dir -r "${path}/requirements.txt" 2>&1 | tee -a "$PROVISION_LOG"
                log_info "✓ Requirements installed for ${dir}"
            else
                log_info "No install.py or requirements.txt for ${dir} — skipping pip"
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
        # Format: "url|target_filename" or just "url"
        local url="${entry%%|*}"
        local target="${entry##*|}"
        [[ "$url" == "$target" ]] && target=""   # no pipe separator = no rename
        provisioning_download_with_retry "$url" "$dir" "$target"
    done
}

function provisioning_get_files() {
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
