# 🤖 Celery Deployment Automation Tool for Django

## 🚀 Project Overview

This repository provides two essential tools for deploying Celery workers and schedulers with Django on Linux distributions that use systemd (like Fedora, Ubuntu, CentOS, etc.):

- **setup.sh**: A robust, interactive Bash script that automatically creates, configures permissions for, and enables the necessary systemd service files on your server.

- **Celery systemd Config Generator (Web UI)**: A single-file HTML/JavaScript application (which you can access via the Canvas) that allows you to visually configure and generate the exact service file content for quick testing and prototyping.

## 📋 Prerequisites

Before using the tools, ensure the following are configured on your server:

- **Django Project**: Your project is configured for Celery tasks.
- **Virtual Environment**: Celery and its dependencies are installed in a Python Virtual Environment (VENV).
- **Message Broker**: A message broker (e.g., RabbitMQ, Redis) is installed and running as a systemd service.

## 🛠️ Tool 1: The Deployment Script (setup.sh)

This script handles the heavy lifting of service installation and configuration.

### Usage

1. Make the script executable:

```bash
chmod +x setup.sh
```

## Running the Deployment Script

To begin the automated setup process, run the script interactively:

```bash
./setup.sh
```

The script will prompt you for four key pieces of information:

Project Name: (e.g., kuh)

Linux User: The non-root user that will own and run the service (e.g., milch).

Project Path: The full absolute path to your Django project root (e.g., /opt/kuh).

VENV Path: The full absolute path to your VENV directory (e.g., /opt/kuh/.venv).

Key Actions Performed by the Script
Creates and secures log (/var/log/celery) and run (/var/run/celery) directories with correct ownership (<LINUX_USER>).

Creates celery-<project>.service and celerybeat-<project>.service files in /etc/systemd/system/.

Reloads the systemd daemon and enables the services to start on boot.

Optionally starts the services immediately and displays the status.

## 🖥️ Tool 2: The Web UI Config Generator
The Celery systemd Config Generator (available in your Canvas) is a utility designed to help you quickly generate and debug the exact content of the service files before deploying them.

### Use of the Canvas UI
Access the Generator: Open the directory with the index file
web/index.html

in your Canvas environment.

Input Configuration: Fill out the four required fields, ensuring the paths are accurate for your server:

- Project Name

- Linux User

- Project Directory

- VENV Bin Directory (The path to the VENV's /bin folder).

Select Broker: Choose either rabbitmq-server.service or redis.service (or manually adjust if you use a different broker).

### Output and Copy: 
The two large text areas at the bottom instantly update with the complete, ready-to-use [Unit] and [Service] configurations. 
Use the Copy to Clipboard buttons to easily grab the content.

### When to Use the Web UI
Debugging: If you are unsure about the paths or arguments, use the Web UI to verify the ExecStart command before running the full setup script.

### Manual Deployment: 
If you prefer to manually create the .service files on a server, the Web UI provides the perfect source content.

### 🩹 Common Deployment Issues (203/EXEC)
During deployment on strict Linux systems (like Fedora), you may encounter the following error:

| Error Code | Log Message | Cause | Resolution |
|------------|-------------|-------|------------|
| `status=203/EXEC` | `Failed to execute /path/to/celery: Permission denied` | SELinux or Corrupted Executable. The system fails to execute the file at the kernel level. | 1. **Check Shebang**: Verify the first line of the `/path/to/.venv/bin/celery` script points to the correct Python interpreter. |
| `status=203/EXEC` | (Error persists after checking Shebang and SELinux is permissive) | Environment/Path Mismatch. The service file or environment is missing a required path or library. | 2. **Manual Test**: Run the `ExecStart` command directly as the service user to reveal the underlying Python error: `sudo -u <user> /path/to/celery -A <project> worker` |
| `status=203/EXEC` | (Initial failure on `/mnt/` or non-standard paths) | | |
