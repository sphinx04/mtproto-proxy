#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SERVICE_NAME="mtproto-proxy"
CONTAINER_NAME="mtproto-proxy"
CONFIG_DIR="/etc/mtproto-proxy"
STATE_DIR="/var/lib/mtproto-proxy"
SCRIPT_FILE="/usr/local/bin/start-mtproto-proxy.sh"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
IMAGE_NAME="telegrammessenger/proxy"

echo "Removing MTProto proxy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "${EUID}" -ne 0 ]; then
  echo -e "${RED}Run as root${NC}"
  exit 1
fi

echo -n "Stopping systemd service... "
service_found=0
if systemctl list-unit-files --type=service --all 2>/dev/null | grep -Fq "${SERVICE_NAME}.service"; then
  service_found=1
fi
if systemctl status "${SERVICE_NAME}.service" >/dev/null 2>&1; then
  service_found=1
fi

if [ "$service_found" -eq 1 ]; then
  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  echo -e "${GREEN}done${NC}"
else
  echo -e "${YELLOW}not found${NC}"
fi

echo -n "Removing Docker container... "
docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo -e "${GREEN}done${NC}"

echo -n "Removing service file... "
if [ -f "${SERVICE_FILE}" ]; then
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  echo -e "${GREEN}done${NC}"
else
  echo -e "${YELLOW}not found${NC}"
fi

echo -n "Removing app files... "
rm -rf "${CONFIG_DIR}"
rm -rf "${STATE_DIR}"
rm -f "${SCRIPT_FILE}"
echo -e "${GREEN}done${NC}"

echo ""
echo -e "${GREEN}MTProto proxy removed${NC}"
echo ""
echo "Removed:"
echo "  - systemd service"
echo "  - Docker container"
echo "  - config files"
echo "  - install directory"
echo ""
echo -e "${YELLOW}Note:${NC} Docker itself was not removed."
echo "To also remove the proxy image, run:"
echo "  docker rmi ${IMAGE_NAME}"
