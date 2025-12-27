#!/usr/bin/env bash

# 用途：本地一键更新服务器版本（同步代码、构建镜像、重建容器、健康检查）
# 入参：通过环境变量覆盖默认值
# 返回：非 0 表示失败
# 约束：需在项目根目录执行；服务器需可 SSH；服务器已安装 Docker

set -euo pipefail

# 服务器 SSH 用户名
SSH_USER="${SSH_USER:-root}"
# 服务器地址或 IP
SERVER_HOST="${SERVER_HOST:-115.190.219.24}"
# 服务器 SSH 端口
SSH_PORT="${SSH_PORT:-22}"
# SSH 私钥路径（为空表示使用默认密钥或 ssh-agent）
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
# 远端项目目录
REMOTE_DIR="${REMOTE_DIR:-/root/xianyu-auto-reply}"
# 服务端口（容器与宿主保持一致）
APP_PORT="${APP_PORT:-10293}"
# 管理员密码（必须显式设置，避免空口令）
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
# 构建使用的 Dockerfile 文件名
DOCKERFILE="${DOCKERFILE:-Dockerfile-cn}"
# 构建镜像标签
IMAGE_TAG="${IMAGE_TAG:-xianyu-auto-reply:local}"
# 容器名称
CONTAINER_NAME="${CONTAINER_NAME:-xianyu-auto-reply}"
# 是否强制将 API 绑定到 0.0.0.0
FORCE_BIND_ALL="${FORCE_BIND_ALL:-true}"

# SSH 连接参数数组
SSH_OPTS=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

if [[ -n "${SSH_KEY_PATH}" ]]; then
  SSH_OPTS+=(-i "${SSH_KEY_PATH}")
fi

# 作用：输出信息日志
# 入参：$1 日志文本
# 返回：无
# 约束：入参不能为空
log_info() {
  printf '[INFO] %s\n' "$1"
}

# 作用：输出错误日志
# 入参：$1 错误文本
# 返回：无
# 约束：入参不能为空
log_error() {
  printf '[ERROR] %s\n' "$1" >&2
}

# 作用：输出错误并退出脚本
# 入参：$1 错误文本
# 返回：无（脚本退出）
# 约束：入参不能为空
die() {
  log_error "$1"
  exit 1
}

# 作用：检测本地依赖
# 入参：无
# 返回：无
# 约束：rsync 与 ssh 必须可用
check_dependencies() {
  command -v rsync >/dev/null 2>&1 || die "未找到 rsync，请先安装"
  command -v ssh >/dev/null 2>&1 || die "未找到 ssh，请先安装"
}

# 作用：构建 rsync 连接用的 ssh 命令
# 入参：无
# 返回：打印 ssh 命令字符串
# 约束：当 SSH_KEY_PATH 非空时，需要保证路径可读
build_rsync_ssh_cmd() {
  local cmd
  cmd="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    cmd+=" -i \"${SSH_KEY_PATH}\""
  fi
  printf '%s' "${cmd}"
}

# 作用：执行远程命令
# 入参：$1 远程命令字符串
# 返回：透传 ssh 的退出码
# 约束：命令需自行处理引用，避免引号冲突
ssh_run() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_HOST}" "$1"
}

# 作用：转义单引号，便于安全拼接到单引号字符串中
# 入参：$1 原始字符串
# 返回：转义后的字符串
# 约束：仅用于单引号上下文
escape_single_quotes() {
  printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

# 作用：同步本地代码到服务器
# 入参：无
# 返回：无
# 约束：默认不覆盖 data/logs 等持久化目录
sync_code() {
  local rsync_ssh_cmd
  rsync_ssh_cmd="$(build_rsync_ssh_cmd)"
  log_info "开始同步代码到服务器..."
  rsync -az -e "${rsync_ssh_cmd}" \
    --exclude '.git/' \
    --exclude 'data/' \
    --exclude 'logs/' \
    --exclude 'browser_data/' \
    --exclude 'tmp_ocr/' \
    --exclude 'trajectory_history/' \
    --exclude 'backups/' \
    --exclude '*.db' \
    --exclude '*.log' \
    ./ "${SSH_USER}@${SERVER_HOST}:${REMOTE_DIR}/"
  log_info "代码同步完成"
}

# 作用：确保 API 绑定到 0.0.0.0（便于公网访问）
# 入参：无
# 返回：无
# 约束：仅在 FORCE_BIND_ALL=true 时执行
ensure_bind_all() {
  if [[ "${FORCE_BIND_ALL}" != "true" ]]; then
    return 0
  fi
  log_info "更新服务绑定地址为 0.0.0.0"
  ssh_run "sed -i 's/host: 127.0.0.1/host: 0.0.0.0/' ${REMOTE_DIR}/global_config.yml"
}

# 作用：远程构建镜像
# 入参：无
# 返回：无
# 约束：Dockerfile 必须存在
build_image() {
  log_info "开始构建镜像：${IMAGE_TAG}"
  ssh_run "test -f ${REMOTE_DIR}/${DOCKERFILE}"
  ssh_run "cd ${REMOTE_DIR} && docker build -f ${DOCKERFILE} -t ${IMAGE_TAG} ."
  log_info "镜像构建完成"
}

# 作用：重建容器并加载新镜像
# 入参：无
# 返回：无
# 约束：ADMIN_PASSWORD 不能为空
recreate_container() {
  local password_escaped
  password_escaped="$(escape_single_quotes "${ADMIN_PASSWORD}")"
  log_info "重建容器：${CONTAINER_NAME}"
  ssh_run "docker rm -f ${CONTAINER_NAME} >/dev/null 2>&1 || true"
  ssh_run "docker run -d --restart always --name ${CONTAINER_NAME} \
    -p ${APP_PORT}:${APP_PORT} \
    -e API_PORT=${APP_PORT} \
    -e ADMIN_PASSWORD='${password_escaped}' \
    -v ${REMOTE_DIR}/data:/app/data:rw \
    -v ${REMOTE_DIR}/logs:/app/logs:rw \
    -v ${REMOTE_DIR}/backups:/app/backups:rw \
    -v ${REMOTE_DIR}/global_config.yml:/app/global_config.yml:ro \
    ${IMAGE_TAG}"
  log_info "容器启动完成"
}

# 作用：健康检查
# 入参：无
# 返回：无
# 约束：服务可能需要一定启动时间
health_check() {
  log_info "等待服务就绪..."
  sleep 5
  ssh_run "curl -sS http://127.0.0.1:${APP_PORT}/health"
  log_info "健康检查通过"
}

# 作用：主流程入口
# 入参：无
# 返回：无
# 约束：ADMIN_PASSWORD 必须提供
main() {
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    die "ADMIN_PASSWORD 为空，请先设置环境变量"
  fi
  check_dependencies
  sync_code
  ensure_bind_all
  build_image
  recreate_container
  health_check
}

main "$@"
