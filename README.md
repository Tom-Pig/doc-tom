# doc-tom

`make-docker-env.sh` 是一个用于 Ubuntu 的 Docker 环境安装配置脚本。

## 数据库编排（`docker/`）

`docker/` 目录下是数据库服务的 Docker Compose 编排，采用「base + override」多环境结构：

| 文件 | 作用 |
| --- | --- |
| `compose.yaml` | 基础定义（生产安全基线：不暴露端口、密码强制注入、root 收紧） |
| `compose.override.yaml` | 开发覆盖（暴露 3306/5432 供宿主机图形化工具直连），`docker compose` 自动加载 |
| `.env.example` | 环境变量模板，复制为 `.env` 并修改其中的密码 |
| `mysql/`、`postgres/` | 配置（`conf.d/*.cnf`）与初始化脚本（`init/*.sql`）挂载目录 |

### 快速开始（开发环境）

```bash
cd docker
cp .env.example .env      # 修改其中的密码
docker compose up -d
```

`docker compose up -d` 会同时加载 `compose.yaml` 与 `compose.override.yaml`，
数据库端口（默认 3306/5432）暴露在宿主机，可用 Navicat / DBeaver 直连。

> 图形化工具请用业务账号（`.env` 中的 `MYSQL_USER` / `POSTGRES_USER`）连接，
> 不要用 `root`——`root` 已收紧为仅容器内 localhost 管理用。

### 生产环境

```bash
cd docker
docker compose -f compose.yaml up -d   # 只加载 base，不暴露端口
```

数据库端口不暴露到宿主机，仅在容器网络内可达；运维通过 SSH 隧道或内网跳板访问。

### 服务清单

- MySQL 8.4（LTS）：数据卷 `doc-tom-mysql-data`
- PostgreSQL 16：数据卷 `doc-tom-pg-data`
