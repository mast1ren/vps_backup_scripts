#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass_count=0

assert_file_exists() {
    if [ ! -f "$1" ]; then
        echo "ASSERT FAILED: expected file to exist: $1"
        exit 1
    fi
}

assert_file_missing() {
    if [ -e "$1" ]; then
        echo "ASSERT FAILED: expected file to be missing: $1"
        exit 1
    fi
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        echo "ASSERT FAILED: expected [$1] == [$2]"
        exit 1
    fi
}

run_test() {
    local name=$1
    shift

    echo "=== ${name} ==="
    "$@"
    pass_count=$((pass_count + 1))
    echo "PASS"
    echo ""
}

test_config_parser() {
    local config_file="${TMP_DIR}/config_parser.conf"
    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="/tmp/marks"
RETRY_COUNT=4
WATCH_DIRS="alpha,beta"

[alpha]
TYPE="DIR"
PATH="/srv/alpha"
EOF

    local mark_dir
    local retry_count
    local alpha_path

    mark_dir="$(bash -lc "source '${SCRIPT_DIR}/common.sh'; read_section_value 'BACKUP' 'MARK_DIR' '${config_file}'")"
    retry_count="$(bash -lc "source '${SCRIPT_DIR}/common.sh'; read_section_value 'BACKUP' 'RETRY_COUNT' '${config_file}'")"
    alpha_path="$(bash -lc "source '${SCRIPT_DIR}/common.sh'; read_section_value 'alpha' 'PATH' '${config_file}'")"

    assert_eq "${mark_dir}" "/tmp/marks"
    assert_eq "${retry_count}" "4"
    assert_eq "${alpha_path}" "/srv/alpha"
}

prepare_zip_stub() {
    local stub_dir=$1

    mkdir -p "${stub_dir}"
    cat > "${stub_dir}/zip" <<'EOF'
#!/bin/bash
set -euo pipefail

state_file="${ZIP_STATE_FILE:?}"
fail_until="${ZIP_FAIL_UNTIL:-0}"
count=0

if [ -f "${state_file}" ]; then
    count="$(cat "${state_file}")"
fi

count=$((count + 1))
echo "${count}" > "${state_file}"

if [ "${count}" -le "${fail_until}" ]; then
    exit 1
fi

output_file=$2
source_path=$3
printf 'fake zip for %s\n' "${source_path}" > "${output_file}"
EOF
    chmod +x "${stub_dir}/zip"
}

prepare_inotify_stub() {
    local stub_dir=$1

    mkdir -p "${stub_dir}"
    cat > "${stub_dir}/inotifywait" <<'EOF'
#!/bin/bash
set -euo pipefail
target_path="${@: -1}"
state_dir="${INOTIFY_STATE_DIR:?}"
project_key="$(basename "${target_path}")"
count_file="${state_dir}/${project_key}.count"
count=0

if [ -f "${count_file}" ]; then
    count="$(cat "${count_file}")"
fi

count=$((count + 1))
echo "${count}" > "${count_file}"
echo "${target_path} MODIFY file.txt"
exit 0
EOF
    chmod +x "${stub_dir}/inotifywait"
}

test_backup_retries_then_succeeds() {
    local case_dir="${TMP_DIR}/backup_success"
    local source_dir="${case_dir}/source"
    local mark_dir="${case_dir}/marks"
    local target_dir="${case_dir}/target"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/backup.log"
    local stub_dir="${case_dir}/bin"
    local state_file="${case_dir}/zip_state"
    local backup_name

    mkdir -p "${source_dir}" "${mark_dir}" "${target_dir}"
    echo "hello" > "${source_dir}/data.txt"
    touch "${mark_dir}/project.mark"
    prepare_zip_stub "${stub_dir}"

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"
TARGET_DIR="${target_dir}"
BACKUP_NUM=2
RETRY_COUNT=2

[project]
TYPE="DIR"
PATH="${source_dir}"
EOF

    PATH="${stub_dir}:$PATH" ZIP_STATE_FILE="${state_file}" ZIP_FAIL_UNTIL=2 CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" \
        bash "${SCRIPT_DIR}/backup.sh"

    backup_name="$(date +"%Y-%m-%d")_project.zip"
    assert_file_exists "${target_dir}/${backup_name}"
    assert_file_missing "${mark_dir}/project.mark"
    assert_eq "$(cat "${state_file}")" "3"
}

