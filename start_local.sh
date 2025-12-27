#!/usr/bin/env bash
set -euo pipefail

# PROJECT_ROOT 用途：项目根目录路径，作为所有相对路径基准
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# VENV_DIR 用途：Python 虚拟环境目录，用于隔离依赖
VENV_DIR="${PROJECT_ROOT}/.venv"

# ENV_FILE 用途：运行环境变量文件路径，必须包含基础运行配置
ENV_FILE="${PROJECT_ROOT}/.env"

# LOG_DIR 用途：本地启动日志目录，保存运行日志与 PID 文件
LOG_DIR="${PROJECT_ROOT}/logs"

# LOG_FILE 用途：本地启动日志文件，便于排查启动问题
LOG_FILE="${LOG_DIR}/local_run.log"

# PYTHON_BIN 用途：虚拟环境内 Python 解释器路径，用于启动服务
PYTHON_BIN="${VENV_DIR}/bin/python"

# load_env 用途：加载 .env 并导出环境变量
# 入参：无；返回值：无；约束：.env 必须存在
load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "未找到 .env，请先创建并配置：$ENV_FILE" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  # SERVICE_PORT 用途：服务监听端口（来自 API_PORT），用于端口占用检测
  SERVICE_PORT="${API_PORT:-18080}"
}

# ensure_python 用途：确保虚拟环境与依赖存在
# 入参：无；返回值：无；约束：系统需安装 python3
ensure_python() {
  if [ -x "$PYTHON_BIN" ]; then
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "未找到 python3，请先安装 Python 3 后再运行。" >&2
    exit 1
  fi

  python3 -m venv "$VENV_DIR"
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r "$PROJECT_ROOT/requirements.txt"
}

# check_port 用途：检测端口占用，避免重复启动
# 入参：无；返回值：无；约束：lsof 可用时才检测
check_port() {
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$SERVICE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "端口 $SERVICE_PORT 已被占用，请先停止占用进程或修改 API_PORT。" >&2
      exit 1
    fi
  fi
}

# start_service 用途：后台启动服务并写入 PID 文件
# 入参：无；返回值：无；约束：依赖 Start.py
start_service() {
  mkdir -p "$LOG_DIR"
  export PYTHONUNBUFFERED=1

  nohup "$PYTHON_BIN" "$PROJECT_ROOT/Start.py" > "$LOG_FILE" 2>&1 &

  # pid 用途：记录后台进程 PID，便于后续停止服务
  local pid=$!
  echo "$pid" > "$LOG_DIR/local_run.pid"

  echo "已启动：PID=$pid"
  echo "访问地址：http://${API_HOST:-127.0.0.1}:$SERVICE_PORT"
  echo "日志文件：$LOG_FILE"
}

load_env
ensure_python
check_port
start_service
