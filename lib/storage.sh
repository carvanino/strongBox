#!/bin/bash
# Storage interface for StrongBox
# Interface contract:
#   storage_put   PATH VALUE          → 0 on success
#   storage_get   PATH               → prints value, 0 on success, 1 if not found
#   storage_delete PATH              → 0 on success
#   storage_list  PREFIX             → prints matching paths, one per line
#   storage_put_version PATH VALUE   → 0 on success, prints new version number
#   storage_get_version PATH VERSION → prints value at that version
#   storage_latest_version PATH      → prints latest version number

STORAGE_DIR="${STORAGE_DIR:-/data/secrets}"

storage_init() {
    mkdir -p "$STORAGE_DIR"
}

storage_put() {
    local path="$1"
    local value="$2"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    mkdir -p "$STORAGE_DIR"
    echo "$value" > "$STORAGE_DIR/${safe_path}"
    return 0
}

storage_get() {
    local path="$1"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    if [[ -f "$STORAGE_DIR/${safe_path}" ]]; then
        cat "$STORAGE_DIR/${safe_path}"
        return 0
    fi
    return 1
}

storage_delete() {
    local path="$1"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    rm -f "$STORAGE_DIR/${safe_path}"
    rm -f "$STORAGE_DIR/${safe_path}".v*
    return 0
}

storage_list() {
    local prefix="$1"
    local safe_prefix
    safe_prefix=$(echo "$prefix" | tr '/' '_')
    find "$STORAGE_DIR" -name "${safe_prefix}*" -type f 2>/dev/null | \
        sed "s|$STORAGE_DIR/||" | tr '_' '/'
}

storage_put_version() {
    local path="$1"
    local value="$2"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    
    mkdir -p "$STORAGE_DIR"
    
    local version=1
    if [[ -f "$STORAGE_DIR/${safe_path}.meta" ]]; then
        version=$(cat "$STORAGE_DIR/${safe_path}.meta")
        version=$((version + 1))
    fi
    
    echo "$value" > "$STORAGE_DIR/${safe_path}.v${version}"
    echo "$value" > "$STORAGE_DIR/${safe_path}"
    echo "$version" > "$STORAGE_DIR/${safe_path}.meta"
    
    echo "$version"
    return 0
}

storage_get_version() {
    local path="$1"
    local version="$2"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    
    if [[ "$version" == "latest" ]] || [[ -z "$version" ]]; then
        storage_get "$path"
        return $?
    fi
    
    if [[ -f "$STORAGE_DIR/${safe_path}.v${version}" ]]; then
        cat "$STORAGE_DIR/${safe_path}.v${version}"
        return 0
    fi
    return 1
}

storage_latest_version() {
    local path="$1"
    local safe_path
    safe_path=$(echo "$path" | tr '/' '_')
    
    if [[ -f "$STORAGE_DIR/${safe_path}.meta" ]]; then
        cat "$STORAGE_DIR/${safe_path}.meta"
    else
        echo "0"
    fi
}
