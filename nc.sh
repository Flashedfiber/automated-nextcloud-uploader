#!/usr/bin/env bash

# ─────────────────────────────────────────────
#         Nextcloud CLI Uploader Tool
# ─────────────────────────────────────────────

NC_URL="https://files.dataheaven.space"
BASE_DIR="Uploads"
DRY_RUN=0

# ─────────────────────────────────────────────
# Static OTA Variables
# ─────────────────────────────────────────────
MAINTAINER="flashedfiber"
OEM="oneplus"

set -euo pipefail

# ─────────────────────────────────────────────
# Dry-run flag
# ─────────────────────────────────────────────
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then DRY_RUN=1; fi
done

# ─────────────────────────────────────────────
# Load .env if present (Always looks in script dir)
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    PERMS=$(stat -c '%a' "$ENV_FILE")
    if [[ "$PERMS" != "600" ]]; then
        echo "⚠️  Warning: .env permissions are ${PERMS}, recommend: chmod 600 $ENV_FILE" >&2
    fi
    source "$ENV_FILE"
fi

# ─────────────────────────────────────────────
# Setup JSON Directory
# ─────────────────────────────────────────────
JSON_DIR="${SCRIPT_DIR}/ota_jsons"
mkdir -p "$JSON_DIR"

# ─────────────────────────────────────────────
# Simple Banner
# ─────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
GREEN="\033[38;5;46m"
CYAN="\033[38;5;51m"
GRAY="\033[38;5;240m"
YELLOW="\033[38;5;220m"

_nc_banner() {
    echo ""
    echo -e "${GREEN}${BOLD}========================================${RESET}"
    echo -e "${GREEN}${BOLD}     🚀 Nextcloud CLI Uploader 🚀       ${RESET}"
    echo -e "${GREEN}${BOLD}========================================${RESET}"
    echo ""
    echo -e "${GRAY}Server:${RESET} ${CYAN}${NC_URL}${RESET}"

    if [[ -n "${NC_USER:-}" ]]; then
        echo -e "${GRAY}User:${RESET} ${CYAN}${NC_USER}${RESET}"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${GRAY}Mode:${RESET} ${YELLOW}DRY-RUN${RESET}"
    fi
    echo -e "${GRAY}Time:${RESET} ${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo ""
}

if [[ -z "${NC_USER:-}" || -z "${NC_PASS:-}" ]]; then
    _nc_banner
    echo "❌ Nextcloud Uploader: Missing credentials!"
    exit 1
fi

WEBDAV_ROOT="${NC_URL}/remote.php/dav/files/${NC_USER}"
LOG_FILE="${SCRIPT_DIR}/nc_upload.log"

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${NC_USER} | $1 | $2 | $3" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────
# Cache & Helpers (Maintains OTA formatting)
# ─────────────────────────────────────────────
cache_init() {
    echo '{"response": []}' > "$1"
}

cache_add() {
    local FILE="$1" LINK="$2" CACHE_FILE="$3" DEVICE="$4" VERSION="$5" NOTE="$6"
    local FILENAME SIZE_BYTES TIMESTAMP_EPOCH MD5 SHA256

    FILENAME="$(basename "$FILE")"
    SIZE_BYTES=$(stat -c '%s' "$FILE")
    TIMESTAMP_EPOCH=$(date +%s)

    echo -n "🔐 Computing MD5...    "
    MD5=$(md5sum "$FILE" | cut -d' ' -f1)
    echo "$MD5"

    echo -n "🔐 Computing SHA256... "
    SHA256=$(sha256sum "$FILE" | cut -d' ' -f1)
    echo "$SHA256"

    local ENTRY
    ENTRY=$(jq -n \
        --arg filename "$FILENAME" --arg download "$LINK" --arg timestamp "$TIMESTAMP_EPOCH" \
        --arg md5 "$MD5" --arg sha256 "$SHA256" --arg size "$SIZE_BYTES" --arg device "$DEVICE" \
        --arg maintainer "$MAINTAINER" --arg oem "$OEM" --arg version "$VERSION" --arg note "$NOTE" \
        '{ maintainer: $maintainer, oem: $oem, device: $device, filename: $filename, download: $download, timestamp: ($timestamp | tonumber), md5: $md5, sha256: $sha256, size: ($size | tonumber), version: $version, note: $note }')

    local TMP
    TMP=$(mktemp)
    jq --argjson entry "$ENTRY" '.response += [$entry]' "$CACHE_FILE" > "$TMP" && mv "$TMP" "$CACHE_FILE"
}

propfind_status() {
    curl -s -o /dev/null -w "%{http_code}" --connect-timeout 15 --http1.1 -u "${NC_USER}:${NC_PASS}" -X PROPFIND -H "Content-Type: application/xml" -d '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>' "${WEBDAV_ROOT}/$1"
}

mkcol() {
    if [[ $DRY_RUN -eq 1 ]]; then 
        echo "[DRY-RUN] Would create folder: $1"
        return 0
    fi
    curl -s -o /dev/null --connect-timeout 15 --http1.1 -u "${NC_USER}:${NC_PASS}" -X MKCOL "${WEBDAV_ROOT}/$1" || true
    
    if [[ "$(propfind_status "$1")" != "207" ]]; then
        echo "❌ Failed to create folder: $1"
        exit 1
    fi
}

ensure_dir() {
    local DIR_PATH="$1" PARTS=() CURRENT=""
    IFS='/' read -ra PARTS <<< "$DIR_PATH"
    for PART in "${PARTS[@]}"; do
        if [[ -z "$PART" ]]; then
            continue
        fi
        CURRENT="${CURRENT:+${CURRENT}/}${PART}"
        local STATUS
        STATUS=$(propfind_status "$CURRENT")
        if [[ "$STATUS" == "404" ]]; then 
            mkcol "$CURRENT"
            echo "[OK] Created folder: ${CURRENT}"
        elif [[ "$STATUS" != "207" ]]; then 
            echo "❌ Cannot access folder: ${CURRENT}"
            exit 1
        fi
    done
}

