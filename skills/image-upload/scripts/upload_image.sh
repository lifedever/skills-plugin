#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# image-upload — Upload images to a GitHub repo, serve via jsDelivr CDN.
#
# Configuration (set in your shell profile, e.g. ~/.zshrc):
#   export IMAGE_HOST_REPO="owner/repo"        # required, e.g. "alice/images"
#   export IMAGE_HOST_BRANCH="master"          # optional, default: master
#   export IMAGE_HOST_BASE_DIR="uploads"       # optional, default: uploads
#
# Override per invocation with --repo / --branch / --base-dir.
# ============================================================================

DEFAULT_BRANCH="master"
DEFAULT_BASE_DIR="uploads"
MAX_RETRIES=3

REPO="${IMAGE_HOST_REPO:-}"
BRANCH="${IMAGE_HOST_BRANCH:-$DEFAULT_BRANCH}"
BASE_DIR="${IMAGE_HOST_BASE_DIR:-$DEFAULT_BASE_DIR}"

print_help() {
    cat <<EOF
image-upload — upload images to GitHub, get jsDelivr CDN links.

Usage:
  upload_image.sh [--copy <format>] [--repo <owner/repo>] [--branch <name>] [--base-dir <path>] <file1> [file2] ...
  upload_image.sh [--copy <format>] [--repo ...] [--branch ...] [--base-dir ...] --clipboard
  upload_image.sh --help

Options:
  --copy <jsdelivr|raw|markdown>   Auto-copy this URL format to clipboard (skip interactive prompt)
  --clipboard                      Read image from clipboard (screenshot or Finder-copied files)
  --repo <owner/repo>              Override IMAGE_HOST_REPO for this run
  --branch <name>                  Override IMAGE_HOST_BRANCH for this run
  --base-dir <path>                Override IMAGE_HOST_BASE_DIR for this run
  --help                           Show this help

Environment variables (set in ~/.zshrc or ~/.bashrc):
  IMAGE_HOST_REPO        required, e.g. "alice/images"
  IMAGE_HOST_BRANCH      optional, default: ${DEFAULT_BRANCH}
  IMAGE_HOST_BASE_DIR    optional, default: ${DEFAULT_BASE_DIR}

Prerequisites:
  - gh CLI installed and authenticated (gh auth login)
  - jq installed
  - The repo must exist and you must have write access
  - For clipboard screenshot mode: brew install pngpaste

For each uploaded image, three URLs are printed:
  - jsDelivr CDN  https://cdn.jsdelivr.net/gh/<repo>@<branch>/<path>
  - GitHub Raw    https://raw.githubusercontent.com/<repo>/<branch>/<path>
  - Markdown      ![](jsdelivr_url)
EOF
}

RESULT_DIR="$(mktemp -d /tmp/img-upload-XXXXXX)"
trap 'rm -rf "$RESULT_DIR"' EXIT

