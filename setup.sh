#!/bin/bash

print_usage() {
  echo "Usage: $0"
  echo "This script will interactively set up Celery services for your Django project."
  exit 1
}

set -o errexit
set -o nounset
set -o pipefail

echo "Welcome to the Celery setup script."
echo "Please provide the following information:"

read -p "Enter your project name (e.g., 'nhwiren'): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
  echo "❌ Project name cannot be empty."
  exit 1
fi

read -p "Enter the Linux user for the service (e.g., 'nana'): " LINUX_USER
if [ -z "$LINUX_USER" ]; then
  echo "❌ Linux user cannot be empty."
  exit 1
fi

# verify user exists
if ! id -u "$LINUX_USER" >/dev/null 2>&1; then
  echo "❌ Linux user '$LINUX_USER' does not exist. Please create the user or provide an existing user."
  exit 1
fi

read -p "Enter the full path to your project directory (press Enter for current directory): " CUSTOM_PROJECT_DIR
if [ -n "$CUSTOM_PROJECT_DIR" ]; then
  PROJECT_DIR="$CUSTOM_PROJECT_DIR"
else
  PROJECT_DIR="$(pwd)"
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "❌ Project directory not found: $PROJECT_DIR"
  exit 1
fi

# --- Virtualenv detection ---
read -p "Enter the full path to your virtual environment (press Enter for auto-detect): " CUSTOM_VENV
if [ -n "$CUSTOM_VENV" ]; then
  VENV_BIN="$CUSTOM_VENV/bin"
