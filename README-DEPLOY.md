# 服务器更新流程（本地二开代码）

适用场景：你在本地修改了代码，需要将最新版部署到服务器，并替换正在运行的容器。

## 1. 准备信息

请先准备以下变量：
- 服务器 IP：`<服务器IP>`
- SSH 私钥路径（如有）：`<私钥路径>`
- 服务端口：`<端口>`（默认示例为 `10293`）
- 管理员密码：`<管理员密码>`

## 1.1 一键脚本（推荐）

项目根目录提供了 `deploy-server.sh`，适合日常快速更新。

```bash
# 进入项目根目录
cd /path/to/xianyu-auto-reply

# 配置环境变量
export SERVER_HOST=<服务器IP>
export SSH_KEY_PATH=<私钥路径>
export APP_PORT=10293
export ADMIN_PASSWORD=<管理员密码>

# 执行更新
bash deploy-server.sh
```

脚本默认会：
1. rsync 同步代码（不会覆盖 data/logs 等持久化目录）
2. 远端构建镜像（默认 Dockerfile-cn）
3. 重建容器并做健康检查

如需自定义，可通过环境变量覆盖：
- `SSH_USER`：SSH 用户名，默认 `root`
- `SSH_PORT`：SSH 端口，默认 `22`
- `REMOTE_DIR`：服务器目录，默认 `/root/xianyu-auto-reply`
- `DOCKERFILE`：默认 `Dockerfile-cn`
- `IMAGE_TAG`：默认 `xianyu-auto-reply:local`
- `CONTAINER_NAME`：默认 `xianyu-auto-reply`
- `FORCE_BIND_ALL`：默认 `true`（自动把 `host` 改成 `0.0.0.0`）

## 2. 同步代码到服务器

默认不覆盖 `data/`（数据库）与 `logs/`（日志），避免误覆盖线上数据。

```bash
rsync -az \
  --exclude '.git/' \
  --exclude 'data/' \
  --exclude 'logs/' \
  --exclude 'browser_data/' \
  --exclude 'tmp_ocr/' \
  --exclude 'trajectory_history/' \
  --exclude 'backups/' \
  --exclude '*.db' \
  --exclude '*.log' \
  ./ root@<服务器IP>:/root/xianyu-auto-reply/
```

如果 SSH 需要私钥：
```bash
rsync -az -e "ssh -i <私钥路径>" \
  --exclude '.git/' \
  --exclude 'data/' \
  --exclude 'logs/' \
  --exclude 'browser_data/' \
  --exclude 'tmp_ocr/' \
  --exclude 'trajectory_history/' \
  --exclude 'backups/' \
  --exclude '*.db' \
  --exclude '*.log' \
  ./ root@<服务器IP>:/root/xianyu-auto-reply/
```

## 3. 调整对外访问配置（如需）

若要从公网访问，需要让 API 绑定到 `0.0.0.0`。

```bash
ssh root@<服务器IP> "sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' /root/xianyu-auto-reply/global_config.yml"
```

如果 SSH 需要私钥：
```bash
ssh -i <私钥路径> root@<服务器IP> "sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' /root/xianyu-auto-reply/global_config.yml"
```

## 4. 构建镜像

国内网络建议使用 `Dockerfile-cn`：
```bash
ssh root@<服务器IP> "cd /root/xianyu-auto-reply && docker build -f Dockerfile-cn -t xianyu-auto-reply:local ."
```

## 5. 重建容器

```bash
ssh root@<服务器IP> "docker rm -f xianyu-auto-reply || true"
ssh root@<服务器IP> "docker run -d --restart always --name xianyu-auto-reply \
  -p <端口>:<端口> \
  -e API_PORT=<端口> \
  -e ADMIN_PASSWORD='<管理员密码>' \
  -v /root/xianyu-auto-reply/data:/app/data:rw \
  -v /root/xianyu-auto-reply/logs:/app/logs:rw \
  -v /root/xianyu-auto-reply/backups:/app/backups:rw \
  -v /root/xianyu-auto-reply/global_config.yml:/app/global_config.yml:ro \
  xianyu-auto-reply:local"
```

如果 SSH 需要私钥，把 `ssh` 命令改成 `ssh -i <私钥路径> ...` 即可。

## 6. 验证服务

```bash
ssh root@<服务器IP> "curl -sS http://127.0.0.1:<端口>/health"
```

对外访问地址：
```
http://<服务器IP>:<端口>/
```

## 常见问题

- **容器健康检查显示异常**：Dockerfile 的健康检查默认指向 `8080`，但你可能运行在 `10293`。这不影响实际服务，可忽略或自行调整健康检查。
- **无法公网访问**：检查安全组/防火墙是否放行端口；并确认 `global_config.yml` 中 `AUTO_REPLY.api.host` 为 `0.0.0.0`。
- **构建依赖下载慢**：优先使用 `Dockerfile-cn`，并确保服务器可访问国内镜像源与 Playwright 镜像站。
