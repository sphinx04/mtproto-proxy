#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME="mtproto-proxy"
CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="telegrammessenger/proxy"
CONFIG_DIR="/etc/mtproto-proxy"
CONFIG_FILE="$CONFIG_DIR/config.env"
SCRIPT_TARGET="/usr/local/bin/start-mtproto-proxy.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/mtproto-proxy"
USER_OUTPUT_FILE="$STATE_DIR/mtproto_config.txt"
DEFAULT_DOMAIN="vk.com"
DEFAULT_PORT="443"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This installer must be run as root.${NC}"
    echo "Use: sudo bash setup-mtproto-proxy.sh"
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}Missing required command: $1${NC}"
    exit 1
  fi
}

prompt_read() {
  local __var_name="$1"
  local __prompt="$2"
  local __value=""

  if [ -t 0 ]; then
    read -r -p "$__prompt" __value
  elif [ -r /dev/tty ]; then
    read -r -p "$__prompt" __value </dev/tty
  else
    echo -e "${RED}Interactive input is not available. Run the script in a terminal or set config values beforehand.${NC}" >&2
    exit 1
  fi

  printf -v "$__var_name" '%s' "$__value"
}

install_dependencies() {
  echo -e "${BLUE}==> Installing dependencies${NC}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl openssl xxd iproute2 ca-certificates gnupg lsb-release

  if ! command -v docker >/dev/null 2>&1; then
    echo -e "${BLUE}==> Installing Docker${NC}"
    apt-get install -y docker.io
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local value
  prompt_read value "$prompt [$default]: "
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf '%s' "$value"
}

prompt_domain_choice() {
  local choice custom_domain

  printf '%s\n' "Choose Fake TLS domain:" >&2
  printf '%s\n' "  1) vk.com" >&2
  printf '%s\n' "  2) ya.ru" >&2
  printf '%s\n' "  3) google.com" >&2
  printf '%s\n' "  4) Custom domain" >&2

  while true; do
    prompt_read choice "Select option [1]: "
    if [ -z "$choice" ]; then
      choice="1"
    fi

    case "$choice" in
      1)
        printf '%s' "vk.com"
        return
        ;;
      2)
        printf '%s' "ya.ru"
        return
        ;;
      3)
        printf '%s' "google.com"
        return
        ;;
      4)
        while true; do
          prompt_read custom_domain "Enter custom Fake TLS domain: "
          if [ -z "$custom_domain" ]; then
            echo -e "${YELLOW}Domain cannot be empty.${NC}" >&2
            continue
          fi
          if [ "${#custom_domain}" -gt 15 ]; then
            echo -e "${YELLOW}Custom domain is too long. Fake TLS supports at most 15 ASCII characters.${NC}" >&2
            continue
          fi
          printf '%s' "$custom_domain"
          return
        done
        ;;
      *)
        echo -e "${YELLOW}Invalid option. Choose 1, 2, 3, or 4.${NC}" >&2
        ;;
    esac
  done
}

generate_secret() {
  local fake_domain="$1"
  local domain_hex domain_len needed random_hex
  domain_hex=$(printf '%s' "$fake_domain" | xxd -ps | tr -d '\n')
  domain_len=${#domain_hex}
  needed=$((30 - domain_len))

  if [ "$needed" -lt 0 ]; then
    echo -e "${RED}Domain is too long for Fake TLS secret. Maximum supported length is 15 ASCII characters.${NC}" >&2
    exit 1
  fi

  random_hex=$(openssl rand -hex 15 | cut -c1-"$needed")
  printf 'ee%s%s' "$domain_hex" "$random_hex"
}

load_or_create_config() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  chmod 700 "$CONFIG_DIR" "$STATE_DIR"

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    FAKE_DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
    PORT="${PORT:-$DEFAULT_PORT}"
    SECRET="${SECRET:-}"
    if [ -z "$SECRET" ]; then
      SECRET=$(generate_secret "$FAKE_DOMAIN")
      persist_config
    fi
    echo -e "${GREEN}Using saved config from $CONFIG_FILE${NC}"
  else
    FAKE_DOMAIN=$(prompt_domain_choice)
    PORT=$(prompt_value "Enter port" "$DEFAULT_PORT")
    SECRET=$(generate_secret "$FAKE_DOMAIN")
    persist_config
    echo -e "${GREEN}Generated and saved persistent config${NC}"
  fi
}

persist_config() {
  local server_ip="${SERVER_IP:-}"
  local link=""
  if [ -n "$server_ip" ]; then
    link="tg://proxy?server=${server_ip}&port=${PORT}&secret=${SECRET}"
  fi

  cat > "$CONFIG_FILE" <<EOFCONF
DOMAIN=${FAKE_DOMAIN}
PORT=${PORT}
SECRET=${SECRET}
SERVER=${server_ip}
LINK=${link}
EOFCONF
  chmod 600 "$CONFIG_FILE"
}

