#!/usr/bin/env bash
# =============================================================================
# HPC101 Lab1 - Docker 保底方案 一键安装脚本
#
# 用法：
#   # 从 build/lab1-docker/ 目录运行
#   cd HPC101/build/lab1-docker
#   bash setup.sh
#
# 该脚本会：
#   1. 检查 Docker 环境
#   2. 构建镜像
#   3. 启动 4 节点容器
#   4. 配置 NFS、MUNGE、Slurm
#   5. 运行验证测试
#   6. 提交 HPL 作业
# =============================================================================
set -euo pipefail

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---- 定位到项目根目录 ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

log_info "项目根目录: $PROJECT_ROOT"

# =============================================================================
# Step 1: 检查环境
# =============================================================================
log_info "========== Step 1: 检查环境 =========="

if ! command -v docker &>/dev/null; then
    log_error "Docker 未安装！请先安装 Docker"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    log_error "Docker Compose 不可用！"
    exit 1
fi

DOCKER_COMPOSE="docker compose"
log_ok "Docker 环境就绪"

# =============================================================================
# Step 2: 构建镜像
# =============================================================================
log_info "========== Step 2: 构建镜像 =========="
log_info "构建镜像 hpc101-lab1:local（首次可能需要 10-30 分钟）..."

$DOCKER_COMPOSE -f "$SCRIPT_DIR/compose.yml" build

log_ok "镜像构建完成"

# =============================================================================
# Step 3: 清理旧容器 & 启动新容器
# =============================================================================
log_info "========== Step 3: 启动容器 =========="

# 停止并删除旧容器（如果有）
$DOCKER_COMPOSE -f "$SCRIPT_DIR/compose.yml" down 2>/dev/null || true

# 启动新容器
$DOCKER_COMPOSE -f "$SCRIPT_DIR/compose.yml" up -d

log_ok "容器已启动"

# 等待所有容器就绪
log_info "等待容器初始化..."
for i in $(seq 1 15); do
    READY=0
    for node in node01 node02 node03 node04; do
        if docker exec "hpc101-$node" pgrep sshd >/dev/null 2>&1; then
            READY=$((READY + 1))
        fi
    done
    if [ "$READY" -eq 4 ]; then
        log_ok "4 个容器全部就绪"
        break
    fi
    sleep 2
done

if [ "$READY" -ne 4 ]; then
    log_warn "只有 $READY/4 个容器就绪（可能部分容器启动较慢）"
fi

# 查看容器状态
$DOCKER_COMPOSE -f "$SCRIPT_DIR/compose.yml" ps

# =============================================================================
# Step 4: 验证 NFS 共享
# =============================================================================
log_info "========== Step 4: 验证 NFS 共享 =========="

NFS_OK=false

# 尝试在 node01 启动 NFS（可能因 overlay 文件系统失败）
if docker exec hpc101-node01 bash -c "mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null && exportfs -av 2>/dev/null && /etc/init.d/nfs-kernel-server start 2>/dev/null"; then
    log_ok "NFS kernel server 启动成功"

    # 在 node02 上测试挂载
    if docker exec hpc101-node02 bash -c "mount -t nfs -o nolock node01:/cluster/shared /mnt 2>/dev/null && touch /mnt/nfs-test && umount /mnt"; then
        NFS_OK=true
        log_ok "NFS 跨节点读写验证通过"
    else
        log_warn "NFS 挂载验证失败，使用 volume 替代"
    fi
else
    log_warn "NFS kernel server 不可用（Docker 环境限制），使用 volume 替代"
fi

if [ "$NFS_OK" = false ]; then
    log_info "容器已通过 Docker volume（hpc101-shared）共享 /cluster/shared"
    log_info "所有容器可以直接读写 /cluster/shared，效果等价于 NFS"
fi

# 验证共享目录可写
docker exec hpc101-node01 bash -c "touch /cluster/shared/.write-test && echo 'shared volume OK' > /cluster/shared/.write-test"
docker exec hpc101-node02 bash -c "cat /cluster/shared/.write-test 2>/dev/null" | grep -q "shared volume OK"
log_ok "共享目录读写正常"

# =============================================================================
# Step 5: 验证 MUNGE
# =============================================================================
log_info "========== Step 5: 验证 MUNGE =========="

