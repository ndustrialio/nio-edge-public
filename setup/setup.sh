#!/bin/bash
set -e

NIO_DIR="/nio"

# Detect OS once
uname_out="$(uname -s)"
case "${uname_out}" in
  Linux*)  OS_NAME="linux"; ASSET_NAME="run-edge-linux.tar.gz" ;;
  Darwin*) OS_NAME="macos"; ASSET_NAME="run-edge-macos.tar.gz" ;;
  CYGWIN*|MINGW*|MSYS*) OS_NAME="win"; ASSET_NAME="run-edge-win.exe.zip" ;;
  *) echo "Unsupported OS: $uname_out"; exit 1 ;;
esac

echo "Detected OS: $OS_NAME"

install_remoteit() {
  if [ ! -d "$NIO_DIR/remoteit" ]; then
    echo "Creating remoteit directory at $NIO_DIR/remoteit"
    mkdir -p "$NIO_DIR/remoteit"
  fi

  if [ ! -e "/etc/remoteit" ] || [ ! -L "/etc/remoteit" ]; then
    echo "Linking /etc/remoteit to $NIO_DIR/remoteit"
    sudo ln -s "$NIO_DIR/remoteit" /etc/remoteit
  fi

  if [[ -z "$R3_REGISTRATION_CODE" ]]; then
    echo "Error: R3_REGISTRATION_CODE environment variable not set."
    exit 1
  fi

  echo "Installing remoteit"
  R3_REGISTRATION_CODE="$R3_REGISTRATION_CODE" sh -c "$(curl -fsSL https://downloads.remote.it/remoteit/install_agent.sh)"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker already installed"
    echo "$QUAY_TOKEN" | docker login --username "ndustrialio+nio_edge_$TENANT" --password-stdin quay.io
    return
  fi

  echo "Installing Docker"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
  sudo apt-get update
  sudo apt-get install -y docker-ce
  sudo systemctl enable docker
  sudo systemctl start docker
  # Check if user 'nio' exists
  if id nio &>/dev/null; then
    sudo usermod -aG docker nio
  fi
  echo "$QUAY_TOKEN" | docker login --username "ndustrialio+nio_edge_$TENANT" --password-stdin quay.io
}

download_github_asset() {
  local token="$GITHUB_TOKEN"

  if [[ -z "$token" ]]; then
    echo "Error: GITHUB_TOKEN environment variable not set."
    exit 1
  fi

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
  echo "Initializing NIO environment"

  sudo mkdir -p "$NIO_DIR"
  sudo chown "$USER":"$USER" "$NIO_DIR"

  download_github_asset

  echo "Extracting asset"
  case "$OS_NAME" in
    linux|macos)
      tar -xzf "$NIO_DIR/run-edge.archive" -C "$NIO_DIR"
      rm -f "$NIO_DIR/run-edge.archive"
      chmod +x "$NIO_DIR/run-edge"
      ;;
    win)
      unzip -o "$NIO_DIR/run-edge.archive" -d "$NIO_DIR"
      rm -f "$NIO_DIR/run-edge.archive"
      mv "$NIO_DIR/run-edge-win.exe" "$NIO_DIR/run-edge.exe" || true
      ;;
  esac
}

create_service() {
  if [[ "$OS_NAME" != "linux" ]]; then
    echo "Skipping service setup: unsupported on $OS_NAME"
    return
  fi

  echo "Creating environment file at $NIO_DIR/run-edge.env"
  sudo tee $NIO_DIR/run-edge.env > /dev/null <<EOF
IDENTITY=$MACHINE_USER_ID
EDGE_TOKEN=$EDGE_TOKEN
DIRECTORY=/nio
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


# Ensure required packages
echo "Installing required packages (curl, jq, tar, unzip)"
sudo apt-get update
sudo apt-get install -y curl jq tar unzip

# Optional installs
install_docker
install_remoteit

initialize_nio
create_service

echo "Setup complete!"