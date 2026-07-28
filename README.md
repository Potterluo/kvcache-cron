# kvcache-cron

轻量 Alpine 镜像，内置 `cron`（busybox crond）+ `find` + `nfs-utils`。**镜像内不内置任何定时任务**，启动时由环境变量动态生成 crontab——在 YAML 或 `docker run` 里随意指定 cron 表达式与命令，无需重新构建镜像。

支持 `linux/arm64`（生产）与 `linux/amd64`（本地验证）。

---

## 核心设计

1. **cron 表达式不内置**：启动时 `entrypoint.sh` 读取环境变量生成 `/etc/crontabs/root`。改表达式/命令**无需重建镜像**。
2. **默认无害**：不设任何 `CRON_*` 环境变量时，默认每 5 分钟 `echo hello world`，**不删除任何东西**——就是个普通的 cron+nfs 镜像。执行删除等操作必须显式设置环境变量。
3. **支持多任务**：用 `CRON_JOBS` 一次指定任意数量 cron 任务。

---

## Release 产物（镜像下载）

两个镜像 tar 包以 GitHub Release 产物形式发布，**不随仓库代码提交**。在 [Releases 页面](../../releases) 下载：

| 文件 | 架构 | 用途 |
|------|------|------|
| `my-cron-nfs_latest-arm64.tar` | `linux/arm64` | 生产部署（ARM 设备/树莓派等）|
| `my-cron-nfs_amd64-test.tar` | `linux/amd64` | x86 本地验证 |

```bash
# 下载后导入
docker load -i my-cron-nfs_latest-arm64.tar       # 或 podman load -i
# k3s/containerd:
sudo k3s ctr -n k8s.io images import my-cron-nfs_latest-arm64.tar
```

校验（SHA256 见各 Release 说明）：
```bash
sha256sum my-cron-nfs_latest-arm64.tar
```

---

## 使用说明

### 快速开始：在 k3s/k8s 上定时清理 NFS 目录

```bash
# 1) 拉取镜像 tar 并导入集群
sudo k3s ctr -n k8s.io images import my-cron-nfs_latest-arm64.tar

# 2) 编辑 deploy.yaml:
#    - PV.server / PV.path  →  你的 NFS 服务器与导出路径
#    - CRON_JOBS           →  你的 cron 表达式与命令

# 3) 部署
kubectl apply -f deploy.yaml

# 4) 查看 cron 执行日志
kubectl -n kvcache-cron logs -f deploy/kvcache-cron

# 5) 查看目录内容
kubectl -n kvcache-cron exec deploy/kvcache-cron -- ls -laR /mnt/kvcache

# 清理
kubectl delete -f deploy.yaml
```

### 快速开始：单机 docker run

```bash
docker load -i my-cron-nfs_latest-arm64.tar

# 宿主机已挂载 NFS，直接 -v 映射（无需特权）
docker run -d --name kvcache-cron \
  -v /mnt/nfs/kvcache:/mnt/kvcache:rw \
  -e CRON_JOBS='0 3 * * * /usr/bin/find /mnt/kvcache -type f -delete' \
  my-cron-nfs:latest-arm64

docker logs -f kvcache-cron
```

### 三种部署方式对比

| 方式 | NFS 来源 | 特权 | 调度者 | 适用 |
|------|----------|------|--------|------|
| A. k8s + NFS PV（`deploy.yaml`）| kubelet 在节点挂载 | 否 | 容器内 crond | 生产集群、常驻 |
| B. docker run + 容器内挂 NFS | 容器内 `mount -t nfs` | 是（`--privileged`）| 容器内 crond | 单机、无 PV |
| C. docker run + `-v` 映射 | 宿主机已挂好 | 否 | 容器内 crond | 单机最简 |
| **D. k8s CronJob（`cronjob.yaml`）** | kubelet 在节点挂载 | 否 | **k8s 原生** | **生产首选** |

---

## 方式 D：k8s CronJob（原生调度，更简单）

> 纯 k8s 场景**首选**。调度交给 k8s 的 `CronJob`，cron 表达式直接写在 YAML 的 `schedule:` 字段；容器**一次性**跑完 `find` 即退出（不常驻、不占资源）。此时镜像内的 crond 不参与，`command:` 直接覆盖 ENTRYPOINT 运行 find。

