#!/bin/bash
set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 挂载点
: "${NFS_MOUNT_POINT:=/data}"
mkdir -p "${NFS_MOUNT_POINT}"

# 容器内挂载 NFS (可选,需特权);也可由 kubelet 通过 PV 挂载,或宿主机 -v 映射
if [ -n "${NFS_HOST}" ] && [ -n "${NFS_PATH}" ]; then
    log "容器内挂载 NFS: ${NFS_HOST}:${NFS_PATH} -> ${NFS_MOUNT_POINT}"
    if mount -t nfs ${NFS_OPTS:--o nolock,vers=3,tcp,soft} "${NFS_HOST}:${NFS_PATH}" "${NFS_MOUNT_POINT}"; then
        log "NFS 挂载成功"
    else
        log "NFS 挂载失败,继续启动"
    fi
else
    log "未配置容器内 NFS 挂载 (可由 kubelet 通过 PV 提供,或宿主机 -v 映射)"
fi

# === 启动时按环境变量生成 crontab (镜像内不内置任何任务) ===
mkdir -p /etc/crontabs
CRONTAB=/etc/crontabs/root
REDIR='> /proc/1/fd/1 2>&1'

# 若该行不含重定向且 CRON_LOG_STDOUT=true,则追加 stdout 重定向(便于 logs 查看)
append_redir() {
    local line="$1"
    if [ "${CRON_LOG_STDOUT:-true}" = "true" ] && ! echo "$line" | grep -q '>'; then
        echo "${line} ${REDIR}"
    else
        echo "$line"
    fi
}

if [ "${CRON_USE_EXTERNAL_FILE:-false}" = "true" ] && [ -s "${CRONTAB}" ]; then
    log "使用外部提供的 crontab: ${CRONTAB} (如 ConfigMap 挂载)"
else
    : > "${CRONTAB}"
    if [ -n "${CRON_JOBS}" ]; then
        # 多任务: CRON_JOBS 多行,每行一条完整 cron 表达式 (# 为注释,空行跳过)
        log "从 CRON_JOBS 生成 crontab:"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) echo "$line" >> "${CRONTAB}"; continue ;; esac
            out="$(append_redir "$line")"
            echo "$out" >> "${CRONTAB}"
            log "  + $out"
        done <<< "${CRON_JOBS}"
    else
        # 单任务 (或默认无害任务): CRON_SCHEDULE + CRON_COMMAND
        : "${CRON_SCHEDULE:=*/5 * * * *}"
        : "${CRON_COMMAND:=echo hello world}"
        out="$(append_redir "${CRON_SCHEDULE} ${CRON_COMMAND}")"
        echo "$out" >> "${CRONTAB}"
        log "生成 cron 任务: $out"
    fi
fi
chmod 0600 "${CRONTAB}"

# 可选: 启动时先跑一次初始化命令
if [ -n "${INIT_CMD}" ]; then
    log "执行初始化: ${INIT_CMD}"
    eval "${INIT_CMD}" > /proc/1/fd/1 2>&1 || log "初始化执行完毕(或有非零返回)"
fi

log "启动 crond (日志级别 ${CRON_LOG_LEVEL:-2})"
exec crond -f -l "${CRON_LOG_LEVEL:-2}"