write_runtime_script() {
  cat > "$SCRIPT_TARGET" <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="telegrammessenger/proxy"
CONFIG_FILE="/etc/mtproto-proxy/config.env"
STATE_DIR="/var/lib/mtproto-proxy"
USER_OUTPUT_FILE="$STATE_DIR/mtproto_config.txt"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}Missing required command: $1${NC}"
    exit 1
  fi
}

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Config file not found: $CONFIG_FILE${NC}"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"

  FAKE_DOMAIN="${DOMAIN:?DOMAIN missing in config}"
  PORT="${PORT:?PORT missing in config}"
  SECRET="${SECRET:?SECRET missing in config}"
}

save_config() {
  local server_ip="$1"
  local link="tg://proxy?server=${server_ip}&port=${PORT}&secret=${SECRET}"

  mkdir -p /etc/mtproto-proxy "$STATE_DIR"
  chmod 700 /etc/mtproto-proxy "$STATE_DIR"

  cat > "$CONFIG_FILE" <<EOFCONF
DOMAIN=${FAKE_DOMAIN}
PORT=${PORT}
SECRET=${SECRET}
SERVER=${server_ip}
LINK=${link}
EOFCONF
  chmod 600 "$CONFIG_FILE"

  cat > "$USER_OUTPUT_FILE" <<EOFOUT
SERVER=${server_ip}
PORT=${PORT}
SECRET=${SECRET}
DOMAIN=${FAKE_DOMAIN}
LINK=${link}
EOFOUT
  chmod 600 "$USER_OUTPUT_FILE"
}

main() {
  require_command docker
  require_command curl

  load_config

  echo "Starting MTProto proxy with persistent config"
  echo "Fake TLS domain: $FAKE_DOMAIN"
  echo "Port: $PORT"

  systemctl start docker
  docker pull "$IMAGE_NAME" >/dev/null

  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "$PORT:443" \
    -e SECRET="$SECRET" \
    "$IMAGE_NAME" >/dev/null

  sleep 3

  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo -e "${RED}Container failed to start${NC}"
    docker logs "$CONTAINER_NAME" || true
    exit 1
  fi

  SERVER_IP=$(curl -4 -fsSL ifconfig.me || true)
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
  fi
  if [ -z "$SERVER_IP" ]; then
    SERVER_IP="UNKNOWN"
  fi

  save_config "$SERVER_IP"

  echo
  echo -e "${GREEN}MTProto proxy is running${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Server: $SERVER_IP"
  echo "Port: $PORT"
  echo "Secret: $SECRET"
  echo "Fake TLS domain: $FAKE_DOMAIN"
  echo "Link: tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"
  echo "Saved config: $USER_OUTPUT_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
EOFSCRIPT
  chmod +x "$SCRIPT_TARGET"
}

write_systemd_unit() {
  cat > "$UNIT_FILE" <<EOFUNIT
[Unit]
Description=MTProto Proxy Bootstrapper
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_TARGET
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFUNIT
}

enable_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service" >/dev/null
  systemctl restart "$SERVICE_NAME.service"
}

show_result() {
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"

  local final_server final_link
  final_server="${SERVER:-}"
  if [ -z "$final_server" ]; then
    final_server=$(curl -4 -fsSL ifconfig.me || true)
  fi
  if [ -z "$final_server" ]; then
    final_server=$(hostname -I | awk '{print $1}')
  fi
  if [ -z "$final_server" ]; then
    final_server="UNKNOWN"
  fi

  final_link="${LINK:-}"
  if [ -z "$final_link" ]; then
    final_link="tg://proxy?server=${final_server}&port=${PORT}&secret=${SECRET}"
  fi

  echo
  echo -e "${GREEN}All set.${NC}"
  echo "One-command setup is installed and reboot-safe."
  echo "Service: $SERVICE_NAME.service"
  echo "Config: $CONFIG_FILE"
  echo -n "Connect using:"
  echo -e "${BLUE} ${final_link} ${NC}"
  echo
  echo "Useful commands:"
  echo "  systemctl status $SERVICE_NAME.service"
  echo "  journalctl -u $SERVICE_NAME.service -b --no-pager"
  echo "  docker logs $CONTAINER_NAME --tail 20"
}

main() {
  require_root
  install_dependencies
  require_command docker
  require_command systemctl
  require_command curl
  require_command openssl
  require_command xxd

  load_or_create_config
  write_runtime_script
  write_systemd_unit
  enable_service
  show_result
}

main "$@"
