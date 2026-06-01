#!/usr/bin/env bash
# StrongBox hand-rolled, Raft-inspired consensus helpers.
#
# This module keeps local node state on disk and talks to peers through the
# internal HTTP endpoints implemented in lib/http.sh. It intentionally exposes a
# small shell interface so other modules only need to ask "am I leader?" before
# accepting writes.

set -uo pipefail

NODE_ID="${NODE_ID:-node1}"
NODE_ADDR="${NODE_ADDR:-http://127.0.0.1:8200}"
PUBLIC_NODE_ADDR="${PUBLIC_NODE_ADDR:-$NODE_ADDR}"
PEERS="${PEERS:-}"
CONSENSUS_DIR="${CONSENSUS_DIR:-/data/consensus}"
CONSENSUS_HEARTBEAT_MS="${CONSENSUS_HEARTBEAT_MS:-250}"
CONSENSUS_ELECTION_MIN_MS="${CONSENSUS_ELECTION_MIN_MS:-900}"
CONSENSUS_ELECTION_MAX_MS="${CONSENSUS_ELECTION_MAX_MS:-1600}"

consensus_init() {
    mkdir -p "$CONSENSUS_DIR"
    : "${CONSENSUS_STATE_FILE:=$CONSENSUS_DIR/state.env}"

    if [[ -z "${CONSENSUS_RANDOM_SEEDED:-}" ]]; then
        local seed
        seed=$(printf '%s:%s:%s' "$NODE_ID" "$$" "$(date +%s%N)" | cksum | awk '{print $1}')
        RANDOM=$((seed % 32768))
        CONSENSUS_RANDOM_SEEDED=1
    fi

    if [[ ! -f "$CONSENSUS_STATE_FILE" ]]; then
        local initial_state="follower"
        local initial_leader="node1"
        local initial_leader_addr="http://strongbox-1:8200"
        local initial_vote=""

        if [[ "$NODE_ID" == "node1" ]]; then
            initial_state="leader"
            initial_vote="node1"
        fi

        cat > "$CONSENSUS_STATE_FILE" <<EOF
current_term=1
voted_for=$initial_vote
state=$initial_state
leader_id=$initial_leader
leader_addr=$initial_leader_addr
last_heartbeat_ms=$(consensus_now_ms)
last_log_index=0
last_log_term=0
EOF
    fi
}

consensus_now_ms() {
    date +%s%3N
}

consensus_sleep_ms() {
    local ms="$1"
    sleep "$(awk "BEGIN { printf \"%.3f\", $ms / 1000 }")"
}

consensus_random_timeout_ms() {
    local spread=$((CONSENSUS_ELECTION_MAX_MS - CONSENSUS_ELECTION_MIN_MS + 1))
    echo $((CONSENSUS_ELECTION_MIN_MS + (RANDOM % spread)))
}

consensus_load() {
    consensus_init
    # shellcheck disable=SC1090
    source "$CONSENSUS_STATE_FILE"
}

consensus_save() {
    local term="$1" vote="$2" node_state="$3" leader="$4" leader_addr_arg="$5" heartbeat="$6" log_index="$7" log_term="$8"
    local tmp_file
    mkdir -p "${CONSENSUS_DIR:-/data/consensus}"
    CONSENSUS_STATE_FILE="${CONSENSUS_STATE_FILE:-${CONSENSUS_DIR:-/data/consensus}/state.env}"
    tmp_file="${CONSENSUS_STATE_FILE}.$$.$RANDOM.tmp"
    cat > "$tmp_file" <<EOF
current_term=$term
voted_for=$vote
state=$node_state
leader_id=$leader
leader_addr=$leader_addr_arg
last_heartbeat_ms=$heartbeat
last_log_index=$log_index
last_log_term=$log_term
EOF
    mv "$tmp_file" "$CONSENSUS_STATE_FILE"
}

consensus_peer_count() {
    local count=1
    local peer
    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -n "$peer" ]] && count=$((count + 1))
    done
    echo "$count"
}

consensus_quorum_size() {
    local total
    total=$(consensus_peer_count)
    echo $((total / 2 + 1))
}

consensus_for_each_peer() {
    local callback="$1"
    local peer peer_id peer_addr

    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_id="${peer%%=*}"
        peer_addr="${peer#*=}"
        "$callback" "$peer_id" "$peer_addr"
    done
}

consensus_current_term() {
    consensus_load
    echo "$current_term"
}

consensus_get_leader() {
    consensus_load
    if [[ -n "${leader_id:-}" && -n "${leader_addr:-}" ]]; then
        echo "$leader_id:$leader_addr"
        return 0
    fi
    return 1
}

