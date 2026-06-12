#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/.env}"
RESULT_DIR="${RESULT_DIR:-${SCRIPT_DIR}/results/$(date +%Y%m%d_%H%M%S)}"

TABLES="${TABLES:-100}"
TABLE_SIZE="${TABLE_SIZE:-20000000}"
THREADS_LIST="${THREADS_LIST:-32 64 128 256 512 1024 2048}"
WORKLOADS="${WORKLOADS:-oltp_read_write oltp_read_only oltp_point_select oltp_update_non_index oltp_update_index oltp_write_only}"
PREPARE_THREADS="${PREPARE_THREADS:-256}"
WARMUP_TIME="${WARMUP_TIME:-120}"
RUN_TIME="${RUN_TIME:-600}"
REPORT_INTERVAL="${REPORT_INTERVAL:-1}"
RAND_TYPE="${RAND_TYPE:-uniform}"
PERCENTILE="${PERCENTILE:-95}"
HISTOGRAM="${HISTOGRAM:-on}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-30}"
MYSQL_IGNORE_ERRORS="${MYSQL_IGNORE_ERRORS:-1213,1205,9007,8028}"
THREAD_INIT_TIMEOUT="${THREAD_INIT_TIMEOUT:-240}"
SYSBENCH_LUA_DIR="${SYSBENCH_LUA_DIR:-}"

DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-4000}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_NAME="${DB_NAME:-}"
DB_SSL_CA="${DB_SSL_CA:-}"

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

unquote() {
  local value="$1"
  if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
  }

  local line key value key_norm
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" != *"="* ]] && continue

    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    value="$(unquote "$value")"
    key_norm="$(printf '%s' "$key" | tr '[:upper:]-' '[:lower:]_')"

    case "$key_norm" in
      host|db_host|mysql_host) DB_HOST="${DB_HOST:-$value}" ;;
      port|db_port|mysql_port) DB_PORT="${DB_PORT:-$value}" ;;
      username|user|db_user|db_username|mysql_user) DB_USER="${DB_USER:-$value}" ;;
      password|db_password|mysql_password) DB_PASSWORD="${DB_PASSWORD:-$value}" ;;
      database|databse|db|db_name|db_database|mysql_db) DB_NAME="${DB_NAME:-$value}" ;;
      ca|ssl_ca|db_ssl_ca|mysql_ssl_ca) DB_SSL_CA="${DB_SSL_CA:-$value}" ;;
    esac
  done < "$CONFIG_FILE"

  : "${DB_HOST:?missing host in config}"
  : "${DB_USER:?missing username in config}"
  : "${DB_PASSWORD:?missing password in config}"
  : "${DB_NAME:?missing database/databse in config}"
}

script_name() {
  local workload="$1"
  if [[ -n "$SYSBENCH_LUA_DIR" ]]; then
    printf '%s/%s.lua' "${SYSBENCH_LUA_DIR%/}" "$workload"
  else
    printf '%s' "$workload"
  fi
}

sysbench_supports_modern_ssl() {
  sysbench --help 2>/dev/null | grep -q -- '--mysql-ssl-ca'
}

sysbench_ssl_mode() {
  if [[ -n "${SYSBENCH_MYSQL_SSL:-}" ]]; then
    printf '%s' "$SYSBENCH_MYSQL_SSL"
  else
    printf 'on'
  fi
}

check_sysbench_tls_support() {
  if [[ "$(sysbench_ssl_mode)" == "off" ]]; then
    return
  fi

  if ! sysbench_supports_modern_ssl && [[ "${ALLOW_LEGACY_SYSBENCH_SSL:-0}" != "1" ]]; then
    cat >&2 <<'EOF'
This sysbench build only supports legacy --mysql-ssl=on and does not support --mysql-ssl-ca.
Legacy sysbench requires local client-key.pem, client-cert.pem and cacert.pem files for TLS, which usually fails with TiDB Cloud.
Please install/build a newer sysbench that supports --mysql-ssl=REQUIRED and --mysql-ssl-ca, then rerun this script.
Set ALLOW_LEGACY_SYSBENCH_SSL=1 only if you intentionally prepared those legacy certificate files.
EOF
    exit 2
  fi
}

common_args() {
  local args=(
    "--db-driver=mysql"
    "--mysql-host=$DB_HOST"
    "--mysql-port=$DB_PORT"
    "--mysql-user=$DB_USER"
    "--mysql-password=$DB_PASSWORD"
    "--mysql-db=$DB_NAME"
    "--mysql-ssl=$(sysbench_ssl_mode)"
    "--tables=$TABLES"
    "--table-size=$TABLE_SIZE"
    "--rand-type=$RAND_TYPE"
    "--percentile=$PERCENTILE"
    "--histogram=$HISTOGRAM"
    "--report-interval=$REPORT_INTERVAL"
    "--thread-init-timeout=$THREAD_INIT_TIMEOUT"
  )

  if sysbench_supports_modern_ssl && [[ -n "$DB_SSL_CA" ]]; then
    args+=("--mysql-ssl-ca=$DB_SSL_CA")
  fi
  if [[ -n "$MYSQL_IGNORE_ERRORS" ]]; then
    args+=("--mysql-ignore-errors=$MYSQL_IGNORE_ERRORS")
  fi

  printf '%s\0' "${args[@]}"
}