else
  VENV_BIN=""
  for candidate in ".venv" "venv" "env"; do
    if [ -x "$PROJECT_DIR/$candidate/bin/python" ]; then
      VENV_BIN="$PROJECT_DIR/$candidate/bin"
      break
    fi
  done
  # broaden detection: look for any subdir that looks like a venv
  if [ -z "$VENV_BIN" ]; then
    for d in "$PROJECT_DIR"/*; do
      if [ -x "$d/bin/python" ]; then
        VENV_BIN="$d/bin"
        break
      fi
    done
  fi
fi

if [ -z "$VENV_BIN" ]; then
  echo "❌ Could not detect virtual environment. Please run the script again and provide the path to your virtualenv."
  exit 1
fi

# --- Settings module flexibility ---
read -p "Enter your Django settings module (default: ${PROJECT_NAME}.settings): " CUSTOM_SETTINGS
if [ -n "$CUSTOM_SETTINGS" ]; then
  DJANGO_SETTINGS="$CUSTOM_SETTINGS"
else
  DJANGO_SETTINGS="${PROJECT_NAME}.settings"
fi

# --- Broker choice ---
echo "Select your Celery broker backend:"
PS3="Broker (choose number): "
select BROKER in "rabbitmq" "redis"; do
  case $BROKER in
    rabbitmq)
      BROKER_SERVICE="rabbitmq-server.service"
      break
      ;;
    redis)
      BROKER_SERVICE="redis.service"
      break
      ;;
    *)
      echo "Invalid option. Please select 1 or 2."
      ;;
  esac
done

read -p "Enter log directory (default: /var/log/celery): " CUSTOM_LOG_DIR
if [ -n "$CUSTOM_LOG_DIR" ]; then
  LOG_DIR="$CUSTOM_LOG_DIR"
else
  LOG_DIR="/var/log/celery"
fi

read -p "Do you want to start the services immediately? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  FORCE=true
else
  FORCE=false
fi

CELERY_BIN="${VENV_BIN}/celery"
PYTHON_BIN="${VENV_BIN}/python"

# prefer celery executable, fallback to `python -m celery`
if [ -x "$CELERY_BIN" ]; then
  CELERY_CMD="$CELERY_BIN"
elif [ -x "$PYTHON_BIN" ]; then
  CELERY_CMD="$PYTHON_BIN -m celery"
else
  echo "❌ Could not find celery executable or python in the specified virtualenv: $VENV_BIN"
  exit 1
fi

RUNTIME_DIR="celery-${PROJECT_NAME}"

# === Cleanup old services ===
echo "🧹 Cleaning up old systemd service files for ${PROJECT_NAME}..."
if systemctl list-unit-files | grep -q "^celery-${PROJECT_NAME}.service"; then
  sudo systemctl stop celery-${PROJECT_NAME}.service 2>/dev/null || true
  sudo systemctl disable celery-${PROJECT_NAME}.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/celery-${PROJECT_NAME}.service
fi
if systemctl list-unit-files | grep -q "^celerybeat-${PROJECT_NAME}.service"; then
  sudo systemctl stop celerybeat-${PROJECT_NAME}.service 2>/dev/null || true
  sudo systemctl disable celerybeat-${PROJECT_NAME}.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/celerybeat-${PROJECT_NAME}.service
fi
sudo systemctl daemon-reload
sudo systemctl reset-failed

# Ensure log directory exists and has correct ownership (will be created by ExecStartPre too, but we create here for clarity)
if [ "${LOG_DIR}" = "/var/log/celery" ]; then
  sudo mkdir -p "${LOG_DIR}"
  sudo chown -R "${LINUX_USER}:${LINUX_USER}" "${LOG_DIR}"
else
  mkdir -p "${LOG_DIR}" || true
  chown -R "${LINUX_USER}:${LINUX_USER}" "${LOG_DIR}" || true
fi

# --- Worker service ---
echo "⚙️ Creating systemd service: celery-${PROJECT_NAME}.service"
sudo tee /etc/systemd/system/celery-${PROJECT_NAME}.service > /dev/null <<EOF
[Unit]
Description=Celery Worker for ${PROJECT_NAME}
After=network.target ${BROKER_SERVICE}
Requires=${BROKER_SERVICE}

[Service]
Type=simple
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS}"
ExecStartPre=/bin/mkdir -p ${LOG_DIR}
ExecStartPre=/bin/chown -R ${LINUX_USER}:${LINUX_USER} ${LOG_DIR}
ExecStart=${CELERY_CMD} -A ${PROJECT_NAME} worker \\
    --loglevel=INFO \\
    --logfile=${LOG_DIR}/${PROJECT_NAME}-worker.log \\
    --pidfile=/run/${RUNTIME_DIR}/worker.pid
Restart=always
RestartSec=10
LimitNOFILE=10000
RuntimeDirectory=${RUNTIME_DIR}
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

# --- Beat service ---
echo "⚙️ Creating systemd service: celerybeat-${PROJECT_NAME}.service"
sudo tee /etc/systemd/system/celerybeat-${PROJECT_NAME}.service > /dev/null <<EOF
[Unit]
Description=Celery Beat Scheduler for ${PROJECT_NAME}
After=network.target ${BROKER_SERVICE}
Requires=${BROKER_SERVICE}

[Service]
Type=simple
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS}"
ExecStartPre=/bin/mkdir -p ${LOG_DIR}
ExecStartPre=/bin/chown -R ${LINUX_USER}:${LINUX_USER} ${LOG_DIR}
ExecStart=${CELERY_CMD} -A ${PROJECT_NAME} beat \\
    --loglevel=INFO \\
    --logfile=${LOG_DIR}/${PROJECT_NAME}-beat.log \\
    --pidfile=/run/${RUNTIME_DIR}/beat.pid
Restart=always
RestartSec=10
RuntimeDirectory=${RUNTIME_DIR}
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Reloading systemd manager..."
sudo systemctl daemon-reload
sudo systemctl enable celery-${PROJECT_NAME}.service
sudo systemctl enable celerybeat-${PROJECT_NAME}.service

if [ "$FORCE" = true ]; then
  echo "🚀 Starting services..."
  sudo systemctl restart celery-${PROJECT_NAME}.service || sudo systemctl start celery-${PROJECT_NAME}.service
  sudo systemctl restart celerybeat-${PROJECT_NAME}.service || sudo systemctl start celerybeat-${PROJECT_NAME}.service

  echo "📊 Service Status:"
  sudo systemctl status celery-${PROJECT_NAME}.service --no-pager || true
  sudo systemctl status celerybeat-${PROJECT_NAME}.service --no-pager || true

  echo
  echo "To follow logs in realtime:"
  echo "  sudo journalctl -u celery-${PROJECT_NAME}.service -f"
  echo "  sudo journalctl -u celerybeat-${PROJECT_NAME}.service -f"
else
  echo "✅ Setup complete. You can start services using:"
  echo "  sudo systemctl start celery-${PROJECT_NAME}.service"
  echo "  sudo systemctl start celerybeat-${PROJECT_NAME}.service"
  echo
  echo "To check logs:"
  echo "  sudo journalctl -u celery-${PROJECT_NAME}.service"
  echo "  sudo journalctl -u celerybeat-${PROJECT_NAME}.service"
fi

# End of script