test_backup_failure_keeps_mark() {
    local case_dir="${TMP_DIR}/backup_failure"
    local source_dir="${case_dir}/source"
    local mark_dir="${case_dir}/marks"
    local target_dir="${case_dir}/target"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/backup.log"
    local stub_dir="${case_dir}/bin"
    local state_file="${case_dir}/zip_state"
    local backup_name
    local status=0

    mkdir -p "${source_dir}" "${mark_dir}" "${target_dir}"
    echo "world" > "${source_dir}/data.txt"
    touch "${mark_dir}/project.mark"
    prepare_zip_stub "${stub_dir}"

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"
TARGET_DIR="${target_dir}"
BACKUP_NUM=2
RETRY_COUNT=1

[project]
TYPE="DIR"
PATH="${source_dir}"
EOF

    backup_name="$(date +"%Y-%m-%d")_project.zip"
    set +e
    PATH="${stub_dir}:$PATH" ZIP_STATE_FILE="${state_file}" ZIP_FAIL_UNTIL=9 CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" \
        bash "${SCRIPT_DIR}/backup.sh"
    status=$?
    set -e

    assert_eq "${status}" "1"
    assert_file_exists "${mark_dir}/project.mark"
    assert_file_missing "${target_dir}/${backup_name}"
}

test_backup_reports_monitor_failures() {
    local case_dir="${TMP_DIR}/backup_monitor_failure"
    local source_dir="${case_dir}/source"
    local mark_dir="${case_dir}/marks"
    local target_dir="${case_dir}/target"
    local failed_monitor_dir="${mark_dir}/.monitor_failures"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/backup.log"
    local stub_dir="${case_dir}/bin"
    local state_file="${case_dir}/zip_state"

    mkdir -p "${source_dir}" "${mark_dir}" "${target_dir}" "${failed_monitor_dir}"
    echo "hello" > "${source_dir}/data.txt"
    touch "${mark_dir}/project.mark"
    prepare_zip_stub "${stub_dir}"

    cat > "${failed_monitor_dir}/broken.state" <<EOF
PROJECT=broken
PATH=/tmp/broken
TYPE=DIR
LAST_ERROR_AT=2026-05-15 00:00:00
REASON=Monitor process restart failed after 4 attempts
EOF

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"
TARGET_DIR="${target_dir}"
BACKUP_NUM=2
RETRY_COUNT=0

[project]
TYPE="DIR"
PATH="${source_dir}"
EOF

    PATH="${stub_dir}:$PATH" ZIP_STATE_FILE="${state_file}" ZIP_FAIL_UNTIL=0 CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" \
        bash "${SCRIPT_DIR}/backup.sh"

    if ! grep -q "Monitor warning: unresolved monitor failure detected." "${log_file}"; then
        echo "ASSERT FAILED: expected monitor failure warning in backup log"
        exit 1
    fi
    if ! grep -q "PROJECT=broken" "${log_file}"; then
        echo "ASSERT FAILED: expected failed monitor details in backup log"
        exit 1
    fi
}

test_monitor_creates_mark_file() {
    local case_dir="${TMP_DIR}/monitor"
    local watch_dir="${case_dir}/watch"
    local mark_dir="${case_dir}/marks"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/monitor.log"
    local lock_file="${case_dir}/monitor.pid"
    local stub_dir="${case_dir}/bin"
    local monitor_pid

    mkdir -p "${watch_dir}" "${mark_dir}" "${stub_dir}"
    echo "content" > "${watch_dir}/file.txt"

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"

[project]
TYPE="DIR"
PATH="${watch_dir}"
EOF

    prepare_inotify_stub "${stub_dir}"

    PATH="${stub_dir}:$PATH" INOTIFY_STATE_DIR="${case_dir}" CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" LOCK_FILE="${lock_file}" \
        HEALTH_CHECK_INTERVAL=5 bash "${SCRIPT_DIR}/monitor.sh" &
    monitor_pid=$!

    for _ in $(seq 1 10); do
        if [ -f "${mark_dir}/project.mark" ]; then
            break
        fi
        sleep 1
    done

    kill "${monitor_pid}"
    wait "${monitor_pid}" 2>/dev/null || true

    assert_file_exists "${mark_dir}/project.mark"
    assert_file_missing "${lock_file}"
}

