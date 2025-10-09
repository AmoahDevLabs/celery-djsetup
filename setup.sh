#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Celery Django Setup Script
# Last modified: 9th Oct, 2025 @ 22:28
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
LINUX_USER=$(ask "Enter user for the project (e.g., nana): ")

id -u "$LINUX_USER" &>/dev/null || { echo "❌ User '$LINUX_USER' does not exist."; exit 1; }

PROJECT_DIR=$(ask "Enter full path for project directory (e.g., /opt/nhwiren): ")
[[ -d "$PROJECT_DIR" ]] || { echo "❌ Directory not found: $PROJECT_DIR"; exit 1; }

# --- Detect or Create Virtual Environment ---
CUSTOM_VENV=$(ask "Virtualenv path (auto-detect/create if empty): ")

if [[ -n "$CUSTOM_VENV" ]]; then
  VENV_PATH="${CUSTOM_VENV%/}"
else
  for v in ".venv" "venv" "env"; do
    if [[ -x "$PROJECT_DIR/$v/bin/python" ]]; then
      VENV_PATH="$PROJECT_DIR/$v"
      break
    fi
  done
fi

# --- Handle missing virtualenv ---
if [[ -z "${VENV_PATH:-}" ]]; then
  echo "⚙️  No virtual environment detected. Preparing to create one..."

  if [[ ! -w "$PROJECT_DIR" ]]; then
    echo "🔒 Insufficient permissions on $PROJECT_DIR"
    echo "🔧 Resolving permissions for user '${LINUX_USER}'..."
    run_or_echo "sudo chown -R ${LINUX_USER}:${LINUX_USER} ${PROJECT_DIR}"
    run_or_echo "sudo chmod -R 755 ${PROJECT_DIR}"
  fi

  VENV_PATH="$PROJECT_DIR/.venv"
  echo "🐍 Creating virtual environment at: $VENV_PATH"
  if $DRY_RUN; then
    echo "[DRY-RUN] python3 -m venv $VENV_PATH"
  else
    sudo -u "$LINUX_USER" python3 -m venv "$VENV_PATH"
  fi
  echo "✅ Virtual environment created successfully."
else
  echo "✅ Detected existing virtual environment: $VENV_PATH"
fi

VENV_BIN="${VENV_PATH%/}/bin"
PYTHON_BIN="$VENV_BIN/python"
PIP_BIN="$VENV_BIN/pip"
CELERY_BIN="$VENV_BIN/celery"
CELERY_CMD="$CELERY_BIN"
[[ ! -x "$CELERY_BIN" ]] && CELERY_CMD="$PYTHON_BIN -m celery"

# --- Verify Python in venv ---
if ! $PYTHON_BIN -V &>/dev/null; then
  echo "❌ Failed to locate Python executable in virtual environment."
  exit 1
fi

# --- Inform user about package installation ---
echo "📦 Installing required Python packages inside the virtual environment..."
if [[ -f "$PROJECT_DIR/requirements.txt" ]]; then
  echo "🔍 Found requirements.txt — installing dependencies..."
  run_or_echo "$PIP_BIN install --upgrade pip"
  run_or_echo "$PIP_BIN install -r $PROJECT_DIR/requirements.txt --progress-bar on"
else
  echo "⚠️  No requirements.txt found. Installing celery (and common extras)..."
  run_or_echo "$PIP_BIN install --upgrade pip"
  run_or_echo "$PIP_BIN install 'celery' --progress-bar on"
fi
echo "✅ Package installation complete."

# --- Verify Celery Installation ---
if ! "$PYTHON_BIN" -m celery --version &>/dev/null; then
  echo "❌ Celery installation failed or not found in the virtual environment."
  echo "Attempting to reinstall Celery..."
  run_or_echo "$PIP_BIN install 'celery' --progress-bar on"
  "$PYTHON_BIN" -m celery --version >/dev/null || { echo "❌ Celery installation still missing. Aborting."; exit 1; }
fi

echo "✅ Celery successfully installed in virtual environment."

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

# --- Permissions prompt ---
read -rp "Resolve permissions for project/venv? (y/N): " fixperm
[[ "$fixperm" =~ ^[Yy]$ ]] && run_or_echo "sudo chown -R ${LINUX_USER}:${LINUX_USER} ${PROJECT_DIR} ${VENV_PATH}"

# --- Cleanup old services ---
echo "🧹 Checking and cleaning up existing Celery services for '${PROJECT_NAME}'..."
for svc in celery celerybeat; do
  SERVICE_NAME="${svc}-${PROJECT_NAME}.service"
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
  PID_DIR="/run/celery-${PROJECT_NAME}"
  LOG_PATTERN="${LOG_DIR}/${PROJECT_NAME}-${svc}*.log"

  if systemctl list-units --type=service --all | grep -q "${SERVICE_NAME}"; then
    run_or_echo "sudo systemctl stop ${SERVICE_NAME} 2>/dev/null || true"
    run_or_echo "sudo systemctl disable ${SERVICE_NAME} 2>/dev/null || true"
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    echo "🗑 Removing old service file: $SERVICE_FILE"
    run_or_echo "sudo rm -f ${SERVICE_FILE}"
  fi

  if [[ -d "$PID_DIR" ]]; then
    echo "🧾 Clearing old PID directory: $PID_DIR"
    run_or_echo "sudo rm -rf ${PID_DIR}"
  fi

  if compgen -G "$LOG_PATTERN" > /dev/null; then
    echo "🪶 Removing old log files: ${LOG_PATTERN}"
    run_or_echo "sudo rm -f ${LOG_PATTERN}"
  fi
done

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

# ---------- SECRET_KEY detection ----------
check_secret_key() {
  echo "🔍 Checking for SECRET_KEY value in Django settings (${DJANGO_SETTINGS})..."

  local result
  result=$("$PYTHON_BIN" - <<EOF 2>/dev/null
import os, sys, django
sys.path.insert(0, os.path.abspath("${PROJECT_DIR}"))
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "${DJANGO_SETTINGS}")
try:
    django.setup()
    from django.conf import settings
    print(bool(getattr(settings, "SECRET_KEY", None)))
except Exception:
    print("ERROR")
EOF
)

  if [[ "$result" == "True" ]]; then
    echo "✅ SECRET_KEY found and has a value in Django settings (${DJANGO_SETTINGS})."
    return 0
  elif [[ "$result" == "ERROR" ]]; then
    echo "⚠️  Could not import Django or load settings module (${DJANGO_SETTINGS})."
    echo "Ensure the virtual environment and DJANGO_SETTINGS_MODULE are correct."
    return 1
  else
    echo "⚠️  SECRET_KEY missing or empty in Django settings (${DJANGO_SETTINGS})."
    return 1
  fi
}

# Run check and warn user — do not auto-generate
if ! check_secret_key; then
  read -rp "SECRET_KEY not found. Continue and write systemd units anyway? (y/N): " cont
  if [[ ! "$cont" =~ ^[Yy]$ ]]; then
    echo "Aborting per user request. Please set SECRET_KEY and re-run the script."
    exit 1
  fi
fi
# ---------- end SECRET_KEY detection ----------

run_or_echo "sudo systemctl daemon-reload"
run_or_echo "sudo systemctl enable celery-${PROJECT_NAME}.service celerybeat-${PROJECT_NAME}.service"

read -rp "Start services now? (y/N): " start_now
if [[ "$start_now" =~ ^[Yy]$ ]]; then
  run_or_echo "sudo systemctl restart celery-${PROJECT_NAME}.service celerybeat-${PROJECT_NAME}.service"
  echo "🚀 Celery services started successfully."
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

