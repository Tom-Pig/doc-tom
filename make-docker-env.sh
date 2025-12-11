#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

GREEN="\033[1;32m"; RED="\033[1;31m"; BLUE="\033[1;34m"; YELLOW="\033[1;33m"; RESET="\033[0m"

echo -e "${BLUE}=== Docker 安装,宿主机必须存在代理===${RESET}"

# ----------------------------------------------------------
# 1. 检测宿主机代理
# ----------------------------------------------------------
HOST_HTTP_PROXY="${http_proxy:-${HTTP_PROXY:-}}"
HOST_HTTPS_PROXY="${https_proxy:-${HTTPS_PROXY:-}}"

if [[ -z "$HOST_HTTP_PROXY" && -z "$HOST_HTTPS_PROXY" ]]; then
  echo -e "${RED}⛔ 未检测到宿主机代理，Docker 下载可能极慢或失败${RESET}"
  echo -e "${YELLOW}⚠️ 例如可设置:${RESET}"
  echo -e "    export http_proxy=http://<ip>:<port>"
  echo -e "    export https_proxy=http://<ip>:<port>"
  exit 1
fi

echo -e "${GREEN}宿主机代理检测成功:${RESET}"
[[ -n "$HOST_HTTP_PROXY" ]]  && echo "  HTTP : $HOST_HTTP_PROXY"
[[ -n "$HOST_HTTPS_PROXY" ]] && echo "  HTTPS: $HOST_HTTPS_PROXY"

# ----------------------------------------------------------
# 2. APT 临时代理参数（保持原样）
# ----------------------------------------------------------
APT_PROXY_ARGS=()
[[ -n "$HOST_HTTP_PROXY"  ]] && APT_PROXY_ARGS+=("-oAcquire::http::Proxy=$HOST_HTTP_PROXY")
[[ -n "$HOST_HTTPS_PROXY" ]] && APT_PROXY_ARGS+=("-oAcquire::https::Proxy=$HOST_HTTPS_PROXY")

# ----------------------------------------------------------
# 3. 移除旧 Docker
# ----------------------------------------------------------
echo -e "${BLUE}==> 移除旧 Docker（不影响镜像/容器/数据）${RESET}"
sudo apt-get remove -y docker docker-engine docker.io containerd runc \
   docker-ce docker-ce-cli docker-compose docker-buildx-plugin docker-compose-plugin || true

sudo rm -rf /etc/docker /etc/apt/keyrings/docker.asc \
            /etc/apt/sources.list.d/docker.sources || true

# ----------------------------------------------------------
# 4. 更新 APT
# ----------------------------------------------------------
echo -e "${BLUE}==> 更新 APT（临时使用宿主机代理）${RESET}"
sudo apt-get update "${APT_PROXY_ARGS[@]}"

# ----------------------------------------------------------
# 5. 安装依赖
# ----------------------------------------------------------
sudo apt-get install -y ca-certificates curl gnupg lsb-release jq "${APT_PROXY_ARGS[@]}"

# ----------------------------------------------------------
# 6. Docker GPG key
# ----------------------------------------------------------
echo -e "${BLUE}==> 下载 Docker GPG 密钥${RESET}"
sudo install -m 0755 -d /etc/apt/keyrings

sudo http_proxy="$HOST_HTTP_PROXY" https_proxy="$HOST_HTTPS_PROXY" \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

sudo chmod a+r /etc/apt/keyrings/docker.asc

# ----------------------------------------------------------
# 7. 添加 Docker 源
# ----------------------------------------------------------
CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt-get update "${APT_PROXY_ARGS[@]}"

# ----------------------------------------------------------
# 8. 安装 Docker
# ----------------------------------------------------------
echo -e "${BLUE}==> 安装 Docker${RESET}"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin "${APT_PROXY_ARGS[@]}"

# ----------------------------------------------------------
# 9. Docker daemon 代理处理（回环地址替换为本机 IP + 安全 JSON）
# ----------------------------------------------------------
echo -e "${BLUE}==> 配置 Docker daemon 代理${RESET}"

resolve_loopback_to_host_ip() {
  local proxy="$1"

  # 如果不是 localhost 或 127.0.0.1，直接返回
  if [[ ! "$proxy" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)? ]]; then
    echo "$proxy"
    return
  fi

  # 获取本机的首个非 lo IPv4
  local host_ip
  host_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

  if [[ -z "$host_ip" ]]; then
    echo -e "${RED}未找到本机有效 IPv4，请检查网络${RESET}"
    exit 1
  fi

  # 替换回环地址
  echo "$proxy" | sed -E "s#(127\.0\.0\.1|localhost)#$host_ip#"
}

DOCKER_HTTP_PROXY=$( [[ -n "$HOST_HTTP_PROXY"  ]] && resolve_loopback_to_host_ip "$HOST_HTTP_PROXY"  )
DOCKER_HTTPS_PROXY=$( [[ -n "$HOST_HTTPS_PROXY" ]] && resolve_loopback_to_host_ip "$HOST_HTTPS_PROXY" )

sudo mkdir -p /etc/docker

