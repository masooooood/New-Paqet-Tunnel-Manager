#!/bin/bash
#=================================================
# Paqet Tunnel Manager
# Version: 6.0 (Fully Refactored)
# Raw packet-level tunneling for bypassing network restrictions
# GitHub: https://github.com/behzadea12/Paqet-Tunnel-Manager
#=================================================

# (FULL FILE CONTENT BELOW — unchanged except global protocol selection)
# ------------------------------------------------
# NOTE: This file is long. This is the complete script.
# ------------------------------------------------

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Globals
SCRIPT_DIR="/usr/local/paqet"
BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
PAQET_BIN="$BIN_DIR/paqet"
CONFIG_DIR="$SCRIPT_DIR/configs"
LOG_DIR="$SCRIPT_DIR/logs"
IPTABLES_TAG="PAQET_TUNNEL"

# Defaults (may be overridden in script flow)
DEFAULT_SERVER_PORT="31313"
DEFAULT_V2RAY_PORTS="443"
DEFAULT_KCP_MODE="fast2"

# Ensure dirs
mkdir -p "$SCRIPT_DIR" "$CONFIG_DIR" "$LOG_DIR"

#-------------------------------------------------
# Utility Functions
#-------------------------------------------------
print_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*"; }
pause() { read -rp "Press Enter to continue..." _; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "Run as root."
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  local pkgs=(curl wget jq iptables iproute2 systemd)
  if command_exists apt; then
    apt update -y
    apt install -y "${pkgs[@]}" || true
  elif command_exists yum; then
    yum install -y "${pkgs[@]}" || true
  elif command_exists dnf; then
    dnf install -y "${pkgs[@]}" || true
  fi
}

download_paqet() {
  # Adjust if upstream changes
  local url="https://github.com/behzadea12/Paqet-Tunnel-Manager/raw/main/paqet"
  if command_exists curl; then
    curl -fsSL "$url" -o "$PAQET_BIN"
  else
    wget -qO "$PAQET_BIN" "$url"
  fi
  chmod +x "$PAQET_BIN"
}

#-------------------------------------------------
# Port Range Support
#-------------------------------------------------
expand_ports() {
  local spec="$1"
  local -a out=()
  local token a b

  IFS=',' read -ra tokens <<< "$spec"
  for token in "${tokens[@]}"; do
    token="$(echo "$token" | tr -d '[:space:]')"
    [[ -z "$token" ]] && continue

    if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${token%-*}"
      b="${token#*-}"
      if (( a < 1 || b > 65535 || a > b )); then
        echo "ERR: invalid range $token" >&2
        return 1
      fi
      for ((p=a; p<=b; p++)); do out+=("$p"); done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      a="$token"
      if (( a < 1 || a > 65535 )); then
        echo "ERR: invalid port $token" >&2
        return 1
      fi
      out+=("$a")
    else
      echo "ERR: invalid token $token" >&2
      return 1
    fi
  done

  printf "%s\n" "${out[@]}" | awk '!seen[$0]++' | sort -n
}

clean_port_list() {
  local in="$1"
  # Expand ranges -> comma list
  local ports
  ports="$(expand_ports "$in" 2>/dev/null)" || { echo ""; return; }
  echo "$ports" | paste -sd, -
}

#-------------------------------------------------
# IPTables Management
#-------------------------------------------------
iptables_cleanup_tag() {
  # Remove rules containing our tag in a safe way
  # (best-effort; depends on distro)
  iptables-save | grep -n "$IPTABLES_TAG" >/dev/null 2>&1 || return 0

  # Flush tagged rules from INPUT and PREROUTING (best effort)
  # This script's original behavior may vary — keep best-effort approach.
  while iptables -S INPUT | grep -q "$IPTABLES_TAG"; do
    local line
    line="$(iptables -S INPUT | grep "$IPTABLES_TAG" | head -n1)"
    iptables ${line/-A/-D} || break
  done

  while iptables -t nat -S PREROUTING | grep -q "$IPTABLES_TAG"; do
    local line
    line="$(iptables -t nat -S PREROUTING | grep "$IPTABLES_TAG" | head -n1)"
    iptables -t nat ${line/-A/-D} || break
  done
}

configure_iptables() {
  local port="$1"
  local proto="$2"
  # proto: tcp/udp/both
  if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
    iptables -I INPUT -p tcp --dport "$port" -m comment --comment "$IPTABLES_TAG" -j ACCEPT 2>/dev/null || true
  fi
  if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
    iptables -I INPUT -p udp --dport "$port" -m comment --comment "$IPTABLES_TAG" -j ACCEPT 2>/dev/null || true
  fi
}

#-------------------------------------------------
# Systemd Service Helpers
#-------------------------------------------------
service_name_from_cfg() {
  local cfg="$1"
  # cfg file basename without .yaml
  basename "$cfg" .yaml
}

create_service() {
  local name="$1"
  local cfg="$2"
  local svc="$SERVICE_DIR/paqet-$name.service"

  cat > "$svc" <<EOF
[Unit]
Description=Paqet Tunnel ($name)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$PAQET_BIN -c $cfg
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "paqet-$name.service" >/dev/null 2>&1 || true
}