get_download_link() {
    local FILE_PATH="$1"
    _extract_url() { echo "$1" | grep -oP '(?<=<url>).*?(?=</url>)'; }

    local RESPONSE
    RESPONSE=$(curl -s --connect-timeout 15 -u "${NC_USER}:${NC_PASS}" -X POST -H "OCS-APIRequest: true" "${NC_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares" --data-urlencode "path=/${FILE_PATH}" --data "shareType=3" --data "permissions=1")
    local URL
    URL=$(_extract_url "$RESPONSE")

    if [[ -z "$URL" ]]; then
        local EXISTING
        EXISTING=$(curl -s --connect-timeout 15 -u "${NC_USER}:${NC_PASS}" -X GET -H "OCS-APIRequest: true" "${NC_URL}/ocs/v2.php/apps/files_sharing/api/v1/shares?path=/${FILE_PATH}&reshares=false")
        URL=$(_extract_url "$EXISTING")
    fi
    
    if [[ -n "$URL" ]]; then
        echo "${URL}/download"
    else
        echo ""
    fi
}

do_upload() {
    local TARGET="$1" FILE="$2" 
    local TMP_HTTP
    TMP_HTTP=$(mktemp)
    
    curl --progress-bar --connect-timeout 30 --http1.1 -u "${NC_USER}:${NC_PASS}" -T "$FILE" -o /dev/null -w "%{http_code}" "$TARGET" > "$TMP_HTTP" || true
    echo ""
    cat "$TMP_HTTP"
    rm -f "$TMP_HTTP"
}

# ─────────────────────────────────────────────
# Interactive Upload Command
# ─────────────────────────────────────────────
interactive_upload() {
    local FILE="$1"
    
    if [[ ! -f "$FILE" ]]; then
        echo "❌ File not found: $FILE" >&2
        exit 1
    fi

    _nc_banner
    
    echo "📦 Target File: $(basename "$FILE")"
    echo "─────────────────────────────────────────"
    
    # 1. Ask for Target Path
    read -rp "📂 Enter Nextcloud destination folder (e.g., Builds/Matrixx/asteroids): " TARGET_PATH
    if [[ -z "$TARGET_PATH" ]]; then
        TARGET_PATH="$BASE_DIR"
    fi
    TARGET_PATH=$(echo "$TARGET_PATH" | sed 's|^/||; s|/$||')

    # 2. Ask for ROM Version
    read -rp "🏷 Enter ROM Version (e.g., 14.0-Official): " ROM_VERSION
    if [[ -z "$ROM_VERSION" ]]; then
        ROM_VERSION="—"
    fi

    # 3. Ask for Custom Note
    read -rp "⚠️ Enter custom note for Telegram (Leave empty for none): " ROM_NOTE

    echo "⚙️ Verifying/Creating directories for: $TARGET_PATH"
    ensure_dir "$TARGET_PATH"

    local FILENAME
    FILENAME="$(basename "$FILE")"
    local TARGET="${WEBDAV_ROOT}/${TARGET_PATH}/${FILENAME}"
    local DEVICE
    DEVICE="$(basename "$TARGET_PATH")"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Auto-upload target: ${FILENAME} → ${TARGET_PATH}" >&2
        return 0
    fi

    echo "🚀 Uploading..."
    local HTTP
    HTTP=$(do_upload "$TARGET" "$FILE")
    
    if [[ "$(propfind_status "${TARGET_PATH}/${FILENAME}")" == "207" ]]; then
        log_action "UPLOAD" "${TARGET_PATH}/${FILENAME}" "SUCCESS"
        local LINK
        LINK=$(get_download_link "${TARGET_PATH}/${FILENAME}")

        if [[ -n "$LINK" ]]; then
            echo "─────────────────────────────────────────"
            echo "✅ ALL DONE! Download Link:"
            echo "🔗 $LINK"
            
            # ─────────────────────────────────────────────
            # Generate Timestamped JSON File
            # ─────────────────────────────────────────────
            local TIME_STAMP
            TIME_STAMP=$(date +%Y%m%d_%H%M%S)
            local CACHE_FILE="${JSON_DIR}/${DEVICE}_${TIME_STAMP}.json"
            
            cache_init "$CACHE_FILE" >/dev/null
            cache_add "$FILE" "$LINK" "$CACHE_FILE" "$DEVICE" "$ROM_VERSION" "$ROM_NOTE" >/dev/null
            
            echo "📄 OTA JSON saved to:"
            echo "   $CACHE_FILE"
            echo "─────────────────────────────────────────"
        else
            echo "❌ Share Link Generation Failed" >&2
            exit 1
        fi

    else
        log_action "UPLOAD" "${TARGET_PATH}/${FILENAME}" "FAILED ($HTTP)"
        echo "❌ Remote upload verification failed (HTTP $HTTP)" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────
# CLI Commands
# ─────────────────────────────────────────────
ARGS=()
for arg in "$@"; do 
    if [[ "$arg" != "--dry-run" ]]; then 
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]:-}"
CMD="${1:-}"

show_help() {
    echo -e "\n❌ Invalid or incomplete command\n\n👉 Available commands:\n"
    echo -e "  Upload:\n    ./nc.sh upload <file>\n"
}

case "$CMD" in
    upload)
        shift
        if [[ -z "${1:-}" ]]; then
            echo "❌ Missing file."
            show_help
            exit 1
        fi
        interactive_upload "$1"
        ;;
    *)
        show_help
        ;;
esac