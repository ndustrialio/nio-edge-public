#!/bin/bash
set -e

NIO_DIR="/nio"
LOG_FILE="/tmp/setup-$(date +%Y%m%d-%H%M%S).log"

# Capture all output to a log file
exec > >(tee "$LOG_FILE") 2>&1

# Ship logs to Datadog on exit (success or failure)
ship_logs() {
  local exit_code=$?
  local status="info"
  if [[ $exit_code -ne 0 ]]; then
    status="error"
  fi

  if [[ -f "$LOG_FILE" && -n "$DD_API_KEY" ]]; then
    local log_content
    log_content=$(jq -Rs '.' < "$LOG_FILE")

    echo "[{\"ddsource\":\"nio-edge\",\"ddtags\":\"owner:integrations,tenant:${TENANT:-unknown},machine_user_id:${MACHINE_USER_ID:-unknown}\",\"hostname\":\"$(hostname)\",\"service\":\"nio-edge-setup\",\"status\":\"${status}\",\"message\":${log_content}}]" \
      | gzip \
      | curl -s -X POST "https://http-intake.logs.datadoghq.com/api/v2/logs" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Content-Encoding: gzip" \
        -H "DD-API-KEY: $DD_API_KEY" \
        --data-binary @- \
      || echo "Warning: Failed to ship logs to Datadog"
  fi

  exit "$exit_code"
}
trap ship_logs EXIT

# Detect OS and architecture
UNAME_OS="$(uname -s)"
UNAME_ARCH="$(uname -m)"
OS_ARCH="${UNAME_OS}_${UNAME_ARCH}"

case "$OS_ARCH" in
  Linux_x86_64)
    OS_NAME="linux"
    ASSET_NAME="run-edge-linux-x64.tar.gz"
    ;;
  Linux_aarch64)
    OS_NAME="linux"
    ASSET_NAME="run-edge-linux-arm64.tar.gz"
    ;;
  Darwin_x86_64)
    OS_NAME="macos"
    ASSET_NAME="run-edge-macos-x64.tar.gz"
    ;;
  Darwin_arm64)
    OS_NAME="macos"
    ASSET_NAME="run-edge-macos-arm64.tar.gz"
    ;;
  CYGWIN*_x86_64|MINGW*_x86_64|MSYS*_x86_64)
    OS_NAME="windows"
    ASSET_NAME="run-edge-windows-x64.exe.zip"
    ;;
  *)
    echo "Unsupported OS/Architecture: $OS_ARCH"
    exit 1
    ;;
esac

echo "Detected platform: $OS_ARCH"

if [[ "$OS_NAME" != "linux" ]]; then
  echo "$OS_NAME is not yet supported"
  exit 1
fi

# Validate required environment variables early
missing_vars=()
for var in DD_API_KEY GITHUB_TOKEN R3_REGISTRATION_CODE QUAY_TOKEN TENANT MACHINE_USER_ID EDGE_TOKEN; do
  if [[ -z "${!var}" ]]; then
    missing_vars+=("$var")
  fi