```bash
sudo k3s ctr -n k8s.io images import my-cron-nfs_latest-arm64.tar
kubectl apply -f cronjob.yaml                      # schedule 在 yaml 里改
kubectl -n kvcache-cron get cronjob,job -w         # 看调度与 Job
kubectl -n kvcache-cron logs job/kvcache-cron-XXXX # 看某次执行日志
```

`cronjob.yaml` 关键片段：

```yaml
spec:
  schedule: "0 3 * * *"          # ★ cron 表达式直接写这里
  timeZone: Asia/Shanghai
  concurrencyPolicy: Forbid      # 上次没跑完则跳过本次
  successfulJobsHistoryLimit: 3   # 保留 3 次成功记录
  jobTemplate:
    spec:
      backoffLimit: 2            # 失败重试 2 次
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: cleanup
              image: my-cron-nfs:latest-arm64
              imagePullPolicy: Never
              command:           # 覆盖 ENTRYPOINT,直接跑 find
                - /bin/sh
                - -c
                - |
                  n=$(find /mnt/kvcache -type f -print -delete | wc -l)
                  echo "kvcache cleanup: deleted $n files at $(date)"
```

**容器内 crond（方式 A/B/C）vs CronJob（方式 D）对比：**

| 维度 | 容器内 crond | k8s CronJob |
|------|--------------|-------------|
| cron 在哪 | 镜像/env 变量 | YAML `schedule:` |
| Pod 形态 | 常驻（Deployment）| 一次性 Job |
| 失败重试 | 无 | `backoffLimit` |
| 历史记录 | 无 | `*HistoryLimit` |
| 并发控制 | 无 | `concurrencyPolicy` |
| 错过补偿 | 无 | `startingDeadlineSeconds` |
| 资源占用 | 一直占 | 仅执行时 |

> 验证记录：k3s 上用 `schedule: "* * * * *"` 实测，k8s 自动建 Job，3 秒跑完，日志 `deleted 4 files`，4 文件全删、`subdir`/`subdir2` 文件夹全保留 ✅

---

## 方式 E：Sidecar 边车（Pod 内定时清理）

> 当要清理的是**主容器 Pod 本地卷**（如 `emptyDir` 缓存）时，CronJob（独立 Pod）访问不到——只有**同 Pod 的边车**能清。典型场景：主容器是 vLLM 等服务，边车定时清它写的缓存。

复用本镜像作边车：`crond` 在边车内常驻，按 env 调度；主容器与边车挂载**同一个卷**（`emptyDir` 或共享 `PVC`）。见仓库 `vllm-sidecar-cron.yaml`：

```yaml
spec:
  containers:
    - name: vllm                # 主容器
      image: vllm/vllm-openai:latest
      volumeMounts:
        - {name: kvcache, mountPath: /mnt/kvcache}
    - name: cleanup             # 边车: 定时清主容器写的缓存
      image: my-cron-nfs:latest-arm64
      env:
        - {name: CRON_SCHEDULE, value: "0 3 * * *"}
        - {name: CRON_COMMAND, value: "/usr/bin/find /mnt/kvcache -type f -delete"}
      volumeMounts:
        - {name: kvcache, mountPath: /mnt/kvcache}   # 共享同一卷
  volumes:
    - {name: kvcache, emptyDir: {}}    # 或 persistentVolumeClaim 共享
```

**验证记录**（k3s）：`writer`(模拟主容器写文件)+`cleanup`(边车) 共享 `emptyDir`，边车 cron 触发后删掉主容器写的 3 个文件，`sub` 文件夹保留 ✅

> 三种调度方式怎么选？
> - **CronJob**：要清理的是**集群/共享存储**（PV/PVC），且无需常驻 → 方式 D
> - **Sidecar**：要清理的是**主容器 Pod 本地卷**（emptyDir），需与主容器同生命周期 → 方式 E
> - **常驻 Deployment + crond**：主容器本身就需要常驻、且清理与它解耦 → 方式 A

---

## cron 表达式说明

镜像使用标准 **Vixie cron 5 段格式**（与系统 `crontab`、busybox crond 完全兼容）：

```
# ┌──── 分钟  (0-59)
# │ ┌──── 小时 (0-23)
# │ │ ┌──── 日  (1-31)
# │ │ │ ┌──── 月  (1-12, 或 jan-dec)
# │ │ │ │ ┌──── 星期 (0-7, 0 和 7 均为周日, 或 sun-sat)
# │ │ │ │ │
# │ │ │ │ │
# * * * * * 命令
```

