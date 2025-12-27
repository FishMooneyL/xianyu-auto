#!/usr/bin/env bash
set -euo pipefail

# PROJECT_ROOT 用途：项目根目录路径，用于定位配置与脚本资源
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ENV_FILE 用途：环境变量文件路径，用于加载启动配置
ENV_FILE="${PROJECT_ROOT}/.env"

# ONE_CLICK_MODE 用途：启动模式（auto/local/docker），来自脚本第一个参数
ONE_CLICK_MODE="${1:-auto}"

# VENV_DIR 用途：Python 虚拟环境目录，用于隔离依赖
VENV_DIR="${PROJECT_ROOT}/.venv"

# PYTHON_BIN 用途：虚拟环境 Python 解释器路径，用于启动服务
PYTHON_BIN="${VENV_DIR}/bin/python"

# LOG_DIR 用途：日志目录，用于保存一键启动日志与 PID
LOG_DIR="${PROJECT_ROOT}/logs"

# LOG_FILE 用途：一键启动日志文件路径，便于排查启动问题
LOG_FILE="${LOG_DIR}/one_click_start.log"

# PID_FILE 用途：记录本地启动 PID，便于定位与停止进程
PID_FILE="${LOG_DIR}/one_click_start.pid"

# DEFAULT_COMPOSE_FILE 用途：Docker Compose 默认配置文件路径
DEFAULT_COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"

# CN_COMPOSE_FILE 用途：国内镜像 Docker Compose 配置文件路径
CN_COMPOSE_FILE="${PROJECT_ROOT}/docker-compose-cn.yml"

# RUN_MODE 用途：最终生效的启动模式（local/docker）
RUN_MODE=""

# COMPOSE_CMD 用途：Docker Compose 命令数组（支持 docker compose / docker-compose）
COMPOSE_CMD=()

# print_info 用途：输出普通提示信息
# 入参：$1=提示内容
# 返回值：无
# 约束：仅用于用户可读输出
print_info() {
  echo "ℹ️  $1"
}

# print_success 用途：输出成功提示信息
# 入参：$1=提示内容
# 返回值：无
# 约束：仅用于用户可读输出
print_success() {
  echo "✅ $1"
}

# print_error 用途：输出错误提示信息
# 入参：$1=提示内容
# 返回值：无
# 约束：仅用于用户可读输出，调用方需自行终止流程
print_error() {
  echo "❌ $1" >&2
}

# has_command 用途：判断命令是否存在
# 入参：$1=命令名称
# 返回值：存在返回 0，否则返回 1
# 约束：仅用于检测系统依赖
has_command() {
  command -v "$1" >/dev/null 2>&1
}

# load_env 用途：加载 .env 并导出启动所需环境变量
# 入参：无
# 返回值：无
# 约束：.env 必须存在，否则终止
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    print_error "未找到 .env，请先创建并配置：$ENV_FILE"
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  # API_HOST 用途：本地启动绑定地址，默认回退到 127.0.0.1
  API_HOST="${API_HOST:-127.0.0.1}"
  # API_PORT 用途：本地启动监听端口，默认回退到 8080
  API_PORT="${API_PORT:-8080}"
  # WEB_PORT 用途：Docker 暴露端口，默认回退到 8080
  WEB_PORT="${WEB_PORT:-8080}"
  # SKIP_PLAYWRIGHT_INSTALL 用途：是否跳过 Playwright 浏览器安装
  SKIP_PLAYWRIGHT_INSTALL="${SKIP_PLAYWRIGHT_INSTALL:-false}"
  # PLAYWRIGHT_INSTALL_DEPS 用途：是否额外安装 Playwright 系统依赖
  PLAYWRIGHT_INSTALL_DEPS="${PLAYWRIGHT_INSTALL_DEPS:-false}"
  # USE_DOCKER_CN 用途：是否使用国内 Docker Compose 配置
  USE_DOCKER_CN="${USE_DOCKER_CN:-false}"
  # DOCKER_COMPOSE_FILE 用途：自定义 Docker Compose 配置文件相对路径
  DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-}"
}

# ensure_runtime_dirs 用途：创建运行所需目录
# 入参：无
# 返回值：无
# 约束：目录创建失败时终止
ensure_runtime_dirs() {
  mkdir -p "$LOG_DIR" "$PROJECT_ROOT/data" "$PROJECT_ROOT/backups"
}

