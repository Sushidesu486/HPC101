# =============================================================================
# HPC101 Lab1 - Docker 保底方案镜像
# 基于 Ubuntu 24.04，自包含构建 OpenMPI + BLAS + CBLAS + HPL
# 预装 SSH、NFS、MUNGE、Slurm
# =============================================================================
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENMPI_VERSION=5.0.3
ARG HPL_VERSION=2.3

# =============================================================================
# 第一阶段：安装系统包
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    gfortran \
    iproute2 \
    iputils-ping \
    libevent-dev \
    libhwloc-dev \
    libpmix-dev \
    libz-dev \
    make \
    munge \
    nfs-common \
    nfs-kernel-server \
    openssh-client \
    openssh-server \
    pkg-config \
    rpcbind \
    slurm-wlm \
    sudo \
    wget \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# 第二阶段：创建用户 & 配置 SSH 免密
# =============================================================================
RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/user \
    && chmod 0440 /etc/sudoers.d/user \
    && mkdir -p /run/sshd /opt/src /opt/hpc /home/user/.ssh \
    && chown -R user:user /home/user

# 生成 SSH 密钥对，所有容器共用同一份密钥（容器间免密）
RUN ssh-keygen -t ed25519 -N "" -f /home/user/.ssh/id_ed25519 \
    && cp /home/user/.ssh/id_ed25519.pub /home/user/.ssh/authorized_keys \
    && chown -R user:user /home/user/.ssh \
    && chmod 700 /home/user/.ssh \
    && chmod 600 /home/user/.ssh/id_ed25519 /home/user/.ssh/authorized_keys

# 跳过 SSH 首次连接确认
RUN printf "Host *\n    StrictHostKeyChecking accept-new\n    UserKnownHostsFile /dev/null\n" >/home/user/.ssh/config \
    && chown user:user /home/user/.ssh/config \
    && chmod 600 /home/user/.ssh/config

# =============================================================================
# 第三阶段：编译 OpenMPI
# =============================================================================
RUN cd /opt/src \
    && wget -q "https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-${OPENMPI_VERSION}.tar.gz" \
    && tar xf "openmpi-${OPENMPI_VERSION}.tar.gz" \
    && cd "openmpi-${OPENMPI_VERSION}" \
    && ./configure --prefix=/opt/openmpi \
    && make -j"$(nproc)" \
    && make install \
    && echo /opt/openmpi/lib >/etc/ld.so.conf.d/openmpi.conf \
    && ldconfig

# 确保 user 登录时 PATH 和 LD_LIBRARY_PATH 正确
RUN echo 'export PATH=/opt/openmpi/bin:$PATH' >>/home/user/.bashrc \
    && echo 'export LD_LIBRARY_PATH=/opt/openmpi/lib:$LD_LIBRARY_PATH' >>/home/user/.bashrc \
    && echo 'export PATH=/opt/openmpi/bin:$PATH' >>/etc/skel/.bashrc

# =============================================================================
# 第四阶段：编译 BLAS
# =============================================================================
COPY src/lab1/blas-3.12.0.tgz /opt/src/

RUN cd /opt/src \
    && tar xf blas-3.12.0.tgz \
    && cd BLAS-3.12.0 \
    && make -j"$(nproc)" \
    && mkdir -p /opt/hpc/BLAS-3.12.0 \
    && cp blas_LINUX.a /opt/hpc/BLAS-3.12.0/

# =============================================================================
# 第五阶段：编译 CBLAS
# =============================================================================
COPY src/lab1/CBLAS.tgz /opt/src/

RUN cd /opt/src \
    && tar xf CBLAS.tgz \
    && cd CBLAS \
    && sed -i 's#^BLLIB = .*#BLLIB = /opt/hpc/BLAS-3.12.0/blas_LINUX.a#' Makefile.in \
    && make alllib \
    && mkdir -p /opt/hpc/CBLAS/lib \
    && cp lib/cblas_LINUX.a /opt/hpc/CBLAS/lib/

# =============================================================================
# 第六阶段：编译 HPL
# =============================================================================
RUN cd /opt/src \
    && wget -q "https://netlib.org/benchmark/hpl/hpl-${HPL_VERSION}.tar.gz" \
    && tar xf "hpl-${HPL_VERSION}.tar.gz" \
    && cd "hpl-${HPL_VERSION}" \
    && cp setup/Make.Linux_PII_FBLAS Make.Linux_PII_FBLAS \
    && sed -i 's#^TOPdir[[:space:]]*=.*#TOPdir = /opt/src/hpl-2.3#' Make.Linux_PII_FBLAS \
    && sed -i 's#^MPdir[[:space:]]*=.*#MPdir = /opt/openmpi#' Make.Linux_PII_FBLAS \
    && sed -i 's#^MPinc[[:space:]]*=.*#MPinc = -I$(MPdir)/include#' Make.Linux_PII_FBLAS \
    && sed -i 's#^MPlib[[:space:]]*=.*#MPlib = $(MPdir)/lib/libmpi.so#' Make.Linux_PII_FBLAS \
    && sed -i 's#^LAdir[[:space:]]*=.*#LAdir = /opt/hpc/BLAS-3.12.0#' Make.Linux_PII_FBLAS \
    && sed -i 's#^LAlib[[:space:]]*=.*#LAlib = $(LAdir)/blas_LINUX.a#' Make.Linux_PII_FBLAS \
    && sed -i 's#^CC[[:space:]]*=.*#CC = /opt/openmpi/bin/mpicc#' Make.Linux_PII_FBLAS \
    && sed -i 's#^LINKER[[:space:]]*=.*#LINKER = /opt/openmpi/bin/mpifort#' Make.Linux_PII_FBLAS \
    && make arch=Linux_PII_FBLAS \
    && mkdir -p /opt/hpc/hpl-2.3 \
    && cp -a /opt/src/hpl-2.3/bin /opt/hpc/hpl-2.3/

# =============================================================================
# 第七阶段：准备共享目录 & hostfile
# =============================================================================
RUN mkdir -p /cluster/shared && chown user:user /cluster/shared

# 创建 hostfile（IP 版本保证跨容器解析正确）
RUN printf "node01 slots=1\nnode02 slots=1\nnode03 slots=1\nnode04 slots=1\n" >/opt/hpc/hostfile \
    && printf "172.28.0.11 slots=1\n172.28.0.12 slots=1\n172.28.0.13 slots=1\n172.28.0.14 slots=1\n" >/opt/hpc/hostfile.ip \
    && chown -R user:user /opt/hpc

# 拷贝一份 HPL 到共享目录
RUN cp -a /opt/hpc/hpl-2.3 /cluster/shared/hpl-2.3 \
    && cp /opt/hpc/hostfile /opt/hpc/hostfile.ip /cluster/shared/ \
    && chown -R user:user /cluster/shared

# =============================================================================
# 第八阶段：Entrypoint
# =============================================================================
COPY build/lab1-docker/entrypoint.sh /usr/local/bin/lab1-entrypoint.sh
RUN chmod +x /usr/local/bin/lab1-entrypoint.sh

EXPOSE 22 111 2049
CMD ["/usr/local/bin/lab1-entrypoint.sh"]