### 字段取值

| 字段 | 允许值 |
|------|--------|
| 分钟 | `0-59` |
| 小时 | `0-23` |
| 日 | `1-31` |
| 月 | `1-12` 或 `jan-dec` |
| 星期 | `0-7`（0 与 7 均为周日）或 `sun-sat` |

### 特殊字符

| 字符 | 含义 | 示例 |
|------|------|------|
| `*` | 任意值（该字段所有合法值）| `* * * * *` 每分钟 |
| `,` | 列表（多个离散值）| `0,15,30,45 * * * *` 每小时的 0/15/30/45 分 |
| `-` | 范围 | `0 9-17 * * *` 每天 9:00–17:00 每小时 |
| `/` | 步长 | `*/10 * * * *` 每 10 分钟；`0 */2 * * *` 每 2 小时 |
| `*/N` | 从字段最小值起每 N 步 | `*/5 * * * *` 每 5 分钟 |

### 常用示例

| 表达式 | 含义 |
|--------|------|
| `0 3 * * *` | 每天凌晨 3:00 |
| `0 3 * * 0` | 每周日凌晨 3:00 |
| `0 0 1 * *` | 每月 1 号 0:00 |
| `*/30 * * * *` | 每 30 分钟 |
| `0 */2 * * *` | 每 2 小时整点 |
| `0 9-17 * * 1-5` | 工作日 9:00–17:00 每小时 |
| `0 3 1,15 * *` | 每月 1 号与 15 号 3:00 |
| `* * * * *` | 每分钟（仅用于验证）|

> **时区**：cron 按 `TZ` 环境变量（默认 `Asia/Shanghai`）执行。容器时区即 cron 时区。
> **注意**：日与星期同时为具体值时是“或”关系（任一满足即触发），这是 cron 标准行为。

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TZ` | `Asia/Shanghai` | 时区，决定 cron 执行时区 |
| `CRON_JOBS` | _(空)_ | ★ **多任务**：多行字符串，每行一条完整 cron 表达式（`#` 注释，空行跳过）。设置后优先于单任务变量 |
| `CRON_SCHEDULE` | `*/5 * * * *` | ★ 单任务 cron 表达式（仅当 `CRON_JOBS` 为空时生效）|
| `CRON_COMMAND` | `echo hello world` | ★ 单任务执行的命令（仅当 `CRON_JOBS` 为空时生效）|
| `CRON_LOG_STDOUT` | `true` | 把任务输出重定向到容器 stdout（便于 `logs` 查看）；对已有重定向的行不重复追加 |
| `CRON_USE_EXTERNAL_FILE` | `false` | 设为 `true` 时使用外部挂载的 crontab（见“进阶”）|
| `CRON_LOG_LEVEL` | `2` | crond 日志级别 |
| `NFS_HOST` | _(空)_ | 容器内挂载 NFS：服务器地址（需特权运行）|
| `NFS_PATH` | _(空)_ | 容器内挂载 NFS：导出路径 |
| `NFS_MOUNT_POINT` | `/mnt/kvcache` | 容器内 NFS 挂载点 |
| `NFS_OPTS` | `-o nolock,vers=3,...` | `mount.nfs` 选项 |
| `INIT_CMD` | _(空)_ | 启动 crond 前先执行一次的命令 |

> **优先级**：`CRON_USE_EXTERNAL_FILE=true`(外部挂载文件) > `CRON_JOBS`(多任务) > `CRON_SCHEDULE`+`CRON_COMMAND`(单任务) > 默认 hello world。

---

## 部署方式

### 方式 A：k8s/k3s + NFS PV（推荐，非特权）

kubelet 在节点上挂载 NFS 再挂入 Pod，Pod 无需特权。用本仓库 `deploy.yaml`：

```bash
sudo k3s ctr -n k8s.io images import my-cron-nfs_latest-arm64.tar   # 导入镜像
kubectl apply -f deploy.yaml                                          # 部署
kubectl -n kvcache-cron logs -f deploy/kvcache-cron                  # 查看日志
```

编辑 `deploy.yaml`：改 `PV.server/path` 为你的 NFS；用 `CRON_JOBS`（多任务）或 `CRON_SCHEDULE`+`CRON_COMMAND`（单任务）指定任务。

### 方式 B：docker/podman run，容器内挂载 NFS（需特权）