test_monitor_restarts_failed_child() {
    local case_dir="${TMP_DIR}/monitor_restart"
    local watch_dir="${case_dir}/watch"
    local mark_dir="${case_dir}/marks"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/monitor.log"
    local lock_file="${case_dir}/monitor.pid"
    local stub_dir="${case_dir}/bin"
    local count_file="${case_dir}/watch.count"
    local restart_count=0
    local monitor_pid

    mkdir -p "${watch_dir}" "${mark_dir}"
    prepare_inotify_stub "${stub_dir}"

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"

[project]
TYPE="DIR"
PATH="${watch_dir}"
EOF

    PATH="${stub_dir}:$PATH" INOTIFY_STATE_DIR="${case_dir}" CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" LOCK_FILE="${lock_file}" \
        HEALTH_CHECK_INTERVAL=1 bash "${SCRIPT_DIR}/monitor.sh" &
    monitor_pid=$!

    for _ in $(seq 1 10); do
        if [ -f "${count_file}" ]; then
            restart_count="$(cat "${count_file}")"
            if [ "${restart_count}" -ge 2 ]; then
                break
            fi
        fi
        sleep 1
    done

    kill "${monitor_pid}"
    wait "${monitor_pid}" 2>/dev/null || true

    assert_file_exists "${mark_dir}/project.mark"
    assert_eq "$(cat "${count_file}")" "2"
    assert_file_missing "${lock_file}"
}

test_monitor_records_failure_after_retry_exhausted() {
    local case_dir="${TMP_DIR}/monitor_failure"
    local watch_dir="${case_dir}/watch"
    local mark_dir="${case_dir}/marks"
    local failed_state_file="${mark_dir}/.monitor_failures/project.state"
    local config_file="${case_dir}/monitor_config.conf"
    local log_file="${case_dir}/monitor.log"
    local lock_file="${case_dir}/monitor.pid"
    local stub_dir="${case_dir}/bin"
    local monitor_pid

    mkdir -p "${watch_dir}" "${mark_dir}" "${stub_dir}"

    cat > "${config_file}" <<EOF
[BACKUP]
MARK_DIR="${mark_dir}"
WATCH_DIRS="project"
MONITOR_RESTART_RETRIES=1

[project]
TYPE="DIR"
PATH="${watch_dir}"
EOF

    cat > "${stub_dir}/inotifywait" <<'EOF'
#!/bin/bash
set -euo pipefail
exit 1
EOF
    chmod +x "${stub_dir}/inotifywait"

    PATH="${stub_dir}:$PATH" CONFIG_FILE="${config_file}" LOG_FILE="${log_file}" LOCK_FILE="${lock_file}" \
        HEALTH_CHECK_INTERVAL=1 bash "${SCRIPT_DIR}/monitor.sh" &
    monitor_pid=$!

    for _ in $(seq 1 10); do
        if [ -f "${failed_state_file}" ] && grep -q "Monitor process restart failed after 2 attempts" "${failed_state_file}"; then
            break
        fi
        sleep 1
    done

    kill "${monitor_pid}"
    wait "${monitor_pid}" 2>/dev/null || true

    assert_file_exists "${failed_state_file}"
    if ! grep -q "Monitor process restart failed after 2 attempts" "${failed_state_file}"; then
        echo "ASSERT FAILED: expected retry exhaustion reason in failed monitor state"
        exit 1
    fi
    assert_file_missing "${lock_file}"
}

run_test "配置解析" test_config_parser
run_test "备份失败重试后成功" test_backup_retries_then_succeeds
run_test "备份失败保留标记" test_backup_failure_keeps_mark
run_test "备份前输出未恢复的监控错误" test_backup_reports_monitor_failures
run_test "监控触发标记" test_monitor_creates_mark_file
run_test "监控子进程退出后自动拉起" test_monitor_restarts_failed_child
run_test "监控重试耗尽后记录失败状态" test_monitor_records_failure_after_retry_exhausted

echo "All ${pass_count} tests passed."
