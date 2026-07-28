FROM alpine:latest

RUN apk add --no-cache \
    tzdata \
    findutils \
    nfs-utils \
    bash \
    util-linux \
    && mkdir -p /etc/crontabs \
    && rm -rf /var/cache/apk/*

# 镜像内不内置任何 crontab,启动时由环境变量生成
# 默认为无害的 hello world,不会删除任何东西
ENV TZ=Asia/Shanghai
ENV NFS_HOST=""
ENV NFS_PATH=""
ENV NFS_MOUNT_POINT="/mnt/kvcache"
ENV NFS_OPTS="-o nolock,vers=3,tcp,soft,timeo=600,retrans=2"
ENV CRON_JOBS=""
ENV CRON_SCHEDULE="*/5 * * * *"
ENV CRON_COMMAND="echo hello world"
ENV CRON_LOG_STDOUT="true"
ENV CRON_USE_EXTERNAL_FILE="false"
ENV CRON_LOG_LEVEL="2"
ENV INIT_CMD=""

WORKDIR /app
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