```bash
docker load -i my-cron-nfs_latest-arm64.tar

docker run -d --name kvcache-cron --privileged \
  -e TZ=Asia/Shanghai \
  -e NFS_HOST=192.168.1.100 -e NFS_PATH=/export/kvcache \
  -e CRON_JOBS='0 3 * * * /usr/bin/find /mnt/kvcache -type f -delete' \
  my-cron-nfs:latest-arm64
```

### 方式 C：宿主机已挂载 NFS，直接 -v 映射（无需特权）

```bash
docker run -d --name kvcache-cron \
  -v /mnt/nfs/kvcache:/mnt/kvcache:rw \
  -e CRON_JOBS='0 3 * * * /usr/bin/find /mnt/kvcache -type f -delete' \
  my-cron-nfs:latest-arm64
```

---

## 多任务

`CRON_JOBS` 为多行字符串，每行一条完整 cron 表达式。`#` 开头为注释，空行跳过。

```yaml
env:
  - name: CRON_JOBS
    value: |-
      0 3 * * * /usr/bin/find /mnt/kvcache -type f -delete
      0 4 * * * /usr/bin/find /mnt/other -type f -delete
      */10 * * * * echo keepalive
      # 这是一行注释,不会被 cron 执行
```

或 `docker run` 用多行 `-e`：

```bash
docker run -d --name kvcache-cron \
  -e CRON_JOBS='0 3 * * * find /mnt/kvcache -type f -delete
0 4 * * * find /mnt/other -type f -delete
*/10 * * * * echo keepalive' \
  my-cron-nfs:latest-arm64
```

> 启动日志会逐行打印生成的 crontab 内容，便于核对。

## 进阶：挂载完整 crontab（ConfigMap）

更复杂场景可挂载一个完整 crontab 文件并设 `CRON_USE_EXTERNAL_FILE=true`：

```yaml
env:
  - name: CRON_USE_EXTERNAL_FILE
    value: "true"
volumeMounts:
  - name: cronfile
    mountPath: /etc/crontabs/root
    subPath: root
volumes:
  - name: cronfile
    configMap:
      name: kvcache-crontab
      defaultMode: 0600
```

---

## 本地验证记录（k3s，amd64 测试镜像）

1. **默认无害**：不设任何 `CRON_*`，容器内 crontab 仅为 `*/5 * * * * echo hello world > /proc/1/fd/1 2>&1`，不删除任何文件 ✅
2. **多任务执行**：`CRON_JOBS` 设置三条每分钟任务（2 个 echo + 1 个 find-delete），均在日志中输出，全部执行 ✅
3. **删除验证**：`find /mnt/kvcache -type f -delete`，4 个文件（含子目录内嵌套文件）全删，`subdir`/`subdir2`/根 `kvcache` 文件夹全保留 ✅
4. **NFS**：通过 PV 挂载（`127.0.0.1` 走 loopback，绕过 firewalld），Pod 非特权 ✅

---

## 文件清单

| 文件 | 说明 |
|------|------|
| `Dockerfile` | 镜像构建文件（env 驱动，无内置 cron，默认 hello world）|
| `entrypoint.sh` | 启动脚本：按 env 生成 crontab，可选挂载 NFS，启动 crond |
| `deploy.yaml` | k8s/k3s 部署清单（Namespace+PV+PVC+Deployment）|
| `build.sh` | 构建脚本（一键构建 ARM64/AMD64 并导出 tar）|
| `README.md` | 本文档 |
| `my-cron-nfs_latest-arm64.tar` | 生产 ARM64 镜像（**Release 产物，不在仓库内**）|

## 重新构建镜像

```bash
# 用 build.sh 一键构建
./build.sh arm64    # 生产 ARM64 + 导出 tar
./build.sh amd64    # 本地 AMD64 验证 + 导出 tar

# 或手动
podman build --platform linux/arm64 -t my-cron-nfs:latest-arm64 .
podman save -o my-cron-nfs_latest-arm64.tar my-cron-nfs:latest-arm64
```

> AMD64 本地验证构建前需安装 ARM64 模拟：`sudo dnf install -y qemu-user-static`（仅跨架构构建需要）。

## 清理测试环境

```bash
kubectl delete -f deploy.yaml
sudo systemctl disable --now nfs-server
sudo rm -f /etc/exports.d/kvcache.exports && sudo exportfs -ra
```