# resolve_start_mode 用途：确定最终启动模式
# 入参：$1=用户传入模式（auto/local/docker）
# 返回值：通过全局变量 RUN_MODE 输出
# 约束：仅接受 auto/local/docker
resolve_start_mode() {
  # requested 用途：用户传入的启动模式入参
  local requested="$1"

  case "$requested" in
    auto|local|docker)
      ;;
    *)
      print_error "未知模式：$requested（仅支持 auto/local/docker）"
      exit 1
      ;;
  esac

  if [ "$requested" = "auto" ]; then
    if has_command docker && docker info >/dev/null 2>&1; then
      RUN_MODE="docker"
    else
      RUN_MODE="local"
    fi
    return
  fi

  RUN_MODE="$requested"
}

# resolve_compose_cmd 用途：确定 Docker Compose 可用命令
# 入参：无
# 返回值：通过全局变量 COMPOSE_CMD 输出
# 约束：仅在 docker 模式下调用
resolve_compose_cmd() {
  if has_command docker-compose; then
    COMPOSE_CMD=(docker-compose)
    return
  fi

  if has_command docker && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi

  print_error "未找到 Docker Compose，请先安装 docker-compose 或升级 Docker"
  exit 1
}

# ensure_python 用途：确保 Python 虚拟环境与依赖就绪
# 入参：无
# 返回值：无
# 约束：系统需可用 python3 且可访问 requirements.txt
ensure_python() {
  if [ -x "$PYTHON_BIN" ]; then
    return
  fi

  if ! has_command python3; then
    print_error "未找到 python3，请先安装 Python 3 后再运行。"
    exit 1
  fi

  python3 -m venv "$VENV_DIR"
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r "$PROJECT_ROOT/requirements.txt"
}

# ensure_playwright 用途：按需安装 Playwright 浏览器依赖
# 入参：无
# 返回值：无
# 约束：仅在 SKIP_PLAYWRIGHT_INSTALL!=true 时执行
ensure_playwright() {
  if [ "$SKIP_PLAYWRIGHT_INSTALL" = "true" ]; then
    return
  fi

  if "$PYTHON_BIN" -m playwright install chromium; then
    if [ "$PLAYWRIGHT_INSTALL_DEPS" = "true" ]; then
      "$PYTHON_BIN" -m playwright install-deps chromium
    fi
    return
  fi

  print_error "Playwright 安装失败，请检查网络或手动安装。"
  exit 1
}

# check_port 用途：检测端口是否被占用
# 入参：无
# 返回值：无
# 约束：仅在本地启动时检测，可用 lsof 才执行
check_port() {
  if has_command lsof; then
    if lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      print_error "端口 $API_PORT 已被占用，请先释放端口或调整 API_PORT。"
      exit 1
    fi
  fi
}

# start_local 用途：本地后台启动服务
# 入参：无
# 返回值：无
# 约束：依赖 Start.py 与 Python 运行环境
start_local() {
  print_info "使用本地模式启动..."

  ensure_python
  ensure_playwright
  check_port

  # PYTHONUNBUFFERED 用途：禁用输出缓冲，便于实时写日志
  export PYTHONUNBUFFERED=1
  nohup "$PYTHON_BIN" "$PROJECT_ROOT/Start.py" > "$LOG_FILE" 2>&1 &

  # pid 用途：记录后台进程 PID，便于排查与停止
  local pid=$!
  echo "$pid" > "$PID_FILE"

  print_success "本地服务已启动：PID=$pid"
  print_success "访问地址：http://${API_HOST}:${API_PORT}"
  print_success "日志文件：$LOG_FILE"
}

# start_docker 用途：使用 Docker Compose 启动服务
# 入参：无
# 返回值：无
# 约束：需可用 Docker 与 Docker Compose
start_docker() {
  print_info "使用 Docker 模式启动..."

  resolve_compose_cmd

  # compose_file 用途：Docker Compose 配置文件路径
  local compose_file="$DEFAULT_COMPOSE_FILE"
  if [ "$USE_DOCKER_CN" = "true" ]; then
    compose_file="$CN_COMPOSE_FILE"
  fi
  if [ -n "$DOCKER_COMPOSE_FILE" ]; then
    compose_file="$PROJECT_ROOT/$DOCKER_COMPOSE_FILE"
  fi

  "${COMPOSE_CMD[@]}" -f "$compose_file" up -d --build

  print_success "Docker 服务已启动"
  print_success "访问地址：http://localhost:${WEB_PORT}"
}

# main 用途：脚本主流程入口
# 入参：无
# 返回值：无
# 约束：按 RUN_MODE 分流执行
main() {
  load_env
  ensure_runtime_dirs
  resolve_start_mode "$ONE_CLICK_MODE"

  if [ "$RUN_MODE" = "docker" ]; then
    start_docker
    return
  fi

  start_local
}

main
