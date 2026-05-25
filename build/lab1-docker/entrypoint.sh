#!/usr/bin/env bash
# =============================================================================
# HPC101 Lab1 - Docker 容器 Entrypoint
# 自动完成：SSH 配置、NFS 服务、MUNGE、Slurm 初始化
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. 基础配置
# ---------------------------------------------------------------------------
HOSTNAME="$(hostname)"
MY_IP="$(ip -4 addr show eth0 2>/dev/null | awk '/inet/ {print $2}' | cut -d/ -f1)"
ALL_NODES=(node01 node02 node03 node04)
ALL_IPS=(172.28.0.11 172.28.0.12 172.28.0.13 172.28.0.14)

log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[ OK ]  $*"; }
log_error() { echo "[ERROR] $*"; }

# ---------------------------------------------------------------------------
# 1. 写入 /etc/hosts（确保主机名解析）
# ---------------------------------------------------------------------------
update_hosts() {
    for i in "${!ALL_NODES[@]}"; do
        node="${ALL_NODES[$i]}"
        ip="${ALL_IPS[$i]}"
        if ! grep -q "$ip.*$node" /etc/hosts 2>/dev/null; then
            echo "$ip    $node" >>/etc/hosts
        fi
    done
}
update_hosts
log_ok "/etc/hosts 已更新"

# ---------------------------------------------------------------------------
# 2. SSH 配置
# ---------------------------------------------------------------------------
setup_ssh() {
    mkdir -p /run/sshd /home/user/.ssh
    chown -R user:user /home/user/.ssh
    chmod 700 /home/user/.ssh
    [ -f /home/user/.ssh/id_ed25519 ] && chmod 600 /home/user/.ssh/id_ed25519
    [ -f /home/user/.ssh/authorized_keys ] && chmod 600 /home/user/.ssh/authorized_keys
    # 确保 user 可以 sudo
    echo "user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/user 2>/dev/null || true
}
setup_ssh
log_ok "SSH 配置完成"

# ---------------------------------------------------------------------------
# 3. NFS 服务端配置（仅在 LAB1_NFS_SERVER=1 时执行，即 node01）
# ---------------------------------------------------------------------------
setup_nfs_server() {
    if [ "${LAB1_NFS_SERVER:-0}" != "1" ]; then
        return
    fi

    log_info "配置 NFS 服务端..."

    # 确保共享目录存在
    mkdir -p /cluster/shared
    chown user:user /cluster/shared

    # 写入 /etc/exports
    if ! grep -q '^/cluster/shared ' /etc/exports 2>/dev/null; then
        echo '/cluster/shared 172.28.0.0/24(rw,sync,no_subtree_check,no_root_squash)' >>/etc/exports
    fi

    # 启动 rpcbind（通常 docker 内已运行，但确保）
    if ! pidof rpcbind >/dev/null 2>&1; then
        /sbin/rpcbind 2>/dev/null || rpcbind 2>/dev/null || true
    fi

    # 挂载 nfsd 内核接口（如果是 overlay 文件系统可能失败）
    if [ ! -f /proc/fs/nfsd/threads ]; then
        mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || log_error "nfsd 挂载失败，NFS 不可用"
    fi

    # 导出并启动 NFS
    if exportfs -av 2>/dev/null; then
        /etc/init.d/nfs-kernel-server start 2>/dev/null || true
        log_ok "NFS 服务端已启动"
    else
        log_error "exportfs 失败，NFS kernel server 不可用（overlay 文件系统限制）"
        log_info "将使用 Docker volume 替代 NFS 共享"
    fi
}
setup_nfs_server

