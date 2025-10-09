#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Celery Django Setup Script
# Last modified: 9th Oct, 2025
# By: https://github.com/AmoahDevLabs
# ===============================

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf "🧪 Running in DRY-RUN mode: no changes will be made.\n"
fi

# safe command runner that prints commands in dry-run, executes otherwise
run_or_echo() {
  # single string argument expected
  local cmd="$*"
  if $DRY_RUN; then
    printf "[DRY-RUN] %s\n" "$cmd"
  else
    # use bash -c to ensure a single string is executed safely
    bash -c "$cmd"
  fi
}

# ask with default
ask() {
  local prompt="$1"
  local default="${2:-}"
  local response
  if [[ -n "$default" ]]; then
    read -rp "${prompt} [${default}] " response
    printf '%s\n' "${response:-$default}"
  else
    read -rp "${prompt} " response
    printf '%s\n' "$response"
  fi
}

ask_confirm() {
  local prompt="$1"
  local response
  read -rp "${prompt} (y/N): " response
  [[ "$response" =~ ^[Yy]$ ]]
}

# Ensure systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
  printf "❌ systemctl not found. This script requires systemd.\n" >&2
  exit 1
fi

printf "=== Celery Setup Wizard ===\n"

PROJECT_NAME=$(ask "Enter project name (e.g., nhwiren):")
if [[ -z "${PROJECT_NAME}" ]]; then
  printf "❌ Project name cannot be empty.\n" >&2
  exit 1
fi

LINUX_USER=$(ask "Enter user for service (e.g., nana):")
if [[ -z "${LINUX_USER}" ]]; then
  printf "❌ Linux user cannot be empty.\n" >&2
  exit 1
fi

# Verify user exists
if ! id -u "$LINUX_USER" &>/dev/null; then
  printf "❌ User '%s' does not exist.\n" "$LINUX_USER" >&2
  exit 1
fi

PROJECT_DIR=$(ask "Enter project directory (Press Enter for default: current directory):" "$(pwd)")
if [[ ! -d "$PROJECT_DIR" ]]; then
  printf "❌ Directory not found: %s\n" "$PROJECT_DIR" >&2
  exit 1
fi

# --- Detect virtual environment ---
CUSTOM_VENV=$(ask "Virtualenv path (leave blank to auto-detect):")
if [[ -n "$CUSTOM_VENV" ]]; then
  VENV_BIN="${CUSTOM_VENV%/}/bin"
else
  VENV_BIN=""
  for v in ".venv" "venv" "env"; do
    if [[ -x "${PROJECT_DIR%/}/$v/bin/python" ]]; then
      VENV_BIN="${PROJECT_DIR%/}/$v/bin"
      break
    fi
  done
fi

if [[ -z "${VENV_BIN:-}" ]]; then
  printf "❌ Could not detect a virtualenv. Provide the path when prompted or create one inside your project.\n" >&2
  exit 1
fi

# normalize VENV_ROOT
VENV_ROOT="${VENV_BIN%/bin}"
PYTHON_BIN="${VENV_BIN%/}/python"
CELERY_BIN="${VENV_BIN%/}/celery"
# prefer direct celery binary; fallback to python -m celery
if [[ -x "$CELERY_BIN" ]]; then
  CELERY_CMD="$CELERY_BIN"
else
  CELERY_CMD="$PYTHON_BIN -m celery"
fi

# --- Django settings ---
DJANGO_SETTINGS=$(ask "Django settings module (default: ${PROJECT_NAME}.settings):" "${PROJECT_NAME}.settings")
DJANGO_SETTINGS="${DJANGO_SETTINGS:-${PROJECT_NAME}.settings}"

# --- Broker selection ---
printf "Select Celery broker backend:\n"
PS3="Broker (enter number): "
select BROKER in rabbitmq redis; do
  if [[ "$BROKER" == "rabbitmq" || "$BROKER" == "redis" ]]; then
    break
  fi
done
if [[ "$BROKER" == "redis" ]]; then
  BROKER_SERVICE="redis.service"
else
  BROKER_SERVICE="rabbitmq-server.service"
fi

# --- Log directory ---
LOG_DIR=$(ask "Log directory (default: /var/log/celery):" "/var/log/celery")
LOG_DIR="${LOG_DIR:-/var/log/celery}"

