run_test_process() {
  test_binary=$1
  test_result=$2
  test_limit=$3
  status=0
  timed_out=0
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$test_limit" "$test_binary" > "$test_result" 2>&1 || status=$?
    case $status in
      124|137) timed_out=1 ;;
    esac
    return
  fi
  "$test_binary" > "$test_result" 2>&1 &
  pid=$!
  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    process_state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    case "$process_state" in
      Z*) break ;;
    esac
    if [ "$ticks" -ge "$((test_limit * 50))" ]; then
      kill -9 "$pid" 2>/dev/null || true
      timed_out=1
      break
    fi
    sleep 0.02
    ticks=$((ticks + 1))
  done
  wait "$pid" || status=$?
}