consensus_get_public_leader() {
    consensus_load
    if [[ -n "${leader_id:-}" ]]; then
        if [[ "$leader_id" == "$NODE_ID" ]]; then
            echo "$leader_id:$PUBLIC_NODE_ADDR"
            return 0
        fi

        local peer peer_id peer_addr
        IFS=',' read -ra peer_items <<< "$PEERS"
        for peer in "${peer_items[@]}"; do
            [[ -z "$peer" ]] && continue
            peer_id="${peer%%=*}"
            peer_addr="${peer#*=}"
            if [[ "$peer_id" == "$leader_id" ]]; then
                echo "$leader_id:$PUBLIC_NODE_ADDR"
                return 0
            fi
        done
    fi
    consensus_get_leader
}

consensus_is_leader() {
    consensus_load
    [[ "${state:-follower}" == "leader" ]]
}

consensus_has_quorum() {
    local reachable=1
    local quorum
    quorum=$(consensus_quorum_size)

    local peer peer_addr
    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_addr="${peer#*=}"
        if curl -fsS --max-time 1 "$peer_addr/v1/sys/health" >/dev/null 2>&1; then
            reachable=$((reachable + 1))
        fi
    done

    [[ "$reachable" -ge "$quorum" ]]
}

consensus_log_is_up_to_date() {
    local candidate_log_index="$1"
    local candidate_log_term="$2"

    if [[ "$candidate_log_term" -gt "${last_log_term:-0}" ]]; then
        return 0
    fi
    if [[ "$candidate_log_term" -eq "${last_log_term:-0}" && "$candidate_log_index" -ge "${last_log_index:-0}" ]]; then
        return 0
    fi
    return 1
}

consensus_handle_vote_request() {
    local candidate_id="$1"
    local candidate_addr="$2"
    local request_term="$3"
    local candidate_log_index="${4:-0}"
    local candidate_log_term="${5:-0}"

    consensus_load

    if [[ "$request_term" -lt "$current_term" ]]; then
        printf '{"term":%s,"vote_granted":false}\n' "$current_term"
        return 0
    fi

    if [[ "$request_term" -gt "$current_term" ]]; then
        current_term="$request_term"
        voted_for=""
        state="follower"
        leader_id=""
        leader_addr=""
    fi

    if [[ -z "${voted_for:-}" || "$voted_for" == "$candidate_id" ]]; then
        if consensus_log_is_up_to_date "$candidate_log_index" "$candidate_log_term"; then
            voted_for="$candidate_id"
            last_heartbeat_ms=$(consensus_now_ms)
            consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$last_heartbeat_ms" "${last_log_index:-0}" "${last_log_term:-0}"
            printf '{"term":%s,"vote_granted":true}\n' "$current_term"
            return 0
        fi
    fi

    consensus_save "$current_term" "${voted_for:-}" "$state" "$leader_id" "$leader_addr" "${last_heartbeat_ms:-0}" "${last_log_index:-0}" "${last_log_term:-0}"
    printf '{"term":%s,"vote_granted":false}\n' "$current_term"
}

consensus_handle_heartbeat() {
    local leader="$1"
    local leader_http_addr="$2"
    local leader_term="$3"

    consensus_load

    if [[ "$leader_term" -lt "$current_term" ]]; then
        printf '{"term":%s,"accepted":false}\n' "$current_term"
        return 0
    fi

    current_term="$leader_term"
    state="follower"
    leader_id="$leader"
    leader_addr="$leader_http_addr"
    last_heartbeat_ms=$(consensus_now_ms)
    consensus_save "$current_term" "${voted_for:-}" "$state" "$leader_id" "$leader_addr" "$last_heartbeat_ms" "${last_log_index:-0}" "${last_log_term:-0}"
    printf '{"term":%s,"accepted":true}\n' "$current_term"
}

consensus_request_vote_from_peer() {
    local peer_id="$1"
    local peer_addr="$2"
    local response granted response_term

    response=$(curl -fsS --max-time 1 \
        -X POST "$peer_addr/v1/sys/consensus/request-vote" \
        -H 'Content-Type: application/json' \
        -d "{\"candidate_id\":\"$NODE_ID\",\"candidate_addr\":\"$NODE_ADDR\",\"term\":$current_term,\"last_log_index\":${last_log_index:-0},\"last_log_term\":${last_log_term:-0}}" 2>/dev/null) || return 1

    granted=$(printf '%s' "$response" | sed -n 's/.*"vote_granted":\([^,}]*\).*/\1/p')
    response_term=$(printf '%s' "$response" | sed -n 's/.*"term":\([0-9]*\).*/\1/p')

    if [[ -n "$response_term" && "$response_term" -gt "$current_term" ]]; then
        current_term="$response_term"
        state="follower"
        voted_for=""
        leader_id=""
        leader_addr=""
        consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
        return 1
    fi

    [[ "$granted" == "true" ]]
}

consensus_start_election() {
    consensus_load
    current_term=$((current_term + 1))
    state="candidate"
    voted_for="$NODE_ID"
    leader_id=""
    leader_addr=""
    local votes=1
    local quorum
    quorum=$(consensus_quorum_size)
    consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"

    local peer peer_id peer_addr
    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_id="${peer%%=*}"
        peer_addr="${peer#*=}"
        if consensus_request_vote_from_peer "$peer_id" "$peer_addr"; then
            votes=$((votes + 1))
        fi
    done

    consensus_load
    if [[ "$votes" -ge "$quorum" && "$state" == "candidate" ]]; then
        state="leader"
        leader_id="$NODE_ID"
        leader_addr="$NODE_ADDR"
        consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
        return 0
    fi

    state="follower"
    consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
    return 1
}