done
if [[ ${#missing_vars[@]} -gt 0 ]]; then
  echo "Error: Required environment variables not set: ${missing_vars[*]}"
  exit 1
fi

install_datadog() {
  echo "------------------------------
Installing Datadog Agent
------------------------------"

  if command -v datadog-agent >/dev/null 2>&1; then
    echo "Datadog agent already installed"
    return
  fi

  DD_API_KEY="$DD_API_KEY" DD_SITE="datadoghq.com" bash -c "$(curl -fsSL https://install.datadoghq.com/scripts/install_script_agent7.sh)"

  # Enable log collection, container autodiscovery, and tags
  sudo tee -a /etc/datadog-agent/datadog.yaml > /dev/null <<EOF

logs_enabled: true
logs_config:
  container_collect_all: true

listeners:
  - name: docker

config_providers:
  - name: docker
    polling: true

tags:
  - owner:integrations
  - tenant:$TENANT
  - machine_user_id:$MACHINE_USER_ID
EOF

  # Add dd-agent user to docker group
  sudo usermod -aG docker dd-agent

  # Add dd-agent user to systemd-journal group
  sudo usermod -aG systemd-journal dd-agent

  # Collect run-edge systemd service logs
  sudo mkdir -p /etc/datadog-agent/conf.d/run-edge.d
  sudo tee /etc/datadog-agent/conf.d/run-edge.d/conf.yaml > /dev/null <<EOF
logs:
  - type: journald
    source: nio-edge
    service: nio-edge-run-edge
    include_units:
      - run-edge.service
EOF

  sudo systemctl enable datadog-agent
  sudo systemctl restart datadog-agent
}

install_remoteit() {
  echo "------------------------------
Installing Remoteit
------------------------------"
  
  if [ ! -d "$NIO_DIR/remoteit" ]; then
    echo "Creating remoteit directory at $NIO_DIR/remoteit"
    mkdir -p "$NIO_DIR/remoteit"
  fi

  if [ ! -e "/etc/remoteit" ] || [ ! -L "/etc/remoteit" ]; then
    echo "Linking /etc/remoteit to $NIO_DIR/remoteit"
    sudo ln -s "$NIO_DIR/remoteit" /etc/remoteit
  fi

  R3_REGISTRATION_CODE="$R3_REGISTRATION_CODE" sh -c "$(curl -fsSL https://downloads.remote.it/remoteit/install_agent.sh)"
}

install_docker() {
  echo "------------------------------
Installing Docker
------------------------------"

  if command -v docker >/dev/null 2>&1; then
    echo "Docker already installed"
    echo "$QUAY_TOKEN" | docker login --username "ndustrialio+nio_edge_$TENANT" --password-stdin quay.io
    return
  fi

  # Remove conflicts
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg || true; done

  # Add Docker's official GPG key
  sudo apt-get update
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update

  # Install Docker and start
  sudo apt-get install -y docker-ce
  sudo systemctl enable docker
  sudo systemctl start docker
  if id nio &>/dev/null; then
    sudo usermod -aG docker nio
  fi
  echo "$QUAY_TOKEN" | docker login --username "ndustrialio+nio_edge_$TENANT" --password-stdin quay.io
}

download_github_asset() {
  local token="$GITHUB_TOKEN"
  local api_url
  if [[ -n "$NIO_EDGE_VERSION" ]]; then
    echo "Using specified version: $NIO_EDGE_VERSION"
    api_url="https://api.github.com/repos/ndustrialio/nio-edge-api/releases/tags/$NIO_EDGE_VERSION"
  else
    echo "Using latest release"
    api_url="https://api.github.com/repos/ndustrialio/nio-edge-api/releases/latest"
  fi

  local download_target="$NIO_DIR/run-edge.archive"

  echo "Fetching release metadata from GitHub API: $api_url"
  asset_url=$(curl -s -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$api_url" \
    | jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .url')

  if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
    echo "Error: Asset '$ASSET_NAME' not found in release metadata."
    exit 1
  fi

  echo "Downloading asset $ASSET_NAME → $download_target"
  curl -s -L -H "Authorization: Bearer $token" \
       -H "Accept: application/octet-stream" \
       -o "$download_target" "$asset_url"
}

initialize_nio() {
  echo "------------------------------
Initializing NIO environment
------------------------------"

  sudo mkdir -p "$NIO_DIR"
  sudo chown root:root "$NIO_DIR"

  download_github_asset

  echo "Extracting asset"
  case "$OS_NAME" in
    linux|macos)
      tar -xzf "$NIO_DIR/run-edge.archive" -C "$NIO_DIR"
      rm -f "$NIO_DIR/run-edge.archive"
      chmod +x "$NIO_DIR/run-edge"
      ;;
    windows)
      unzip -o "$NIO_DIR/run-edge.archive" -d "$NIO_DIR"
      rm -f "$NIO_DIR/run-edge.archive"
      ;;
  esac
}

create_service() {
  echo "Creating environment file at $NIO_DIR/run-edge.env"
  sudo tee $NIO_DIR/run-edge.env > /dev/null <<EOF
IDENTITY=$MACHINE_USER_ID
EDGE_TOKEN=$EDGE_TOKEN
DIRECTORY=$NIO_DIR
TENANT=$TENANT
EOF
  sudo chmod 640 $NIO_DIR/run-edge.env
  sudo chown root:root $NIO_DIR/run-edge.env

  echo "Creating systemd service for run-edge"

  sudo tee /etc/systemd/system/run-edge.service > /dev/null <<EOF
[Unit]
Description=Ndustrial Edge Service
After=network.target

[Service]
EnvironmentFile=$NIO_DIR/run-edge.env
ExecStart=$NIO_DIR/run-edge
Restart=always
User=root
WorkingDirectory=$NIO_DIR

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable run-edge.service
  sudo systemctl start run-edge.service
}


echo "Installing required packages"
sudo apt-get update
sudo apt-get install -y curl ca-certificates jq tar unzip

install_datadog
install_docker
install_remoteit

initialize_nio
create_service

echo "Setup complete!"