# create directory with safe ownership/permissions
if ask_confirm "Create/ensure log directory '${LOG_DIR}' and set ownership to ${LINUX_USER}?"; then
  run_or_echo "sudo install -d -m 0755 -o '${LINUX_USER}' -g '${LINUX_USER}' '${LOG_DIR}'"
fi

# --- Fix permissions for project/venv ---
if ask_confirm "Fix permissions for project and venv (chown -R ${LINUX_USER}:${LINUX_USER})?"; then
  # use VENV_ROOT which points to venv path without trailing /bin
  run_or_echo "sudo chown -R '${LINUX_USER}:${LINUX_USER}' '${PROJECT_DIR%/}' '${VENV_ROOT%/}'"
fi

# --- Full Cleanup of Old Services and Files ---
printf "🧹 Checking and cleaning up existing Celery services for '%s'...\n" "$PROJECT_NAME"

for svc in worker beat; do
  # If using template units, old non-template files might exist; check both patterns.
  SERVICE_NAME1="celery-${svc}-${PROJECT_NAME}.service"
  SERVICE_NAME2="celery-${svc}@${PROJECT_NAME}.service"   # older or instance-style naming
  SERVICE_TEMPLATE="celery-${svc}@.service"               # template file location if present

  # check active units containing the expected service name
  for SVC in "${SERVICE_NAME1}" "${SERVICE_NAME2}" "${SERVICE_TEMPLATE}"; do
    # Stop and disable if active
    if systemctl list-units --type=service --all | grep -q "${SVC}"; then
      run_or_echo "sudo systemctl stop '${SVC}' 2>/dev/null || true"
      run_or_echo "sudo systemctl disable '${SVC}' 2>/dev/null || true"
    fi
  done

  # Remove old concrete files
  for FILE in "/etc/systemd/system/celery-${svc}-${PROJECT_NAME}.service" "/etc/systemd/system/celery-${svc}@${PROJECT_NAME}.service" "/etc/systemd/system/celery-${svc}@.service"; do
    if [[ -f "$FILE" ]]; then
      printf "🗑 Removing old service file: %s\n" "$FILE"
      run_or_echo "sudo rm -f '${FILE}'"
    fi
  done

  # PID dir for that project/svc
  PID_DIR="/run/celery-${PROJECT_NAME}"
  if [[ -d "$PID_DIR" ]]; then
    printf "🧾 Clearing old PID directory: %s\n" "$PID_DIR"
    run_or_echo "sudo rm -rf '${PID_DIR}'"
  fi

  # Clear old log files
  # shellcheck disable=SC2086
  LOG_PATTERN="${LOG_DIR%/}/${PROJECT_NAME}-${svc}*.log"
  if compgen -G "$LOG_PATTERN" > /dev/null; then
    printf "🪶 Removing old log files: %s\n" "$LOG_PATTERN"
    run_or_echo "sudo rm -f ${LOG_PATTERN@Q}"
  fi
done

# Reload systemd to apply cleanup
run_or_echo "sudo systemctl daemon-reload && sudo systemctl reset-failed"

# We'll use templated unit files to support instances: celery-worker@.service and celery-beat@.service
RUNTIME_DIR_TPL="celery-%i"   # %i expands to the instance (project name)

# --- Service templates (templated unit files using %i) ---
make_service_template() {
  local svc_type="$1"   # Worker or Beat
  local cmd="$2"        # worker | beat
  local filename="$3"   # /etc/systemd/system/...
  cat <<'EOF'
[Unit]
Description=Celery %s for %%i
After=network.target %s
Requires=%s

[Service]
User=%s
Group=%s
WorkingDirectory=%s
Environment="DJANGO_SETTINGS_MODULE=%s"
ExecStart=%s -A %%i %s --loglevel=INFO --logfile=%s/%%i-%s.log --pidfile=/run/%s/%%i-%s.pid
Restart=always
RuntimeDirectory=%s
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF
}

# Build concrete templates (fill some variables here safely)
WORKER_TEMPLATE_PATH="/etc/systemd/system/celery-worker@.service"
BEAT_TEMPLATE_PATH="/etc/systemd/system/celery-beat@.service"

