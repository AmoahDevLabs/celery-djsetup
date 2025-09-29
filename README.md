# 🤖 Celery Deployment Automation Tool for Django

## 🚀 Project Overview

This repository provides two essential tools for deploying Celery workers and schedulers with Django on Linux distributions that use **systemd** (like Fedora, Ubuntu, CentOS, etc.):

**setup.sh**: A robust, interactive Bash script that automatically creates, configures permissions for, and enables the necessary systemd service files on your server.
**Celery systemd Config Generator (Web UI)**: A single-file HTML/JavaScript application (`web/index.html`) that allows you to visually configure and generate the exact service file content for quick testing and prototyping.

## 📋 Prerequisites

Before using the tools, ensure the following are configured on your server:

- **Django Project**: Your project is configured for Celery tasks.
- **Virtual Environment (VENV)**: Celery and its dependencies are installed inside a Python virtual environment.
- **Message Broker**: A message broker (e.g., RabbitMQ, Redis) is installed and running as a systemd service.

## 🛠️ Tool 1: The Deployment Script (`setup.sh`)

This script handles the heavy lifting of service installation and configuration.

### Usage

1. Make the script executable:

   ```
   chmod +x setup.sh
   ```

2. Run the deployment script interactively:

   ```
   ./setup.sh
   ```

The script will prompt you for four key pieces of information:

- **Project Name** (e.g., `nhwiren`)
- **Linux User**: The non-root user that will own and run the service (e.g., `nana`)
- **Project Path**: The full absolute path to your Django project root (e.g., `/opt/nhwiren`)
- **VENV Path**: The full absolute path to your VENV directory (e.g., `/opt/nhwiren/.venv`)

### ✅ Key Actions Performed by the Script

- Creates and secures log (`/var/log/celery`) and run (`/var/run/celery`) directories with correct ownership (`<LINUX_USER>`).
- Creates **`celery-<project>.service`** and **`celerybeat-<project>.service`** files in `/etc/systemd/system/`.
- Adds **`ExecStartPre`** steps to ensure required directories exist and permissions are fixed before service start.
- Reloads the systemd daemon and enables the services to start on boot.
- Optionally starts the services immediately and displays their status.

---

## 🖥️ Tool 2: The Web UI Config Generator (`web/index.html`)

The Celery systemd Config Generator is a visual utility that helps you quickly generate and debug service file content before deploying.

### Use of the Canvas UI

Access the Generator: Open the directory with the index file,
**`web/index.html`** in your Canvas environment.

Input Configuration: Fill out the four required fields, ensuring the paths are accurate for your server:

- Project Name

- Linux User

- Project Directory

- VENV Bin Directory (The path to the VENV's /bin folder).

Select Broker: Choose either rabbitmq-server.service or redis.service (or manually adjust if you use a different broker).

### Output and Copy:

The two large text areas at the bottom instantly update with the complete, ready-to-use [Unit] and [Service] configurations.
Use the Copy to Clipboard buttons to easily grab the content.

### ✅ When to Use the Web UI

- **Debugging**: Verify the generated `ExecStart` command and environment variables before deploying.
- **Manual Deployment**: If you prefer not to run the setup script, you can copy the generated configs and place them directly in `/etc/systemd/system/`.

## 🩹 Common Deployment Issues

### `status=203/EXEC` Errors

| Error Code        | Log Message                                            | Cause                           | Resolution                                                                                                                                                                       |
| ----------------- | ------------------------------------------------------ | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status=203/EXEC` | `Failed to execute /path/to/celery: Permission denied` | SELinux or corrupted executable | 1. **Check Shebang**: Verify the first line of `/path/to/.venv/bin/celery` points to the correct Python interpreter. <br> 2. Ensure SELinux is permissive or configure policies. |
| `status=203/EXEC` | Error persists after Shebang check                     | Environment/Path mismatch       | **Manual Test**: Run the `ExecStart` command directly as the service user: <br> `sudo -u <user> /path/to/.venv/bin/celery -A <project> worker`                                   |
| `status=203/EXEC` | Failure on `/mnt/` or non-standard paths               | Restricted mount points         | Relocate the project/venv to a standard location such as `/opt/` or `/srv/`.                                                                                                     |

## 📌 Notes

- Both tools (`setup.sh` and `web/index.html`) include **directory safety checks** (`ExecStartPre`) to prevent failures due to missing or mis-owned log/run directories.
- For advanced deployments, consider adding a **Flower monitoring service** (not generated by default).
