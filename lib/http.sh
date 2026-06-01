#!/usr/bin/env bash
# StrongBox HTTP routing for Bash modules.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/consensus.sh
source "$SCRIPT_DIR/consensus.sh"

for module in storage crypto auth lease dynamic audit; do
    if [[ -f "$SCRIPT_DIR/$module.sh" ]]; then
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/$module.sh"
    fi
done

HTTP_HOST="${HTTP_HOST:-0.0.0.0}"
HTTP_PORT="${HTTP_PORT:-8200}"
SEALED_FILE="${SEALED_FILE:-/data/sealed}"

http_reason_phrase() {
    case "$1" in
        200) echo "OK" ;;
        201) echo "Created" ;;
        204) echo "No Content" ;;
        307) echo "Temporary Redirect" ;;
        400) echo "Bad Request" ;;
        401) echo "Unauthorized" ;;
        403) echo "Forbidden" ;;
        404) echo "Not Found" ;;
        405) echo "Method Not Allowed" ;;
        501) echo "Not Implemented" ;;
        503) echo "Service Unavailable" ;;
        *) echo "OK" ;;
    esac
}

http_respond() {
    local status="$1"
    local body="${2:-}"
    local extra_headers="${3:-}"
    local reason
    reason=$(http_reason_phrase "$status")

    printf 'HTTP/1.1 %s %s\r\n' "$status" "$reason"
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-store\r\n'
    if [[ -n "$extra_headers" ]]; then
        printf '%b' "$extra_headers"
    fi
    printf 'Content-Length: %s\r\n' "${#body}"
    printf '\r\n'
    printf '%s' "$body"
}

http_no_content() {
    printf 'HTTP/1.1 204 No Content\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'Content-Length: 0\r\n'
    printf '\r\n'
}

json_get() {
    local key="$1"
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
}

http_is_sealed() {
    [[ -f "$SEALED_FILE" ]]
}

http_method_is_write() {
    case "$1" in
        POST|PUT|PATCH|DELETE) return 0 ;;
        *) return 1 ;;
    esac
}