if $DRY_RUN; then
  printf "[DRY-RUN] Would create template files: %s and %s\n" "$WORKER_TEMPLATE_PATH" "$BEAT_TEMPLATE_PATH"
else
  # Create worker template
  {
    printf "%s\n" "[Unit]"
    printf "Description=Celery Worker for %s\n" "%i"
    printf "After=network.target %s\n" "$BROKER_SERVICE"
    printf "Requires=%s\n\n" "$BROKER_SERVICE"

    printf "[Service]\n"
    printf "User=%s\n" "$LINUX_USER"
    printf "Group=%s\n" "$LINUX_USER"
    printf "WorkingDirectory=%s\n" "$PROJECT_DIR"
    printf "Environment=\"DJANGO_SETTINGS_MODULE=%s\"\n" "$DJANGO_SETTINGS"
    # ExecStart uses %i for project instance name; use CELERY_CMD (might contain spaces), so wrap in sh -c quoting carefully
    # We will write ExecStart with exact expansion using %i and leave CELERY_CMD as literal command fragment.
    printf "ExecStart=%s -A %%i worker --loglevel=INFO --logfile=%s/%%i-worker.log --pidfile=/run/%s/%%i-worker.pid\n" "$CELERY_CMD" "$LOG_DIR" "$RUNTIME_DIR_TPL" 
    printf "Restart=always\n"
    printf "RuntimeDirectory=%s\n" "$RUNTIME_DIR_TPL"
    printf "RuntimeDirectoryMode=0755\n\n"
    printf "[Install]\nWantedBy=multi-user.target\n"
  } | sudo tee "$WORKER_TEMPLATE_PATH" >/dev/null

  # Create beat template
  {
    printf "%s\n" "[Unit]"
    printf "Description=Celery Beat for %s\n" "%i"
    printf "After=network.target %s\n" "$BROKER_SERVICE"
    printf "Requires=%s\n\n" "$BROKER_SERVICE"

    printf "[Service]\n"
    printf "User=%s\n" "$LINUX_USER"
    printf "Group=%s\n" "$LINUX_USER"
    printf "WorkingDirectory=%s\n" "$PROJECT_DIR"
    printf "Environment=\"DJANGO_SETTINGS_MODULE=%s\"\n" "$DJANGO_SETTINGS"
    printf "ExecStart=%s -A %%i beat --loglevel=INFO --logfile=%s/%%i-beat.log --pidfile=/run/%s/%%i-beat.pid\n" "$CELERY_CMD" "$LOG_DIR" "$RUNTIME_DIR_TPL"
    printf "Restart=always\n"
    printf "RuntimeDirectory=%s\n" "$RUNTIME_DIR_TPL"
    printf "RuntimeDirectoryMode=0755\n\n"
    printf "[Install]\nWantedBy=multi-user.target\n"
  } | sudo tee "$BEAT_TEMPLATE_PATH" >/dev/null
fi

# Reload, enable templated instances (instance name is the project name)
run_or_echo "sudo systemctl daemon-reload"
run_or_echo "sudo systemctl enable 'celery-worker@${PROJECT_NAME}.service' 'celery-beat@${PROJECT_NAME}.service'"

# Start immediately?
if ask_confirm "Start services now?"; then
  run_or_echo "sudo systemctl restart 'celery-worker@${PROJECT_NAME}.service' 'celery-beat@${PROJECT_NAME}.service'"
  printf "🚀 Celery services started for instance '%s'.\n" "$PROJECT_NAME"
else
  printf "✅ Setup complete. Start later with:\n  sudo systemctl start 'celery-worker@%s.service' 'celery-beat@%s.service'\n" "$PROJECT_NAME" "$PROJECT_NAME"
fi

printf "\n📋 Status commands:\n"
printf "  sudo systemctl status 'celery-worker@%s.service'\n" "$PROJECT_NAME"
printf "  sudo systemctl status 'celery-beat@%s.service'\n" "$PROJECT_NAME"
printf "📜 Logs (journalctl):\n"
printf "  sudo journalctl -u 'celery-worker@%s.service' -f\n" "$PROJECT_NAME"
printf "  sudo journalctl -u 'celery-beat@%s.service' -f\n" "$PROJECT_NAME"

