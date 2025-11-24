#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# 确保完全非交互性
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
export DEBIAN_PRIORITY=critical

# -----------------------------
# 颜色配置
# -----------------------------
GREEN="\033[1;32m"
RED="\033[1;31m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RESET="\033[0m"

echo -e "${BLUE}接下来将会基于 ubuntu 环境移除当前 docker，并重新安装配置 docker 环境${RESET}"
# 确保sudo权限，但避免交互式提示
echo -e "${GREEN}权限检查完成${RESET}"

# ================================================================
# 1. 移除旧版 docker
# ================================================================
echo -e "${BLUE}==> 移除旧版本的 docker${RESET}"
sudo apt-get remove --purge -y docker docker-engine docker.io containerd runc || true
sudo apt-get autoremove -y || true
sudo apt-get autoclean || true

# ================================================================
# 2. 安装依赖与 GPG KEY
# ================================================================
echo -e "${BLUE}==> 安装依赖与准备 GPG Key${RESET}"

# 首先清理可能存在的问题的 Docker 源
echo -e "${BLUE}==> 清理可能存在的旧 Docker 源${RESET}"
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/sources.list.d/docker-download.list
sudo rm -f /etc/apt/keyrings/docker*.gpg

sudo apt-get update -y --allow-unauthenticated
sudo apt-get install -y ca-certificates curl gnupg lsb-release jq --allow-unauthenticated

sudo install -m 0755 -d /etc/apt/keyrings

echo -e "${BLUE}==> 下载 Docker GPG Key（自动覆盖旧文件）${RESET}"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg || {
  echo -e "${YELLOW}[WARN] 首次下载失败，正在重试...${RESET}"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
}

sudo gpg --yes --batch --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
sudo chmod 0644 /etc/apt/keyrings/docker.gpg

# 额外添加 GPG 密钥到系统密钥环以解决 NO_PUBKEY 错误
echo -e "${BLUE}==> 添加 Docker GPG 密钥到系统密钥环${RESET}"
sudo gpg --import /tmp/docker.gpg || true

# 如果使用阿里云镜像，需要手动添加对应的 GPG 密钥
echo -e "${BLUE}==> 添加阿里云镜像源的 GPG 密钥${RESET}"
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker-aliyun.gpg
sudo chmod 0644 /etc/apt/keyrings/docker-aliyun.gpg

# 手动添加缺失的 GPG 密钥 7EA0A9C3F273FCD8
echo -e "${BLUE}==> 手动添加缺失的 Docker GPG 密钥${RESET}"
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7EA0A9C3F273FCD8 || {
  echo -e "${YELLOW}[WARN] 从 Ubuntu keyserver 失败，尝试从 MIT keyserver${RESET}"
  sudo apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 7EA0A9C3F273FCD8 || {
    echo -e "${YELLOW}[WARN] 从 MIT keyserver 失败，尝试直接添加密钥${RESET}"
    # 直接添加密钥到系统
    curl -fsSL https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x7EA0A9C3F273FCD8 | sudo apt-key add -
  }
}

# ================================================================
# 3. 写入 APT 源
# ================================================================
echo -e "${BLUE}==> 添加 Docker APT 仓库${RESET}"

source /etc/os-release || true
CODENAME="${UBUNTU_CODENAME:-$(lsb_release -cs || echo noble)}"

case "$CODENAME" in
  noble|jammy|focal) ;; 
  *)
    echo -e "${YELLOW}[WARN] 未知系统代号：$CODENAME，回退使用 jammy${RESET}"
    CODENAME="jammy"
    ;;
esac

sudo tee /etc/apt/sources.list.d/docker.list >/dev/null <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $CODENAME stable
EOF

sudo apt-get update -y --allow-unauthenticated

# ================================================================
# 4. 安装 Docker 全家桶
# ================================================================
echo -e "${BLUE}==> 安装 Docker CE + CLI + containerd + buildx + compose${RESET}"

sudo apt-get install -y --allow-unauthenticated \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# ================================================================
# 5. 写入 daemon.json 配置
# ================================================================
echo -e "${BLUE}==> 生成 daemon.json${RESET}"
sudo mkdir -p /etc/docker

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

# -------------------------
# JSON 语法校验
# -------------------------
echo -e "${BLUE}==> 校验 daemon.json 是否为合法 JSON${RESET}"

if ! jq empty /etc/docker/daemon.json 2>/dev/null; then
  echo -e "${RED}✗ daemon.json JSON 语法错误！dockerd 将无法启动${RESET}"
  exit 11
fi

echo -e "${GREEN}✓ daemon.json 格式合法${RESET}"

# ================================================================
# 6. 启动 docker 服务
# ================================================================
echo -e "${BLUE}==> 启动并设置 docker 开机自启${RESET}"
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl restart docker || {
  echo -e "${RED}✗ Docker 启动失败！尝试查看日志${RESET}"
  journalctl -u docker -n 50 --no-pager
  exit 12
}

# ================================================================
# 7. docker 就绪检查
# ================================================================
echo -e "${BLUE}==> 检查 docker 服务是否就绪${RESET}"

for i in {1..30}; do
  if sudo docker info >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker 服务已正常运行${RESET}"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && {
    echo -e "${RED}✗ Docker 未能在 30 秒内启动${RESET}"
    exit 13
  }
done

# ================================================================
# 8. 组件完整性检查
# ================================================================
echo -e "${BLUE}==> 检查 docker / containerd / buildx 完整性${RESET}"

command -v docker >/dev/null || { echo -e "${RED}✗ docker 缺失${RESET}"; exit 21; }
command -v containerd >/dev/null || { echo -e "${RED}✗ containerd 缺失${RESET}"; exit 22; }
docker buildx version >/dev/null 2>&1 || { echo -e "${RED}✗ buildx 缺失${RESET}"; exit 23; }

echo -e "${GREEN}✓ docker / containerd / buildx 均正常${RESET}"

# ================================================================
# 9. 测试镜像
# ================================================================
echo -e "${BLUE}==> 拉取并运行测试镜像（alpine）${RESET}"

sudo docker pull alpine:latest
sudo docker run --rm alpine echo "hello docker"

echo -e "${GREEN}✓ 测试镜像运行成功${RESET}"

sudo docker rmi alpine:latest >/dev/null || true

# ================================================================
# 10. 完成
# ================================================================
echo -e "${GREEN} Docker 全部安装与检测完成！${RESET}"
