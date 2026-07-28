#!/bin/bash
# 一键构建 kvcache-cron 镜像并导出 tar
# 用法:
#   ./build.sh arm64   # 生产 ARM64
#   ./build.sh amd64   # 本地 AMD64 验证
set -e

ARCH="${1:-arm64}"
case "${ARCH}" in
    arm64) IMAGE="my-cron-nfs:latest-arm64"; TAR="my-cron-nfs_latest-arm64.tar" ;;
    amd64) IMAGE="my-cron-nfs:amd64-test";   TAR="my-cron-nfs_amd64-test.tar" ;;
    *) echo "用法: $0 {arm64|amd64}"; exit 1 ;;
esac

echo "==> 构建 linux/${ARCH}: ${IMAGE}"
podman build --platform "linux/${ARCH}" -t "${IMAGE}" .

echo "==> 导出 tar: ${TAR}"
rm -f "${TAR}"
podman save -o "${TAR}" "${IMAGE}"

echo "==> 完成"
ls -lh "${TAR}"
echo "SHA256: $(sha256sum "${TAR}" | awk '{print $1}')"