upload_single() {
    local file_path="$1"
    local remote_path="$2"
    local result_file="$3"

    if [[ ! -f "$file_path" ]]; then
        echo "Error: File not found: $file_path" >&2
        return 1
    fi

    local ext="${remote_path##*.}"
    local base="${remote_path%.*}"

    local target="$remote_path"
    local counter=0
    while true; do
        local status_code
        status_code="$(gh api "repos/${REPO}/contents/${target}" --silent -i 2>&1 | head -1 | awk '{print $2}')" || true
        if [[ "$status_code" != "200" ]]; then
            break
        fi
        counter=$((counter + 1))
        target="${base}-${counter}.${ext}"
    done

    # Build request body in a file. -f content=$BIG_BASE64 hits ARG_MAX
    # (~1 MB) on >1 MB files. Use jq --rawfile + gh api --input to avoid argv.
    local stem
    stem="$(basename "$result_file" .result)"
    local b64_file="${RESULT_DIR}/${stem}.b64"
    local json_file="${RESULT_DIR}/${stem}.json"
    base64 < "$file_path" | tr -d '\n' > "$b64_file"
    jq -n --rawfile content "$b64_file" \
        --arg msg "upload ${target}" \
        --arg branch "${BRANCH}" \
        '{message: $msg, content: $content, branch: $branch}' > "$json_file"

    echo "Uploading: ${target} ..."

    local attempt=0
    while true; do
        local response
        response="$(gh api --method PUT "repos/${REPO}/contents/${target}" \
            --input "$json_file" \
            -i 2>&1)" || true

        local code
        code="$(echo "$response" | head -1 | awk '{print $2}')"

        if [[ "$code" == "201" || "$code" == "200" ]]; then
            break
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -ge $MAX_RETRIES ]]; then
            echo "Error: Failed to upload ${target} after ${MAX_RETRIES} attempts" >&2
            return 1
        fi
        echo "Retry ${attempt}/${MAX_RETRIES} for ${target} ..."
        sleep "$((attempt))"
    done

    local jsdelivr_url="https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}/${target}"
    local raw_url="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${target}"
    local md_url="![](${jsdelivr_url})"

    echo ""
    echo "jsDelivr:  ${jsdelivr_url}"
    echo "Raw:       ${raw_url}"
    echo "Markdown:  ${md_url}"
    echo ""

    {
        echo "JSDELIVR=${jsdelivr_url}"
        echo "RAW=${raw_url}"
        echo "MD=${md_url}"
    } > "$result_file"
}

handle_clipboard() {
    local finder_files
    finder_files="$(osascript -e '
        try
            set theFiles to (the clipboard as «class furl»)
            return POSIX path of theFiles
        on error
            try
                set theList to paragraphs of (do shell script "osascript -e '\''set theFiles to the clipboard as list
set output to \"\"
repeat with f in theFiles
    set output to output & POSIX path of (f as text) & linefeed
end repeat
return output'\''")
                return theList
            on error
                return ""
            end try
        end try
    ' 2>/dev/null)" || true

    if [[ -n "$finder_files" ]]; then
        local has_files=false
        local clipboard_files=()
        while IFS= read -r line; do
            line="$(echo "$line" | xargs)"
            if [[ -n "$line" && -f "$line" ]]; then
                has_files=true
                clipboard_files+=("$line")
            fi
        done <<< "$finder_files"

        if $has_files; then
            echo "Detected Finder-copied file(s) in clipboard."
            for f in "${clipboard_files[@]}"; do
                FILES_TO_UPLOAD+=("$f")
            done
            return 0
        fi
    fi

    if ! command -v pngpaste &>/dev/null; then
        echo "Error: pngpaste is required for clipboard screenshot mode." >&2
        echo "Install it with: brew install pngpaste" >&2
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp /tmp/clipboard-XXXXXX.png)"

    if ! pngpaste "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        echo "Error: No image data found in clipboard." >&2
        return 1
    fi

    FILES_TO_UPLOAD+=("$tmp_file")
    CLEANUP_FILES+=("$tmp_file")
}

