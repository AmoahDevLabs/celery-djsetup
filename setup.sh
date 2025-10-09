#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Celery Django Setup Script
# Last modified: 9th Oct, 2025
# By: https://github.com/AmoahDevLabs
# ===============================

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && echo "🧪 Running in DRY-RUN mode: no changes will be made."

run_or_echo() {
  $DRY_RUN && echo "[DRY-RUN] $*" || eval "$@"
}

ask() {
  local prompt="$1" default="${2:-}" var
  read -rp "$prompt" var
  echo "${var:-$default}"
}

echo "=== Celery Setup Wizard ==="
PROJECT_NAME=$(ask "Enter project name (e.g., nhwiren): ")
LINUX_USER=$(ask "Enter user for service (e.g., nana): ")

id -u "$LINUX_USER" &>/dev/null || { echo "❌ User '$LINUX_USER' does not exist."; exit 1; }

PROJECT_DIR=$(ask "Enter project directory (Press Enter for default: [current directory]): " "$(pwd)")
[[ -d "$PROJECT_DIR" ]] || { echo "❌ Directory not found: $PROJECT_DIR"; exit 1; }

# --- Detect virtual environment ---
CUSTOM_VENV=$(ask "Virtualenv path (auto-detect if empty): ")
if [[ -n "$CUSTOM_VENV" ]]; then
  VENV_BIN="${CUSTOM_VENV%/}/bin"
else
  for v in ".venv" "venv" "env"; do
    [[ -x "$PROJECT_DIR/$v/bin/python" ]] && VENV_BIN="$PROJECT_DIR/$v/bin" && break
  done
fi

[[ -z "${VENV_BIN:-}" ]] && { echo "❌ Could not detect a virtualenv."; exit 1; }

PYTHON_BIN="$VENV_BIN/python"
CELERY_BIN="$VENV_BIN/celery"
CELERY_CMD="$CELERY_BIN"
[[ ! -x "$CELERY_BIN" ]] && CELERY_CMD="$PYTHON_BIN -m celery"

# --- Django settings ---
DJANGO_SETTINGS=$(ask "Django settings module (default: ${PROJECT_NAME}.settings): " "${PROJECT_NAME}.settings")

# --- Broker selection ---
echo "Select Celery broker backend:"
select BROKER in rabbitmq redis; do
  [[ "$BROKER" == "rabbitmq" || "$BROKER" == "redis" ]] && break
done
BROKER_SERVICE="${BROKER}-server.service"
[[ "$BROKER" == "redis" ]] && BROKER_SERVICE="redis.service"

# --- Log directory ---
LOG_DIR=$(ask "Log directory (default: /var/log/celery): " "/var/log/celery")
run_or_echo "sudo mkdir -p ${LOG_DIR} && sudo chown -R ${LINUX_USER}:${LINUX_USER} ${LOG_DIR}"

# --- Permissions ---
read -rp "Fix permissions for project/venv? (y/N): " fixperm
[[ "$fixperm" =~ ^[Yy]$ ]] && run_or_echo "sudo chown -R ${LINUX_USER}:${LINUX_USER} ${PROJECT_DIR} ${VENV_BIN%/bin}"

# --- Full Cleanup of Old Services and Files ---
echo "🧹 Checking and cleaning up existing Celery services for '${PROJECT_NAME}'..."
for svc in celery celerybeat; do
  SERVICE_NAME="${svc}-${PROJECT_NAME}.service"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
  PID_DIR="/run/celery-${PROJECT_NAME}"
  LOG_PATTERN="${LOG_DIR}/${PROJECT_NAME}-${svc}*.log"

  # Stop and disable if active
  if systemctl list-units --type=service --all | grep -q "${SERVICE_NAME}"; then
    run_or_echo "sudo systemctl stop ${SERVICE_NAME} 2>/dev/null || true"
    run_or_echo "sudo systemctl disable ${SERVICE_NAME} 2>/dev/null || true"
  fi

  # Remove old service file if it exists
  if [[ -f "$SERVICE_FILE" ]]; then
    echo "🗑 Removing old service file: $SERVICE_FILE"
    run_or_echo "sudo rm -f ${SERVICE_FILE}"
  fi

  # Remove stale PID directory
  if [[ -d "$PID_DIR" ]]; then
    echo "🧾 Clearing old PID directory: $PID_DIR"
    run_or_echo "sudo rm -rf ${PID_DIR}"
  fi

  # Clear old log files if present
  if compgen -G "$LOG_PATTERN" > /dev/null; then
    echo "🪶 Removing old log files: ${LOG_PATTERN}"
    run_or_echo "sudo rm -f ${LOG_PATTERN}"
  fi
done

# Reload systemd to apply cleanup
run_or_echo "sudo systemctl daemon-reload && sudo systemctl reset-failed"

RUNTIME_DIR="celery-${PROJECT_NAME}"

# --- Service templates ---
make_service() {
  local name="$1" cmd="$2" log="$3" pid="$4"
  cat <<EOF
[Unit]
Description=Celery ${name^} for ${PROJECT_NAME}
After=network.target ${BROKER_SERVICE}
Requires=${BROKER_SERVICE}

[Service]
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS}"
ExecStart=${CELERY_CMD} -A ${PROJECT_NAME} ${cmd} --loglevel=INFO --logfile=${LOG_DIR}/${PROJECT_NAME}-${log}.log --pidfile=/run/${RUNTIME_DIR}/${pid}.pid
Restart=always
RuntimeDirectory=${RUNTIME_DIR}
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
}

WORKER_FILE="/etc/systemd/system/celery-${PROJECT_NAME}.service"
BEAT_FILE="/etc/systemd/system/celerybeat-${PROJECT_NAME}.service"

if $DRY_RUN; then
  echo "[DRY-RUN] Would create $WORKER_FILE and $BEAT_FILE"
else
  make_service "Worker" "worker" "worker" "worker" | sudo tee "$WORKER_FILE" >/dev/null
  make_service "Beat" "beat" "beat" "beat" | sudo tee "$BEAT_FILE" >/dev/null
fi

run_or_echo "sudo systemctl daemon-reload"
run_or_echo "sudo systemctl enable celery-${PROJECT_NAME}.service celerybeat-${PROJECT_NAME}.service"

read -rp "Start services now? (y/N): " start_now
if [[ "$start_now" =~ ^[Yy]$ ]]; then
  run_or_echo "sudo systemctl restart celery-${PROJECT_NAME}.service celerybeat-${PROJECT_NAME}.service"
  echo "🚀 Celery services started."
else
  echo "✅ Setup complete. Start later with:"
  echo "  sudo systemctl start celery-${PROJECT_NAME}.service celerybeat-${PROJECT_NAME}.service"
fi

echo
echo "📋 Status commands:"
echo "  sudo systemctl status celery-${PROJECT_NAME}.service"
echo "  sudo systemctl status celerybeat-${PROJECT_NAME}.service"
echo "📜 Logs:"
echo "  sudo journalctl -u celery-${PROJECT_NAME}.service -f"
echo "  sudo journalctl -u celerybeat-${PROJECT_NAME}.service -f"