daemon_json=$(jq -n \
  --arg http "$DOCKER_HTTP_PROXY" \
  --arg https "$DOCKER_HTTPS_PROXY" \
  '{
    proxies: {
      "http-proxy": $http,
      "https-proxy": $https,
      "no-proxy": "localhost,127.0.0.1"
    }
  }'
)
echo "$daemon_json" | sudo tee /etc/docker/daemon.json >/dev/null

# ----------------------------------------------------------
# 10. systemd 守护进程代理
# ----------------------------------------------------------
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<EOF
[Service]
EOF

[[ -n "$DOCKER_HTTP_PROXY"  ]] && echo "Environment=\"HTTP_PROXY=$DOCKER_HTTP_PROXY\"" | sudo tee -a /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
[[ -n "$DOCKER_HTTPS_PROXY" ]] && echo "Environment=\"HTTPS_PROXY=$DOCKER_HTTPS_PROXY\"" | sudo tee -a /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
echo 'Environment="NO_PROXY=localhost,127.0.0.1"' | sudo tee -a /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl restart docker

# ----------------------------------------------------------
# 11. ~/.docker/config.json 代理（安全 JSON）
# ----------------------------------------------------------
USER_HOME="${HOME}"
if [[ -n "${SUDO_USER:-}" ]]; then
    USER="$SUDO_USER"
    USER_HOME=$(eval echo "~$SUDO_USER")
else
    USER="$USER"
fi

mkdir -p "$USER_HOME/.docker"

docker_config_json=$(jq -n \
  --arg http "$DOCKER_HTTP_PROXY" \
  --arg https "$DOCKER_HTTPS_PROXY" \
  '{
    proxies: {
      default: {
        httpProxy: $http,
        httpsProxy: $https,
        noProxy: "localhost,127.0.0.1"
      }
    }
  }'
)

echo "$docker_config_json" | sudo tee "$USER_HOME/.docker/config.json" >/dev/null
sudo chown -R "$USER":"$USER" "$USER_HOME/.docker"



# ----------------------------------------------------------
# 13. 检测 Docker 代理是否正确配置
# ----------------------------------------------------------
echo -e "${BLUE}==> 检查 Docker 代理配置${RESET}"

HOST_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "${YELLOW}本机 IPv4: $HOST_IP${RESET}"
echo

echo -e "${BLUE}1) /etc/docker/daemon.json${RESET}"
if [[ -f /etc/docker/daemon.json ]]; then
    cat /etc/docker/daemon.json
    echo

    # 检查字段
    d_http=$(jq -r '.proxies["http-proxy"] // empty' /etc/docker/daemon.json)
    d_https=$(jq -r '.proxies["https-proxy"] // empty' /etc/docker/daemon.json)

    if [[ -n "$d_http" ]]; then
        echo -e "  HTTP 代理: ${GREEN}$d_http${RESET}"
    else
        echo -e "  HTTP 代理: ${RED}未配置${RESET}"
    fi

    if [[ -n "$d_https" ]]; then
        echo -e "  HTTPS 代理: ${GREEN}$d_https${RESET}"
    else
        echo -e "  HTTPS 代理: ${RED}未配置${RESET}"
    fi
else
    echo -e "${RED} 文件不存在: /etc/docker/daemon.json${RESET}"
fi

echo
echo -e "${BLUE}2) systemd docker.service.d/http-proxy.conf${RESET}"
if [[ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]]; then
    cat /etc/systemd/system/docker.service.d/http-proxy.conf
else
    echo -e "${RED} 文件不存在: /etc/systemd/system/docker.service.d/http-proxy.conf${RESET}"
fi

echo
echo -e "${BLUE}3) 用户 ~/.docker/config.json${RESET}"
if [[ -f "$USER_HOME/.docker/config.json" ]]; then
    cat "$USER_HOME/.docker/config.json"
    echo

    c_http=$(jq -r '.proxies.default.httpProxy // empty' "$USER_HOME/.docker/config.json")
    c_https=$(jq -r '.proxies.default.httpsProxy // empty' "$USER_HOME/.docker/config.json")

    if [[ -n "$c_http" ]]; then
        echo -e "  HTTP 代理: ${GREEN}$c_http${RESET}"
    else
        echo -e "  HTTP 代理: ${RED}未配置${RESET}"
    fi

    if [[ -n "$c_https" ]]; then
        echo -e "  HTTPS 代理: ${GREEN}$c_https${RESET}"
    else
        echo -e "  HTTPS 代理: ${RED}未配置${RESET}"
    fi
else
    echo -e "${RED} 文件不存在: $USER_HOME/.docker/config.json${RESET}"
fi

echo
echo -e "${GREEN} Docker 代理配置检查完成${RESET}"

# ----------------------------------------------------------
# 12. 验证安装
# ----------------------------------------------------------
echo -e "${BLUE}==> 验证 Docker 工作情况${RESET}"
sudo docker run --rm hello-world && echo -e "${GREEN}Docker 安装成功！${RESET}"

echo -e "${GREEN}=============================================="
echo -e " Docker 已安装并完成代理配置"
echo -e "==============================================${RESET}"

read -p "按 回车键退出..."