http_consensus_write_guard() {
    local method="$1"
    local path="$2"
    local leader

    http_method_is_write "$method" || return 0

    case "$path" in
        /v1/sys/init|/v1/sys/unseal|/v1/sys/consensus/*) return 0 ;;
    esac

    local guard_output
    guard_output=$(consensus_require_leader_for_write)
    local guard_status=$?
    if [[ "$guard_status" -eq 0 ]]; then
        return 0
    fi
    if [[ "$guard_status" -eq 2 ]]; then
        http_respond 503 "$guard_output"
        return 1
    fi

    leader=$(consensus_get_public_leader || true)
    if [[ -n "$leader" ]]; then
        http_respond 307 '{"error":"not leader"}' "X-Leader-Hint: $leader\r\n"
    else
        http_respond 503 '{"error":"leader unknown"}'
    fi
    return 1
}

http_auth_guard() {
    local method="$1"
    local path="$2"
    local token="$3"

    case "$path" in
        /v1/sys/health|/v1/sys/init|/v1/sys/unseal|/v1/sys/consensus/*|/healthz) return 0 ;;
    esac

    if http_is_sealed; then
        http_respond 503 '{"error":"sealed"}'
        return 1
    fi

    if ! declare -F auth_verify_token >/dev/null 2>&1; then
        return 0
    fi

    if [[ -z "$token" ]] || [[ "$(auth_verify_token "$token")" == "INVALID" ]]; then
        http_respond 401 '{"error":"unauthorized"}'
        return 1
    fi

    if declare -F auth_check_policy >/dev/null 2>&1; then
        local capability="read"
        case "$method" in
            PUT|POST|PATCH) capability="write" ;;
            DELETE) capability="delete" ;;
        esac
        if [[ "$(auth_check_policy "$token" "$path" "$capability")" != "ALLOW" ]]; then
            http_respond 403 '{"error":"forbidden"}'
            return 1
        fi
    fi
}

http_call_or_stub() {
    local fn="$1"
    shift
    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$@"
    else
        http_respond 501 "{\"error\":\"handler not implemented\",\"handler\":\"$fn\"}"
    fi
}

http_maybe_replicate_write() {
    local method="$1"
    local path="$2"
    local body="$3"
    local token="$4"
    local replication_mode="${5:-false}"

    [[ "$replication_mode" == "true" ]] && return 0
    http_method_is_write "$method" || return 0

    case "$path" in
        /v1/sys/init|/v1/sys/unseal|/v1/sys/seal|/v1/sys/consensus/*) return 0 ;;
    esac

    local replication_output
    if ! replication_output=$(consensus_replicate_write "$method" "$path" "$body" "$token"); then
        http_respond 503 "$replication_output"
        return 1
    fi
}

http_route() {
    local method="$1"
    local raw_path="$2"
    local body="$3"
    local auth_header="$4"
    local replication_mode="${5:-false}"
    local path="${raw_path%%\?*}"
    [[ "$path" != "/" ]] && path="${path%/}"
    local query=""
    [[ "$raw_path" == *\?* ]] && query="${raw_path#*\?}"

    local token=""
    if [[ "$auth_header" == Bearer\ * ]]; then
        token="${auth_header#Bearer }"
    fi

    if [[ "$replication_mode" != "true" ]]; then
        if ! http_consensus_write_guard "$method" "$path"; then
            return 0
        fi
    fi

    if ! http_auth_guard "$method" "$path" "$token"; then
        return 0
    fi

    if ! http_maybe_replicate_write "$method" "$path" "$body" "$token" "$replication_mode"; then
        return 0
    fi

    case "$method $path" in
        "GET /healthz")
            http_respond 200 '{"ok":true}'
            ;;
        "GET /v1/sys/health")
            local sealed="false"
            http_is_sealed && sealed="true"
            local leader="null"
            local leader_value
            leader_value=$(consensus_get_leader || true)
            [[ -n "$leader_value" ]] && leader="\"$leader_value\""
            http_respond 200 "{\"sealed\":$sealed,\"leader\":$leader,\"term\":$(consensus_current_term),\"node_id\":\"$NODE_ID\"}"
            ;;
        "POST /v1/sys/consensus/request-vote")
            local candidate_id candidate_addr term last_log_index last_log_term
            candidate_id=$(printf '%s' "$body" | json_get candidate_id)
            candidate_addr=$(printf '%s' "$body" | json_get candidate_addr)
            term=$(printf '%s' "$body" | json_get term)
            last_log_index=$(printf '%s' "$body" | json_get last_log_index)
            last_log_term=$(printf '%s' "$body" | json_get last_log_term)
            http_respond 200 "$(consensus_handle_vote_request "$candidate_id" "$candidate_addr" "$term" "${last_log_index:-0}" "${last_log_term:-0}")"
            ;;
        "POST /v1/sys/consensus/heartbeat")
            local leader_id leader_addr term
            leader_id=$(printf '%s' "$body" | json_get leader_id)
            leader_addr=$(printf '%s' "$body" | json_get leader_addr)
            term=$(printf '%s' "$body" | json_get term)
            http_respond 200 "$(consensus_handle_heartbeat "$leader_id" "$leader_addr" "$term")"
            ;;
        "POST /v1/sys/consensus/replicate")
            local leader_id leader_addr term replicated_method replicated_path replicated_body_b64 replicated_token replicated_body
            leader_id=$(printf '%s' "$body" | json_get leader_id)
            leader_addr=$(printf '%s' "$body" | json_get leader_addr)
            term=$(printf '%s' "$body" | json_get term)
            replicated_method=$(printf '%s' "$body" | json_get method)
            replicated_path=$(printf '%s' "$body" | json_get path)
            replicated_body_b64=$(printf '%s' "$body" | json_get body_b64)
            replicated_token=$(printf '%s' "$body" | json_get token)
            consensus_handle_heartbeat "$leader_id" "$leader_addr" "$term" >/dev/null
            consensus_append_replication_log "$replicated_method" "$replicated_path" "$replicated_body_b64"
            replicated_body=$(printf '%s' "$replicated_body_b64" | base64 -d 2>/dev/null || true)
            http_route "$replicated_method" "$replicated_path" "$replicated_body" "Bearer $replicated_token" true >/dev/null
            consensus_note_write_committed
            http_respond 200 "{\"term\":$(consensus_current_term),\"accepted\":true}"
            ;;
        "POST /v1/sys/init")
            http_call_or_stub handle_sys_init "$body" "$query"
            ;;
        "POST /v1/sys/unseal")
            http_call_or_stub handle_sys_unseal "$body" "$query"
            ;;
        "POST /v1/sys/seal")
            http_call_or_stub handle_sys_seal "$token" "$query"
            ;;
        *)
            case "$path" in
                /v1/secrets/*)
                    local secret_path="${path#/v1/secrets/}"
                    case "$method" in
                        PUT) http_call_or_stub handle_secret_put "$secret_path" "$body" "$token" ;;
                        GET) http_call_or_stub handle_secret_get "$secret_path" "$query" "$token" ;;
                        DELETE) http_call_or_stub handle_secret_delete "$secret_path" "$token" ;;
                        *) http_respond 405 '{"error":"method not allowed"}' ;;
                    esac
                    ;;
                /v1/dynamic-postgres/*)
                    [[ "$method" == "GET" ]] && http_call_or_stub handle_dynamic_postgres_get "${path#/v1/dynamic-postgres/}" "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/auth/login)
                    [[ "$method" == "POST" ]] && http_call_or_stub handle_auth_login "$body" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/auth/revoke)
                    [[ "$method" == "POST" ]] && http_call_or_stub handle_auth_revoke "$body" "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/auth/self)
                    [[ "$method" == "GET" ]] && http_call_or_stub handle_auth_self "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/policies/*)
                    local policy_name="${path#/v1/policies/}"
                    case "$method" in
                        PUT) http_call_or_stub handle_policy_put "$policy_name" "$body" "$token" ;;
                        GET) http_call_or_stub handle_policy_get "$policy_name" "$token" ;;
                        *) http_respond 405 '{"error":"method not allowed"}' ;;
                    esac
                    ;;
                /v1/leases/*/renew)
                    [[ "$method" == "POST" ]] && http_call_or_stub handle_lease_renew "$(basename "$(dirname "$path")")" "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/leases/*/revoke)
                    [[ "$method" == "POST" ]] && http_call_or_stub handle_lease_revoke "$(basename "$(dirname "$path")")" "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                /v1/audit)
                    [[ "$method" == "GET" ]] && http_call_or_stub handle_audit_query "$query" "$token" || http_respond 405 '{"error":"method not allowed"}'
                    ;;
                *)
                    http_respond 404 '{"error":"not found"}'
                    ;;
            esac
            ;;
    esac
}