consensus_send_heartbeats() {
    consensus_load
    [[ "$state" == "leader" ]] || return 0

    local peer peer_addr
    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_addr="${peer#*=}"
        curl -fsS --max-time 1 \
            -X POST "$peer_addr/v1/sys/consensus/heartbeat" \
            -H 'Content-Type: application/json' \
            -d "{\"leader_id\":\"$NODE_ID\",\"leader_addr\":\"$NODE_ADDR\",\"term\":$current_term}" >/dev/null 2>&1 || true
    done
}

consensus_tick() {
    consensus_load

    if [[ "$NODE_ID" == "node1" ]]; then
        if [[ "${state:-}" != "leader" || "${leader_id:-}" != "node1" ]]; then
            current_term=$((current_term + 1))
            state="leader"
            voted_for="node1"
            leader_id="node1"
            leader_addr="http://strongbox-1:8200"
            consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
        fi
        consensus_send_heartbeats
        return 0
    fi

    if [[ -z "${leader_id:-}" ]]; then
        leader_id="node1"
        leader_addr="http://strongbox-1:8200"
        state="follower"
        consensus_save "$current_term" "${voted_for:-}" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
        return 0
    fi

    if [[ "$state" == "leader" ]]; then
        if ! consensus_has_quorum; then
            state="follower"
            leader_id=""
            leader_addr=""
            consensus_save "$current_term" "$voted_for" "$state" "$leader_id" "$leader_addr" "$(consensus_now_ms)" "${last_log_index:-0}" "${last_log_term:-0}"
            return 0
        fi
        consensus_send_heartbeats
        return 0
    fi

    local now elapsed timeout
    now=$(consensus_now_ms)
    elapsed=$((now - last_heartbeat_ms))
    timeout=$(consensus_random_timeout_ms)

    if [[ "$elapsed" -ge "$timeout" ]]; then
        consensus_start_election || true
    fi
}

consensus_loop() {
    consensus_init
    while true; do
        consensus_tick
        consensus_sleep_ms "$CONSENSUS_HEARTBEAT_MS"
    done
}

consensus_start_background() {
    consensus_init
    consensus_loop &
    CONSENSUS_PID=$!
    export CONSENSUS_PID
}

consensus_require_leader_for_write() {
    if ! consensus_has_quorum; then
        echo '{"error":"no quorum","detail":"minority partition refuses writes"}'
        return 2
    fi

    if consensus_is_leader; then
        return 0
    fi

    consensus_get_leader || true
    return 1
}

consensus_note_write_committed() {
    consensus_load
    last_log_index=$((last_log_index + 1))
    last_log_term="$current_term"
    consensus_save "$current_term" "${voted_for:-}" "${state:-follower}" "${leader_id:-}" "${leader_addr:-}" "${last_heartbeat_ms:-$(consensus_now_ms)}" "$last_log_index" "$last_log_term"
}

consensus_append_replication_log() {
    local method="$1"
    local path="$2"
    local body_b64="$3"
    mkdir -p "$CONSENSUS_DIR"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(consensus_now_ms)" "$(consensus_current_term)" "$method" "$path" "$body_b64" >> "$CONSENSUS_DIR/replication.log"
}

consensus_replicate_write() {
    local method="$1"
    local path="$2"
    local body="$3"
    local token="$4"
    local quorum acks=1 body_b64 peer peer_addr response accepted

    quorum=$(consensus_quorum_size)
    body_b64=$(printf '%s' "$body" | base64 -w 0)

    IFS=',' read -ra peer_items <<< "$PEERS"
    for peer in "${peer_items[@]}"; do
        [[ -z "$peer" ]] && continue
        peer_addr="${peer#*=}"
        response=$(curl -fsS --max-time 2 \
            -X POST "$peer_addr/v1/sys/consensus/replicate" \
            -H 'Content-Type: application/json' \
            -d "{\"leader_id\":\"$NODE_ID\",\"leader_addr\":\"$NODE_ADDR\",\"term\":$(consensus_current_term),\"method\":\"$method\",\"path\":\"$path\",\"body_b64\":\"$body_b64\",\"token\":\"$token\"}" 2>/dev/null) || continue
        accepted=$(printf '%s' "$response" | sed -n 's/.*"accepted":\([^,}]*\).*/\1/p')
        [[ "$accepted" == "true" ]] && acks=$((acks + 1))
    done

    if [[ "$acks" -ge "$quorum" ]]; then
        consensus_note_write_committed
        return 0
    fi

    echo "{\"error\":\"replication quorum not reached\",\"acks\":$acks,\"quorum\":$quorum}"
    return 1
}