run_sysbench() {
  local workload="$1"
  local threads="$2"
  local seconds="$3"
  local action="$4"
  local log_file="$5"
  local warmup="${6:-0}"
  local script
  script="$(script_name "$workload")"

  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(common_args)

  local cmd=(sysbench "$script" "${args[@]}" "--threads=$threads")
  if [[ "$action" == "run" ]]; then
    cmd+=("--time=$seconds" "--events=0")
    if (( warmup > 0 )); then
      cmd+=("--warmup-time=$warmup")
    fi
  fi

  echo "[$(date -Is)] action=$action workload=$workload threads=$threads time=${seconds}s warmup=${warmup}s log=$log_file"
  "${cmd[@]}" "$action" 2>&1 | tee "$log_file"
}

prepare_data() {
  mkdir -p "$RESULT_DIR"
  local log_file="${RESULT_DIR}/prepare_$(date +%Y%m%d_%H%M%S).log"
  run_sysbench "oltp_read_write" "$PREPARE_THREADS" 0 "prepare" "$log_file"
}

cleanup_data() {
  mkdir -p "$RESULT_DIR"
  local log_file="${RESULT_DIR}/cleanup_$(date +%Y%m%d_%H%M%S).log"
  run_sysbench "oltp_read_write" "$PREPARE_THREADS" 0 "cleanup" "$log_file"
}

extract_tps() {
  awk -F'[()]' '/transactions:/ {gsub(/ per sec\./, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

extract_qps() {
  awk -F'[()]' '/queries:/ {gsub(/ per sec\./, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

extract_p95() {
  awk '/95th percentile:/ {print $3; exit}' "$1"
}

extract_p99_from_histogram() {
  awk '
    /Latency histogram/ {in_hist=1; next}
    in_hist && $1 ~ /^[0-9.]+$/ && $NF ~ /^[0-9]+$/ {n++; value[n]=$1; count[n]=$NF; total+=$NF}
    END {
      if (total <= 0) {print ""; exit}
      threshold=total*0.99
      cumulative=0
      for (i=1; i<=n; i++) {
        cumulative+=count[i]
        if (cumulative >= threshold) {print value[i]; exit}
      }
    }
  ' "$1"
}

append_summary() {
  local summary_file="$1"
  local workload="$2"
  local threads="$3"
  local log_file="$4"
  local qps tps p95 p99

  qps="$(extract_qps "$log_file")"
  tps="$(extract_tps "$log_file")"
  p95="$(extract_p95 "$log_file")"
  p99="$(extract_p99_from_histogram "$log_file")"

  if [[ ! -f "$summary_file" ]]; then
    printf 'timestamp\tworkload\tthreads\tqps\ttps\tp95_ms\tp99_ms_approx\tlog_file\n' > "$summary_file"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$workload" "$threads" "${qps:-NA}" "${tps:-NA}" "${p95:-NA}" "${p99:-NA}" "$log_file" >> "$summary_file"
}

run_benchmarks() {
  mkdir -p "$RESULT_DIR"
  local summary_file="${RESULT_DIR}/summary.tsv"
  local workload threads run_log safe_workload

  for workload in $WORKLOADS; do
    safe_workload="${workload//[^A-Za-z0-9_]/_}"
    for threads in $THREADS_LIST; do
      run_log="${RESULT_DIR}/${safe_workload}_${threads}t.log"
      run_sysbench "$workload" "$threads" "$RUN_TIME" "run" "$run_log" "$WARMUP_TIME"
      append_summary "$summary_file" "$workload" "$threads" "$run_log"

      if (( COOLDOWN_SECONDS > 0 )); then
        sleep "$COOLDOWN_SECONDS"
      fi
    done
  done

  echo "Summary: $summary_file"
}

create_database() {
  command -v mysql >/dev/null 2>&1 || {
    echo "mysql client not found; skip database creation." >&2
    exit 1
  }

  local ssl_args=("--ssl-mode=REQUIRED")
  if [[ -n "$DB_SSL_CA" ]]; then
    ssl_args+=("--ssl-ca=$DB_SSL_CA")
  fi

  MYSQL_PWD="$DB_PASSWORD" mysql \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user="$DB_USER" \
    "${ssl_args[@]}" \
    --execute="CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
}

usage() {
  cat <<'USAGE'
Usage: ./run_sysbench_tidbx.sh <action>

Actions:
  create-db  Create benchmark database if it does not exist, requires mysql client
  prepare    Create sysbench tables and load data
  run        Run warmup + formal benchmark matrix
  all        Run prepare, then run
  cleanup    Drop sysbench tables
  help       Show this help

Common overrides:
  CONFIG_FILE=./.env
  TABLES=100
  TABLE_SIZE=20000000
  THREADS_LIST="32 64 128 256 512 1024 2048"
  WORKLOADS="oltp_read_write oltp_read_only oltp_point_select oltp_update_non_index oltp_update_index oltp_write_only"
  PREPARE_THREADS=256
  WARMUP_TIME=120
  RUN_TIME=600
  RESULT_DIR=./results/manual_run
  SYSBENCH_LUA_DIR=/usr/share/sysbench
  SYSBENCH_MYSQL_SSL=REQUIRED
USAGE
}

main() {
  local action="${1:-help}"

  if [[ "$action" == "help" || "$action" == "--help" || "$action" == "-h" ]]; then
    usage
    exit 0
  fi

  command -v sysbench >/dev/null 2>&1 || {
    echo "sysbench not found. Please install sysbench 1.x first." >&2
    exit 1
  }

  load_config
  check_sysbench_tls_support

  case "$action" in
    create-db) create_database ;;
    prepare) prepare_data ;;
    run) run_benchmarks ;;
    all) prepare_data; run_benchmarks ;;
    cleanup) cleanup_data ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