http_handle_connection() {
    local request_line method target version line content_length=0 auth_header="" body=""

    IFS=$'\r' read -r request_line || return 0
    request_line="${request_line//$'\r'/}"
    method="${request_line%% *}"
    target="${request_line#* }"
    target="${target%% *}"
    version="${request_line##* }"

    while IFS=$'\r' read -r line; do
        line="${line//$'\r'/}"
        [[ -z "$line" ]] && break
        case "${line,,}" in
            content-length:*) content_length="${line#*: }" ;;
            authorization:*) auth_header="${line#*: }" ;;
        esac
    done

    if [[ "$content_length" =~ ^[0-9]+$ && "$content_length" -gt 0 ]]; then
        IFS= read -r -N "$content_length" body || true
    fi

    if [[ "$version" != HTTP/* || -z "$method" || -z "$target" ]]; then
        http_respond 400 '{"error":"bad request"}'
        return 0
    fi

    http_route "$method" "$target" "$body" "$auth_header"
}

http_serve() {
    consensus_start_background
    touch "$SEALED_FILE"
    echo "StrongBox node $NODE_ID listening on $HTTP_HOST:$HTTP_PORT" >&2

    if command -v ncat >/dev/null 2>&1; then
        while true; do
            ncat -l "$HTTP_HOST" "$HTTP_PORT" -k -c "bash -lc 'source \"$SCRIPT_DIR/http.sh\"; http_handle_connection'"
        done
    fi

    while true; do
        ncat -l "$HTTP_HOST" "$HTTP_PORT" -c "bash -lc 'source \"$SCRIPT_DIR/http.sh\"; http_handle_connection'"
    done
}