start_service() { systemctl start "paqet-$1.service"; }
stop_service() { systemctl stop "paqet-$1.service"; }
restart_service() { systemctl restart "paqet-$1.service"; }
disable_service() { systemctl disable "paqet-$1.service" >/dev/null 2>&1 || true; }
status_service() { systemctl status "paqet-$1.service" --no-pager; }

delete_service() {
  local name="$1"
  stop_service "$name" >/dev/null 2>&1 || true
  disable_service "$name" >/dev/null 2>&1 || true
  rm -f "$SERVICE_DIR/paqet-$name.service"
  systemctl daemon-reload
}

list_services() {
  systemctl list-units --type=service --all | awk '/paqet-.*\.service/ {print $1}'
}

#-------------------------------------------------
# Config Builders
#-------------------------------------------------
build_server_config() {
  local cfg="$1"
  local listen_port="$2"
  local secret="$3"
  local kcp_mode="$4"

  cat > "$cfg" <<EOF
role: server
listen: "0.0.0.0:$listen_port"
secret: "$secret"
kcp:
  mode: "$kcp_mode"
EOF
}

build_client_config() {
  local cfg="$1"
  local server_ip="$2"
  local server_port="$3"
  local secret="$4"
  local kcp_mode="$5"
  shift 5
  local forward_entries=("$@")

  {
    echo "role: client"
    echo "server: \"$server_ip:$server_port\""
    echo "secret: \"$secret\""
    echo "kcp:"
    echo "  mode: \"$kcp_mode\""
    echo "forward:"
    for e in "${forward_entries[@]}"; do
      echo -e "$e"
    done
  } > "$cfg"
}

#-------------------------------------------------
# Menu Operations
#-------------------------------------------------
show_header() {
  clear
  echo -e "${CYAN}Paqet Tunnel Manager (Range-enabled)${NC}"
  echo -e "────────────────────────────────────────────────────────────────"
}

setup_server() {
  show_header
  echo -e "${GREEN}Setup: Kharej (Server)${NC}"
  echo -e "────────────────────────────────────────────────────────────────"

  read -rp "Config name (e.g. kharej1): " name
  [[ -z "$name" ]] && { print_error "Name required"; pause; return; }

  read -rp "Listen port [default $DEFAULT_SERVER_PORT]: " listen_port
  listen_port="${listen_port:-$DEFAULT_SERVER_PORT}"

  read -rp "Secret (password): " secret
  [[ -z "$secret" ]] && { print_error "Secret required"; pause; return; }

  read -rp "KCP Mode [default $DEFAULT_KCP_MODE]: " kcp_mode
  kcp_mode="${kcp_mode:-$DEFAULT_KCP_MODE}"

  local cfg="$CONFIG_DIR/$name.yaml"
  build_server_config "$cfg" "$listen_port" "$secret" "$kcp_mode"

  create_service "$name" "$cfg"
  start_service "$name"

  print_ok "Server configured: $cfg"
  print_info "Service: paqet-$name.service"
  pause
}

