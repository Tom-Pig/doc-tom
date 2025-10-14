#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# 定义颜色
GREEN="\033[1;32m"
RED="\033[1;31m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RESET="\033[0m"

echo -e "${BLUE}接下来将会基于ubuntu环境移除当前docker，并重新安装配置docker环境${RESET}"
sudo -v

echo -e "${BLUE}==> 移除旧版本的docker${RESET}"
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
sudo apt-get autoremove -y || true

echo -e "${BLUE}==> 开始安装、配置${RESET}"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod 0644 /etc/apt/keyrings/docker.gpg

echo -e "${BLUE}==> 添加 Docker 官方仓库并刷新索引${RESET}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y

echo -e "${BLUE}==> 安装 Docker CE/CLI、containerd、Buildx、Compose${RESET}"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo -e "${BLUE}==> 配置开机自启动并启动 docker${RESET}"
sudo systemctl enable --now docker

echo -e "${BLUE}==> 配置国内源加速${RESET}"
sudo mkdir -p /etc/docker
cat <<'EOF' | sudo tee /etc/docker/daemon.json >/dev/null
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://mirror.ccs.tencentyun.com",
    "https://hub-mirror.c.163.com",
    "https://docker.mirrors.ustc.edu.cn"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "dns": ["223.5.5.5", "119.29.29.29", "8.8.8.8"]
}
EOF

echo -e "${BLUE}==> 重新加载并重启 docker 以应用配置${RESET}"
sudo systemctl daemon-reload
sudo systemctl restart docker

echo -e "${BLUE}==> 检查 docker 服务是否就绪（最多等待30秒）${RESET}"
for i in {1..30}; do
  if sudo docker info >/dev/null 2>&1; then
    echo -e "${GREEN}✓ dockerd 已就绪${RESET}"
    break
  fi
  sleep 1
  if [[ $i -eq 30 ]]; then
    echo -e "${RED}✗ dockerd 未在30秒内就绪，打印最近日志：${RESET}"
    journalctl -u docker -n 200 --no-pager || true
    exit 1
  fi
done

echo -e "${YELLOW}如果镜像加速无效则尝试进入当前‘make-docker-env.sh’脚本，取消注释部分，进行代理${RESET}"
echo -e "${YELLOW}默认状态不启动代理${RESET}"
# 代理配置相关指令，如果需要代理请取消注释并修改为自己的代理地址
# sudo mkdir -p /etc/systemd/system/docker.service.d
# cat <<'EOF' | sudo tee /etc/systemd/system/docker.service.d/proxy.conf
# [Service]
# Environment="HTTP_PROXY=http://127.0.0.1:7890"
# Environment="HTTPS_PROXY=http://127.0.0.1:7890"
# Environment="NO_PROXY=localhost,127.0.0.1,::1,*.local,*.aliyuncs.com,*.docker.io"
# EOF
# sudo systemctl daemon-reload
# sudo systemctl restart docker

echo -e "${BLUE}==> 配置完成，进行拉取测试（alpine:latest）${RESET}"
if sudo docker pull alpine:latest; then
  echo -e "${GREEN}✓ 镜像拉取成功，显示镜像信息：${RESET}"
  sudo docker images alpine:latest
  echo -e "${BLUE}==> 清理测试镜像...${RESET}"
  if sudo docker rmi alpine:latest >/dev/null 2>&1; then
    echo -e "${GREEN}✓ 测试镜像已删除${RESET}"
  else
    echo -e "${YELLOW}⚠ 测试镜像删除失败（可能被容器占用），请手动检查${RESET}"
  fi
else
  echo -e "${RED}✗ 镜像拉取失败！请检查网络/DNS/镜像加速器或启用代理后重试。${RESET}"
  exit 2
fi

echo -e "${GREEN}🎉 全部完成！${RESET}"
