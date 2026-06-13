#!/usr/bin/env bash
# 等待 prepare 完成后自动启动 run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG="${SCRIPT_DIR}/auto_run.log"

echo "[$(date -Is)] auto_run_after_prepare started, waiting for prepare to finish..." >> "$LOG"

while pgrep -f "sysbench .* prepare" > /dev/null 2>&1; do
  echo "[$(date -Is)] prepare still running, sleep 5min..." >> "$LOG"
  sleep 300
done

echo "[$(date -Is)] prepare finished, sleep 60s buffer then start run..." >> "$LOG"
sleep 60

nohup bash "${SCRIPT_DIR}/run_sysbench_tidbx.sh" run \
  > "${SCRIPT_DIR}/run.log" 2>&1 &

echo "[$(date -Is)] run started, pid=$!" >> "$LOG"