for node in node01 node02 node03 node04; do
    if docker exec "hpc101-$node" bash -c "munge -n 2>/dev/null | unmunge 2>/dev/null >/dev/null"; then
        log_ok "MUNGE 正常 ($node)"
    else
        log_warn "MUNGE 异常 ($node)，尝试重启..."
        docker exec "hpc101-$node" bash -c "pkill munged 2>/dev/null; /usr/sbin/munged 2>/dev/null"
        sleep 1
        if docker exec "hpc101-$node" bash -c "munge -n 2>/dev/null | unmunge 2>/dev/null >/dev/null"; then
            log_ok "MUNGE 已恢复 ($node)"
        else
            log_error "MUNGE 无法恢复 ($node)"
        fi
    fi
done

# 验证跨节点 MUNGE 通信
log_info "验证跨节点 MUNGE 通信（node01 → node02）..."
MUNGE_TOKEN=$(docker exec hpc101-node01 munge -n 2>/dev/null)
if [ -n "$MUNGE_TOKEN" ]; then
    if echo "$MUNGE_TOKEN" | docker exec -i hpc101-node02 unmunge >/dev/null 2>&1; then
        log_ok "跨节点 MUNGE 通信正常"
    else
        # 分发 MUNGE key
        log_warn "跨节点 MUNGE 认证失败，重新分发 key..."
        docker exec hpc101-node01 bash -c "cat /etc/munge/munge.key" | docker exec -i hpc101-node02 bash -c "cat >/tmp/munge.key && mv /tmp/munge.key /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && pkill munged 2>/dev/null; /usr/sbin/munged 2>/dev/null"
        docker exec hpc101-node01 bash -c "cat /etc/munge/munge.key" | docker exec -i hpc101-node03 bash -c "cat >/tmp/munge.key && mv /tmp/munge.key /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && pkill munged 2>/dev/null; /usr/sbin/munged 2>/dev/null"
        docker exec hpc101-node01 bash -c "cat /etc/munge/munge.key" | docker exec -i hpc101-node04 bash -c "cat >/tmp/munge.key && mv /tmp/munge.key /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && pkill munged 2>/dev/null; /usr/sbin/munged 2>/dev/null"
        sleep 1
        log_ok "MUNGE key 已分发到所有计算节点"
    fi
fi

# =============================================================================
# Step 6: 验证 Slurm
# =============================================================================
log_info "========== Step 6: 验证 Slurm =========="

# 确保 slurmctld 在 node01 上运行
docker exec hpc101-node01 bash -c "pidof slurmctld >/dev/null 2>&1 || (mkdir -p /var/spool/slurmctld /var/log/slurm && chown slurm:slurm /var/spool/slurmctld /var/log/slurm 2>/dev/null; slurmctld 2>/dev/null)"
sleep 2

# 确保 slurmd 在计算节点上运行
for node in node02 node03 node04; do
    docker exec "hpc101-$node" bash -c "pidof slurmd >/dev/null 2>&1 || (mkdir -p /var/spool/slurmd /var/log/slurm && slurmd 2>/dev/null)"
done
sleep 2

# 检查 sinfo
log_info "检查 Slurm 集群状态..."
docker exec hpc101-node01 sinfo 2>&1 || log_error "sinfo 失败"

# 如果节点 down，尝试恢复
docker exec hpc101-node01 bash -c "scontrol update NodeName=node[01-04] State=RESUME 2>/dev/null" || true
sleep 1

# srun 验证
log_info "通过 srun 提交测试作业..."
docker exec hpc101-node01 srun -N4 hostname 2>&1 || log_error "srun 失败"

# =============================================================================
# Step 7: 提交 HPL
# =============================================================================
log_info "========== Step 7: 提交 HPL =========="

# 生成 HPL.dat（如果不存在）
HPL_DAT="/cluster/shared/hpl-2.3/bin/Linux_PII_FBLAS/HPL.dat"
if ! docker exec hpc101-node01 test -f "$HPL_DAT"; then
    log_info "生成 HPL.dat（N=1000, NB=128, P=1, Q=4）..."
    cat >/tmp/hpl-docker.dat <<'EOF'