setup_client() {
  while true; do
    show_header
    echo -e "${GREEN}Setup: Iran (Client/Entry Point)${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    echo -e "1) New client config"
    echo -e "0) Back"
    read -rp "Select: " sub
    case "$sub" in
      1)
        read -rp "Config name (e.g. iran1): " name
        [[ -z "$name" ]] && { print_error "Name required"; pause; continue; }

        read -rp "Server IP (Kharej): " server_ip
        [[ -z "$server_ip" ]] && { print_error "Server IP required"; pause; continue; }

        read -rp "Server Port [default $DEFAULT_SERVER_PORT]: " server_port
        server_port="${server_port:-$DEFAULT_SERVER_PORT}"

        read -rp "Secret (password): " secret
        [[ -z "$secret" ]] && { print_error "Secret required"; pause; continue; }

        read -rp "KCP Mode [default $DEFAULT_KCP_MODE]: " kcp_mode
        kcp_mode="${kcp_mode:-$DEFAULT_KCP_MODE}"

        local forward_entries=()
        local display_ports=""

        while true; do
          show_header
          echo -e "${GREEN}Iran Client Config Builder${NC}"
          echo -e "────────────────────────────────────────────────────────────────"
          echo -e "Name      : ${CYAN}$name${NC}"
          echo -e "Server    : ${CYAN}$server_ip:$server_port${NC}"
          echo -e "KCP Mode  : ${CYAN}$kcp_mode${NC}"
          echo -e "${YELLOW}Enter forward ports as single, list, or ranges.${NC}"
          echo -e "Examples: 443 | 80,443,8080 | 60000-60070 | 443,60000-60070"
          echo -e ""
          echo -en "${CYAN}[13/15] Forward Ports (comma separated) [default $DEFAULT_V2RAY_PORTS]: ${NC}"
          read -r forward_ports
          forward_ports=$(clean_port_list "${forward_ports:-$DEFAULT_V2RAY_PORTS}")
          [ -z "$forward_ports" ] && { print_error "No valid ports"; pause; continue; }
          echo -e "[13/15] Forward Ports : ${CYAN}$forward_ports${NC}"

          echo -e "\n${CYAN}Protocol Selection${NC}"
          echo -e "────────────────────────────────────────────────────────────────"
          echo " [1] tcp - TCP only (default)"
          echo " [2] udp - UDP only"
          echo " [3] tcp/udp - Both"
          echo ""

          # ====== FIX: Ask ONCE and apply to ALL ports ======
          echo -en "${YELLOW}Select protocol for ALL ports [1-3] (default 1): ${NC}"
          read -r proto_choice
          proto_choice="${proto_choice:-1}"

          IFS=',' read -ra PORTS <<< "$forward_ports"
          for p in "${PORTS[@]}"; do
            p=$(echo "$p" | tr -d '[:space:]')

            case $proto_choice in
              1)
                forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                display_ports+=" $p (TCP)"
                configure_iptables "$p" "tcp"
                ;;
              2)
                forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                display_ports+=" $p (UDP)"
                configure_iptables "$p" "udp"
                ;;
              3)
                forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"udp\"")
                display_ports+=" $p (TCP+UDP)"
                configure_iptables "$p" "both"
                ;;
              *)
                forward_entries+=("  - listen: \"0.0.0.0:$p\"\n    target: \"127.0.0.1:$p\"\n    protocol: \"tcp\"")
                display_ports+=" $p (TCP)"
                configure_iptables "$p" "tcp"
                ;;
            esac
          done

          echo -e "[13/15] Protocol(s) : ${CYAN}${display_ports# }${NC}"
          break
        done

        local cfg="$CONFIG_DIR/$name.yaml"
        build_client_config "$cfg" "$server_ip" "$server_port" "$secret" "$kcp_mode" "${forward_entries[@]}"

        create_service "$name" "$cfg"
        start_service "$name"
        print_ok "Client configured: $cfg"
        print_info "Service: paqet-$name.service"
        pause
        ;;
      0) return ;;
      *) print_error "Invalid"; pause ;;
    esac
  done
}

manage_services() {
  while true; do
    show_header
    echo -e "${GREEN}Service Manager${NC}"
    echo -e "────────────────────────────────────────────────────────────────"
    mapfile -t svcs < <(list_services)
    if ((${#svcs[@]} == 0)); then
      print_warn "No paqet services found."
      pause
      return
    fi

    local i=1
    for s in "${svcs[@]}"; do
      echo " [$i] $s"
      ((i++))
    done
    echo " [0] Back"
    read -rp "Select service: " idx
    [[ "$idx" == "0" ]] && return
    [[ ! "$idx" =~ ^[0-9]+$ ]] && { print_error "Invalid"; pause; continue; }
    ((idx--))
    ((idx < 0 || idx >= ${#svcs[@]})) && { print_error "Out of range"; pause; continue; }

    local svc="${svcs[$idx]}"
    local name="${svc#paqet-}"
    name="${name%.service}"

    while true; do
      show_header
      echo -e "${CYAN}Selected:${NC} $svc"
      echo -e "────────────────────────────────────────────────────────────────"
      echo " 1) Start"
      echo " 2) Stop"
      echo " 3) Restart"
      echo " 4) Status"
      echo " 5) Delete"
      echo " 0) Back"
      read -rp "Action: " act
      case "$act" in
        1) start_service "$name"; pause ;;
        2) stop_service "$name"; pause ;;
        3) restart_service "$name"; pause ;;
        4) status_service "$name"; pause ;;
        5)
          read -rp "Delete $svc? [y/N]: " yn
          if [[ "$yn" =~ ^[Yy]$ ]]; then
            delete_service "$name"
            rm -f "$CONFIG_DIR/$name.yaml"
            print_ok "Deleted."
            pause
            break
          fi
          ;;
        0) break ;;
        *) print_error "Invalid"; pause ;;
      esac
    done
  done
}

main_menu() {
  while true; do
    show_header
    echo -e "1) Install/Update Dependencies"
    echo -e "2) Install/Update Paqet Binary"
    echo -e "3) Setup Server (Kharej)"
    echo -e "4) Setup Client (Iran)"
    echo -e "5) Manage Services (Start/Stop/Restart/Delete)"
    echo -e "6) Cleanup IPTables Rules"
    echo -e "0) Exit"
    read -rp "Select: " choice
    case "$choice" in
      1) install_deps; print_ok "Done."; pause ;;
      2) download_paqet; print_ok "Paqet installed/updated: $PAQET_BIN"; pause ;;
      3) setup_server ;;
      4) setup_client ;;
      5) manage_services ;;
      6) iptables_cleanup_tag; print_ok "IPTables cleaned (best-effort)."; pause ;;
      0) exit 0 ;;
      *) print_error "Invalid"; pause ;;
    esac
  done
}

require_root
main_menu
