#!/bin/bash

# ==============================================================================
# Script: manage_aware.sh
# Purpose: Unified tool for Syncing, Repairing MKVs, and Docker Deployment.
# ==============================================================================

set -euo pipefail

# --- Configuration: Docker Services ---
readonly SERVICES=(
    "task_prediction:task-pred"
    "instance_pred:instance-pred"
    "screen_recording:screen-recorder"
    "gaze_capture:gaze-capture"
)

# --- Configuration: Logic ---
readonly TIMESTAMP_REGEX="__[0-9]{8}_[0-9]{6}"
readonly DRY_RUN=${DRY_RUN:-false}

# --- Formatting ---
log_info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
log_success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
log_fix()     { echo -e "\033[1;35m[REPAIR]\033[0m $*"; }
log_error()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# --- Load env variables ---
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
else
    log_error "The .env file was not found. Please create one next to this script."
    exit 1
fi

# ==============================================================================
# 1. DATA REPAIR ENGINE
# ==============================================================================

repair_mkv_files() {
    local search_path="$1"
    [[ "$DRY_RUN" == "true" ]] && return
    
    log_info "Scanning for broken MKVs in $search_path..."
    
    # Use FD 3 to avoid stdin conflicts with ffmpeg
    while IFS= read -r -d '' file <&3; do
        
        # Check if file is broken. Redirect stderr to /dev/null to hide the 
        # "File ended prematurely" warning during the check phase.
        if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | grep -qE "^[0-9]"; then
            
            local temp_file="${file}.tmp.mkv"
            log_fix "Standardizing headers: $(basename "$file")"
            
            # -nostdin is vital to prevent the loop from breaking
            if ffmpeg -nostdin -loglevel error -y -i "$file" -c copy -f matroska "$temp_file"; then
                if [[ -s "$temp_file" ]]; then
                    mv "$temp_file" "$file"
                else
                    rm -f "$temp_file"
                fi
            else
                log_error "Failed to repair $file"
                rm -f "$temp_file"
            fi
        fi
    done 3< <(find "$search_path" -type f -name "*.mkv" -print0)
}

# ==============================================================================
# 2. SYNC ENGINE
# ==============================================================================

run_sync() {
    local label="$1" host="$2" src="$3" dest="$4"; shift 4
    log_info "Syncing $label..."
    mkdir -p "$dest"
    
    local opts=("-avzPr" "--ignore-existing")
    [[ "$DRY_RUN" == "true" ]] && opts+=("--dry-run")
    
    rsync "${opts[@]}" "$@" "$host:$src/" "$dest/"
}

# ==============================================================================
# 3. DEPLOY ENGINE
# ==============================================================================

build_containers() {
    log_info "Starting Local Docker Build..."
    for service in "${SERVICES[@]}"; do
        IFS=":" read -r s_dir s_tag <<< "$service"
        [[ ! -d "$s_dir" ]] && continue

        log_info "Building: $s_tag"
        (
            cd "$s_dir"
            docker build --platform linux/amd64 -t "$s_tag:latest" .
        )
    done
}

deploy_containers() {
    log_info "Starting Docker Transfer to $POLARIS_HOST..."
    for service in "${SERVICES[@]}"; do
        IFS=":" read -r s_dir s_tag <<< "$service"
        [[ ! -d "$s_dir" ]] && continue

        log_info "Streaming to remote: $s_tag"
        docker save "$s_tag:latest" | ssh "$POLARIS_HOST" "docker load"
    done
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    local action=${1:-"all"}
    local start_time=$SECONDS

    CLEAN_LIST=$(mktemp)
    ABORTED_LIST=$(mktemp)
    trap 'rm -f "$CLEAN_LIST" "$ABORTED_LIST"' EXIT

    case "$action" in
        "sync")
            # --- Orion ---
            run_sync "Orion DBs" "$ORION_HOST" "$ORION_SRC_PATH" "$ORION_SAVE_PATH" --include="*/" --include="*.db" --exclude="*"

            # --- Polaris ---
            log_info "Querying Polaris ($POLARIS_HOST)..."
            local remote_dirs
            # Filter to ensure we only get the directory names, ignoring terminal noise
            remote_dirs=$(ssh -q "$POLARIS_HOST" "find '$POLARIS_RUNS_SRC_PATH' -maxdepth 1 -mindepth 1 -type d -not -name '.calibrations' -printf '%f\n'" | grep -E '^[0-9]' || true)
            
            if [[ -n "$remote_dirs" ]]; then
                while read -r dir; do
                    [[ -z "$dir" ]] && continue
                    [[ "$dir" =~ $TIMESTAMP_REGEX ]] && echo "$dir" >> "$ABORTED_LIST" || echo "$dir" >> "$CLEAN_LIST"
                done <<< "$remote_dirs"

                [[ -s "$CLEAN_LIST" ]] && run_sync "Polaris Successes" "$POLARIS_HOST" "$POLARIS_RUNS_SRC_PATH" "$POLARIS_DEST" --files-from="$CLEAN_LIST"
                [[ -s "$ABORTED_LIST" ]] && run_sync "Polaris Aborted" "$POLARIS_HOST" "$POLARIS_RUNS_SRC_PATH" "$POLARIS_DEST/aborted" --files-from="$ABORTED_LIST"
                
                # Repair MKVs locally after sync
                repair_mkv_files "$POLARIS_DEST"

                # Generated asd_events from db
                source .venv/bin/activate
                python scripts/process_polaris_db.py "$POLARIS_DEST"
            fi
            ;;

        "deploy")
            deploy_containers
            ;;

        "build")
            build_containers
            ;;

        "submodules")
            git submodule update --init --recursive
            ;;

        *)
            echo "Usage: $0 {sync|deploy|build|submodules}"
            exit 1
            ;;
    esac

    log_success "Completed in $(( SECONDS - start_time ))s."
}

main "$@"