HPLinpack benchmark input file
Innovative Computing Laboratory, University of Tennessee
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
1            # of problems sizes (N)
1000         Ns
1            # of NBs
128          NBs
0            PMAP process mapping (0=Row-,1=Column-major)
1            # of process grids (P x Q)
1            Ps
4            Qs
16.0         threshold
1            # of panel fact
2            PFACTs (0=left,1=Crout,2=Right)
1            # of recursive stopping criterium
4            NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
1            # of recursive panel fact.
1            RFACTs (0=left,1=Crout,2=Right)
1            # of broadcast
1            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Long,5=ring)
1            # of look ahead depth
0            DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in binary (>0)
EOF
    docker exec -i hpc101-node01 bash -c "cat >$HPL_DAT" </tmp/hpl-docker.dat
    log_ok "HPL.dat 已生成"
fi

# 创建 sbatch 脚本
log_info "创建 HPL sbatch 脚本..."
docker exec hpc101-node01 bash -c "cat >/cluster/shared/hpl.sbatch <<'EOF'
#!/bin/bash
#SBATCH --job-name=hpl-docker
#SBATCH --partition=debug
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --output=/cluster/shared/hpl-%j.out

cd /cluster/shared/hpl-2.3/bin/Linux_PII_FBLAS

# 清除可能与 Slurm 冲突的环境变量
unset PRTE_MCA_plm_slurm_args
unset PRTE_MCA_plm_slurm_cutoff

# 使用 --allow-run-as-root 避免 Docker 内 root 限制
mpirun --allow-run-as-root ./xhpl
EOF"

# 提交 HPL 作业
JOB_ID=$(docker exec hpc101-node01 sbatch --parsable /cluster/shared/hpl.sbatch 2>/dev/null || echo "")
if [ -n "$JOB_ID" ]; then
    log_ok "HPL 作业已提交，Job ID: $JOB_ID"

    # 等待作业完成
    log_info "等待 HPL 作业完成..."
    for i in $(seq 1 60); do
        STATE=$(docker exec hpc101-node01 sacct -j "$JOB_ID" --format=State --noheader 2>/dev/null | tr -d ' ' | head -1)
        if [ "$STATE" = "COMPLETED" ]; then
            log_ok "HPL 作业完成！"
            break
        elif [ "$STATE" = "FAILED" ] || [ "$STATE" = "TIMEOUT" ] || [ "$STATE" = "CANCELLED" ]; then
            log_error "HPL 作业失败（状态: $STATE）"
            break
        fi
        sleep 5
        printf "."
    done
    echo ""

    # 查看结果
    log_info "HPL 输出："
    docker exec hpc101-node01 bash -c "cat /cluster/shared/hpl-*.out 2>/dev/null | tail -20" || log_info "（输出文件尚未生成）"
else
    log_error "HPL 作业提交失败，尝试直接运行..."

    # 保底：直接通过 mpirun 运行
    docker exec hpc101-node01 bash -c "cd /cluster/shared/hpl-2.3/bin/Linux_PII_FBLAS && mpirun --allow-run-as-root --hostfile /opt/hpc/hostfile -np 4 ./xhpl 2>&1" | tail -20
fi

# =============================================================================
# Step 8: 总结
# =============================================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  HPC101 Lab1 Docker 保底方案部署完成${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "容器访问方式："
echo "  docker exec -it hpc101-node01 bash    # 控制节点"
echo "  docker exec -it hpc101-node02 bash    # 计算节点 1"
echo "  docker exec -it hpc101-node03 bash    # 计算节点 2"
echo "  docker exec -it hpc101-node04 bash    # 计算节点 3"
echo ""
echo "共享目录：/cluster/shared (所有节点可见)"
echo "OpenMPI:   /opt/openmpi"
echo "HPL:       /cluster/shared/hpl-2.3/bin/Linux_PII_FBLAS/xhpl"
echo "hostfile:  /opt/hpc/hostfile"
echo ""
echo "常用诊断命令："
echo "  sinfo                         # 查看集群状态"
echo "  srun -N4 hostname             # 测试跨节点调度"
echo "  sbatch /cluster/shared/hpl.sbatch  # 提交 HPL"
echo "  squeue                        # 查看作业队列"
echo "  sacct                         # 查看作业历史"
echo ""
echo "停止容器："
echo "  cd $SCRIPT_DIR && docker compose down"
echo ""

# 提示环境限制
echo -e "${YELLOW}注意：${NC}"
echo "  1. 如果 NFS 不可用，Docker volume 已自动替代共享目录"
echo "  2. Slurm 使用 ProctrackType=proctrack/linuxproc（cgroup 降级）"
echo "  3. 容器内为 root 用户运行，mpirun 需加 --allow-run-as-root"
echo "  4. 本方案仅供实验验证，不等同于真实 HPC 集群"