collect_and_copy() {
    local format="$1"
    local urls=()

    for result_file in "$RESULT_DIR"/*.result; do
        [[ -f "$result_file" ]] || continue
        while IFS='=' read -r key value; do
            case "$format" in
                jsdelivr) [[ "$key" == "JSDELIVR" ]] && urls+=("$value") ;;
                raw)      [[ "$key" == "RAW" ]] && urls+=("$value") ;;
                markdown) [[ "$key" == "MD" ]] && urls+=("$value") ;;
            esac
        done < "$result_file"
    done

    if [[ ${#urls[@]} -eq 0 ]]; then
        echo "No results to copy." >&2
        return 1
    fi

    local result
    result="$(printf '%s\n' "${urls[@]}")"
    echo "$result" | pbcopy
    echo "---"
    echo "Copied (${format}):"
    echo "$result"
}

# --- Main ---

COPY_FORMAT=""
ARGS=()
FILES_TO_UPLOAD=()
CLEANUP_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_help
            exit 0
            ;;
        --copy)
            COPY_FORMAT="$2"
            shift 2
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ -z "$REPO" ]]; then
    cat >&2 <<EOF
Error: image hosting repo is not configured.

Set IMAGE_HOST_REPO in your shell profile so the skill knows where to upload:

  echo 'export IMAGE_HOST_REPO="<your-github-username>/images"' >> ~/.zshrc
  source ~/.zshrc

Then make sure the repo exists on GitHub (public preferred so jsDelivr CDN works)
and that you're authenticated:

  gh auth status

Optional env vars:
  IMAGE_HOST_BRANCH     branch to commit to       (default: ${DEFAULT_BRANCH})
  IMAGE_HOST_BASE_DIR   subdirectory inside repo  (default: ${DEFAULT_BASE_DIR})

Or pass them per-invocation:
  upload_image.sh --repo alice/images --branch main file.png

Run 'upload_image.sh --help' for full usage.
EOF
    exit 2
fi

if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not found. Install with: brew install gh" >&2
    exit 2
fi
if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI not authenticated. Run: gh auth login" >&2
    exit 2
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
    print_help
    exit 1
fi

if [[ "${ARGS[0]}" == "--clipboard" ]]; then
    handle_clipboard
else
    FILES_TO_UPLOAD=("${ARGS[@]}")
fi

if [[ ${#FILES_TO_UPLOAD[@]} -eq 0 ]]; then
    echo "No files to upload." >&2
    exit 1
fi

BATCH_TS="$(date +%Y%m%d-%H%M%S)"
YEAR="$(date +%Y)"
MONTH="$(date +%m)"

REMOTE_PATHS=()
for i in "${!FILES_TO_UPLOAD[@]}"; do
    local_file="${FILES_TO_UPLOAD[$i]}"
    ext="${local_file##*.}"
    if [[ ${#FILES_TO_UPLOAD[@]} -eq 1 ]]; then
        new_name="${BATCH_TS}.${ext}"
    else
        new_name="${BATCH_TS}-$((i + 1)).${ext}"
    fi
    REMOTE_PATHS+=("${BASE_DIR}/${YEAR}/${MONTH}/${new_name}")
done

PIDS=()
if [[ ${#FILES_TO_UPLOAD[@]} -eq 1 ]]; then
    upload_single "${FILES_TO_UPLOAD[0]}" "${REMOTE_PATHS[0]}" "$RESULT_DIR/0.result"
else
    for i in "${!FILES_TO_UPLOAD[@]}"; do
        upload_single "${FILES_TO_UPLOAD[$i]}" "${REMOTE_PATHS[$i]}" "$RESULT_DIR/${i}.result" &
        PIDS+=($!)
    done

    FAILED=0
    for pid in "${PIDS[@]}"; do
        if ! wait "$pid"; then
            FAILED=$((FAILED + 1))
        fi
    done

    if [[ $FAILED -gt 0 ]]; then
        echo "Warning: ${FAILED} upload(s) failed." >&2
    fi
fi

for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    rm -f "$f"
done

if [[ -n "$COPY_FORMAT" ]]; then
    collect_and_copy "$COPY_FORMAT"
else
    local_has_results=false
    for f in "$RESULT_DIR"/*.result; do
        [[ -f "$f" ]] && local_has_results=true && break
    done

    if $local_has_results; then
        echo "=== Copy to clipboard ==="
        echo "1) jsDelivr CDN URL"
        echo "2) GitHub Raw URL"
        echo "3) Markdown format"
        echo "4) Skip"
        echo ""
        printf "Choose [1-4]: "
        read -r choice
        case "$choice" in
            1) collect_and_copy "jsdelivr" ;;
            2) collect_and_copy "raw" ;;
            3) collect_and_copy "markdown" ;;
            *) echo "Skipped." ;;
        esac
    fi
fi
