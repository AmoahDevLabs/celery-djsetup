#!/bin/bash

# === Usage Help ===
# The usage help is not strictly needed for an interactive script,
# but it's good practice to keep it for clarity.
print_usage() {
  echo "Usage: $0"
  echo "This script will interactively set up Celery services for your project."
  exit 1
}

# === Read User Input ===
echo "Welcome to the Celery setup script."
echo "Please provide the following information:"

# Read Project Name
read -p "Enter your project name (e.g., 'kuh'): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
  echo "❌ Project name cannot be empty."
  exit 1
fi

# Read Linux User
read -p "Enter the Linux user for the service (e.g., 'milch'): " LINUX_USER
if [ -z "$LINUX_USER" ]; then
  echo "❌ Linux user cannot be empty."
  exit 1
fi

# Read Project Directory
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

# Read Virtual Environment Path
read -p "Enter the full path to your virtual environment (press Enter for auto-detect): " CUSTOM_VENV
if [ -n "$CUSTOM_VENV" ]; then
  VENV_BIN="$CUSTOM_VENV/bin"
else
  if [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
    VENV_BIN="$PROJECT_DIR/.venv/bin"
  elif [ -x "$PROJECT_DIR/venv/bin/python" ]; then
    VENV_BIN="$PROJECT_DIR/venv/bin"
  else
    echo "❌ Could not detect virtual environment. Please run the script again and provide the path."
    exit 1
  fi
fi

# Read Force Restart Option
read -p "Do you want to start the services immediately? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  FORCE=true
else
  FORCE=false
fi

# === Resolve Paths ===
CELERY_BIN="${VENV_BIN}/celery"
LOG_DIR="/var/log/celery"
RUN_DIR="/var/run/celery"
DJANGO_SETTINGS="${PROJECT_NAME}.settings"

# === Create Log and Run Directories ===
echo "📁 Ensuring $LOG_DIR and $RUN_DIR exist..."
sudo mkdir -p "$LOG_DIR" "$RUN_DIR"
sudo chown -R "$LINUX_USER:$LINUX_USER" "$LOG_DIR" "$RUN_DIR"

# === Create Celery Worker Service ===
echo "⚙️ Creating systemd service: celery-${PROJECT_NAME}.service"
sudo tee /etc/systemd/system/celery-${PROJECT_NAME}.service > /dev/null <<EOF
[Unit]
Description=Celery Worker for ${PROJECT_NAME}
After=network.target rabbitmq-server.service
Requires=rabbitmq-server.service

[Service]
Type=simple
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS}"
ExecStart=${CELERY_BIN} -A ${PROJECT_NAME} worker --loglevel=INFO --logfile=${LOG_DIR}/${PROJECT_NAME}-worker.log --pidfile=${RUN_DIR}/${PROJECT_NAME}-worker.pid
Restart=always
LimitNOFILE=10000

[Install]
WantedBy=multi-user.target
EOF

# === Create Celery Beat Service ===
echo "⚙️ Creating systemd service: celerybeat-${PROJECT_NAME}.service"
sudo tee /etc/systemd/system/celerybeat-${PROJECT_NAME}.service > /dev/null <<EOF
[Unit]
Description=Celery Beat Scheduler for ${PROJECT_NAME}
After=network.target
Requires=rabbitmq-server.service

[Service]
Type=simple
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS}"
ExecStart=${CELERY_BIN} -A ${PROJECT_NAME} beat --loglevel=INFO --logfile=${LOG_DIR}/${PROJECT_NAME}-beat.log --pidfile=${RUN_DIR}/${PROJECT_NAME}-beat.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# === Reload systemd and Enable Services ===
echo "🔄 Reloading systemd manager..."
sudo systemctl daemon-reload
sudo systemctl enable celery-${PROJECT_NAME}.service
sudo systemctl enable celerybeat-${PROJECT_NAME}.service

# === Start Services If --force ===
if [ "$FORCE" = true ]; then
  echo "🚀 Starting services..."
  sudo systemctl restart celery-${PROJECT_NAME}.service
  sudo systemctl restart celerybeat-${PROJECT_NAME}.service

  echo "📊 Service Status:"
  sudo systemctl status celery-${PROJECT_NAME}.service --no-pager
  sudo systemctl status celerybeat-${PROJECT_NAME}.service --no-pager
else
  echo "✅ Setup complete. You can start services using:"
  echo "  sudo systemctl start celery-${PROJECT_NAME}.service"
  echo "  sudo systemctl start celerybeat-${PROJECT_NAME}.service"
fi