# ---------------------------------------------------------------------------
# 4. MUNGE 配置
# ---------------------------------------------------------------------------
setup_munge() {
    # 如果 MUNGE key 已通过共享目录分发，则使用它
    if [ -f /cluster/shared/munge.key ]; then
        cp /cluster/shared/munge.key /etc/munge/munge.key
        chown munge:munge /etc/munge/munge.key
        chmod 400 /etc/munge/munge.key
        log_ok "MUNGE key 已从共享目录加载"
    elif [ ! -f /etc/munge/munge.key ]; then
        # 首次运行，生成新 key
        /usr/sbin/mungekey --create 2>/dev/null || true
        chown munge:munge /etc/munge/munge.key 2>/dev/null || true
        chmod 400 /etc/munge/munge.key 2>/dev/null || true
        log_ok "MUNGE key 已生成"
    fi

    # 启动 munged
    if ! pidof munged >/dev/null 2>&1; then
        /usr/sbin/munged 2>/dev/null || true
        log_ok "munged 已启动"
    fi

    # 验证 MUNGE
    if munge -n 2>/dev/null | unmunge 2>/dev/null >/dev/null; then
        log_ok "MUNGE 本地验证通过"
    else
        log_error "MUNGE 本地验证失败"
    fi
}
setup_munge

# ---------------------------------------------------------------------------
# 5. Slurm 配置
# ---------------------------------------------------------------------------
setup_slurm() {
    # 生成 slurm.conf（如果不存在或为空）
    if [ ! -s /etc/slurm/slurm.conf ] && [ ! -s /etc/slurm-llnl/slurm.conf ]; then
        log_info "生成 slurm.conf..."
        cat >/etc/slurm/slurm.conf <<'SLURM_EOF'
ClusterName=hpc101
SlurmctldHost=node01

SlurmUser=slurm
AuthType=auth/munge
CredType=cred/munge
MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=2

SelectType=select/cons_tres
SelectTypeParameters=CR_CPU
SchedulerType=sched/backfill
TaskPlugin=task/none

StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

NodeName=node[01-04] CPUs=1 State=UNKNOWN
PartitionName=debug Nodes=node[01-04] Default=YES MaxTime=INFINITE State=UP
SLURM_EOF

        # Ubuntu 兼容
        mkdir -p /etc/slurm-llnl
        cp /etc/slurm/slurm.conf /etc/slurm-llnl/slurm.conf
        log_ok "slurm.conf 已生成"
    fi

    # 创建必要的目录
    mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
    chown slurm:slurm /var/spool/slurmctld /var/log/slurm 2>/dev/null || true

    # 根据主机名启动对应 Slurm 服务
    case "$HOSTNAME" in
        node01)
            # 控制节点：确保 slurmctld 在运行
            if ! pidof slurmctld >/dev/null 2>&1; then
                slurmctld 2>/dev/null || true
                sleep 1
            fi
            if pidof slurmctld >/dev/null 2>&1; then
                log_ok "slurmctld 已启动 (node01)"
            else
                log_error "slurmctld 启动失败"
            fi
            ;;
        *)
            # 计算节点：启动 slurmd
            if ! pidof slurmd >/dev/null 2>&1; then
                slurmd 2>/dev/null || true
                sleep 1
            fi
            if pidof slurmd >/dev/null 2>&1; then
                log_ok "slurmd 已启动 ($HOSTNAME)"
            else
                log_error "slurmd 启动失败 ($HOSTNAME)"
            fi
            ;;
    esac
}
setup_slurm

# ---------------------------------------------------------------------------
# 6. 如果 MUNGE key 在 node01 上刚生成，复制到共享目录
# ---------------------------------------------------------------------------
distribute_munge_key() {
    if [ "${LAB1_NFS_SERVER:-0}" != "1" ]; then
        return
    fi
    if [ -f /etc/munge/munge.key ] && [ ! -f /cluster/shared/munge.key ]; then
        cp /etc/munge/munge.key /cluster/shared/munge.key
        chown user:user /cluster/shared/munge.key
        chmod 644 /cluster/shared/munge.key
        log_ok "MUNGE key 已分发到共享目录 (node01)"
    fi
}
distribute_munge_key

# ---------------------------------------------------------------------------
# 7. 启动 SSH 守护进程（前台，保持容器运行）
# ---------------------------------------------------------------------------
log_info "启动 SSH 守护进程..."
exec /usr/sbin/sshd -D -e
