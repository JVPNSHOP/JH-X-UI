#!/bin/bash
# x-ui helper (Tri-color UI • Manual creds visible • Auto email • Menu: change password)
# Usage:
#   bash xui-helper.sh           # menu (default)
#   bash xui-helper.sh install   # direct install/update
#   bash xui-helper.sh set-cred  # change username/password/port (no reset)
#   bash xui-helper.sh ch-pass   # change password only (no reset)
#   bash xui-helper.sh reset     # legacy random reset
#   bash xui-helper.sh email-test

# ---------- Colors / UI ----------
plain='\033[0m'; red='\033[0;31m'; blue='\033[0;34m'; yellow='\033[0;33m'
tri1='\033[38;5;39m'; tri2='\033[38;5;226m'; tri3='\033[38;5;201m'
supports_256(){ [[ "$TERM" =~ 256color ]]||[[ "$COLORTERM" =~ truecolor|24bit ]]; }
tri_echo(){ local m="$*"; if supports_256; then local l=${#m};local a=$((l/3));local b=$((2*l/3));echo -e "${tri1}${m:0:$a}${tri2}${m:$a:$((b-a))}${tri3}${m:$b}${plain}"; else echo -e "${blue}${m}${plain}"; fi; }
banner(){ tri_echo "┌──────────────────────────────────────────────────────────────┐"; tri_echo "│  $*"; tri_echo "└──────────────────────────────────────────────────────────────┘"; }

# ---------- Config (persist) ----------
CONF_FILE="/etc/xui-helper.conf"
EMAIL_ENABLED="true"
EMAIL_TO="juevpn@gmail.com"       # requested default
IP_OVERRIDE=""
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
save_config(){ cat >"$CONF_FILE"<<EOF
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
IP_OVERRIDE="$IP_OVERRIDE"
EOF
chmod 600 "$CONF_FILE"||true; }

# ---------- Root / OS ----------
[[ $EUID -ne 0 ]] && echo -e "${red}Please run as root.${plain}" && exit 1
detect_os(){ if [[ -f /etc/os-release ]];then . /etc/os-release; echo "$ID"; elif [[ -f /usr/lib/os-release ]];then . /usr/lib/os-release; echo "$ID"; else echo "unknown"; fi; }
arch(){ case "$(uname -m)" in x86_64|x64|amd64)echo amd64;; i*86|x86)echo 386;; armv8*|arm64|aarch64)echo arm64;; armv7*|arm)echo armv7;; armv6*)echo armv6;; armv5*)echo armv5;; s390x)echo s390x;; *) echo "unknown"; exit 1;; esac; }

install_base(){
  case "$(detect_os)" in
    ubuntu|debian|armbian) apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
    centos|rhel|almalinux|rocky|ol) yum -y update && yum install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    fedora|amzn|virtuozzo) dnf -y update && dnf install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
    arch|manjaro|parch)    pacman -Syu --noconfirm && pacman -S --noconfirm wget curl tar tzdata ca-certificates msmtp-mta mailutils || true ;;
    opensuse-*)            zypper refresh && zypper -q install -y wget curl tar timezone ca-certificates msmtp mailx || true ;;
    alpine)                apk update && apk add wget curl tar tzdata ca-certificates msmtp mailx || true ;;
    *)                     apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
  esac
}

# ---------- Helpers ----------
xui_bin="/usr/local/x-ui/x-ui"
get_ip(){
  [[ -n "$IP_OVERRIDE" ]] && { echo "$IP_OVERRIDE"; return; }
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://v4.api.ipinfo.io/ip https://ipv4.myexternalip.com/raw https://4.ident.me; do
    ip=$(curl -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]'); [[ -n "$ip" ]] && { echo "$ip"; return; }
  done; echo SERVER_IP;
}
_have(){ command -v "$1" >/dev/null 2>&1; }
send_mail(){
  [[ "$EMAIL_ENABLED" != "true" || -z "$EMAIL_TO" ]] && return 0
  local subj="$1"; shift; local body="$*"
  if _have mail; then echo -e "$body" | mail -s "$subj" "$EMAIL_TO" && return 0; fi
  if _have sendmail; then { echo "Subject: $subj"; echo "To: $EMAIL_TO"; echo; echo -e "$body"; } | sendmail -t && return 0; fi
  if _have msmtp; then { echo "Subject: $subj"; echo "To: $EMAIL_TO"; echo; echo -e "$body"; } | msmtp "$EMAIL_TO" && return 0; fi
  echo -e "${yellow}No mailer configured (mail/sendmail/msmtp). Skipping email.${plain}"; return 1
}
announce_creds(){
  local u="$1" p="$2" port="$3"; local ip; ip=$(get_ip); local url="http://${ip}:${port}/"
  banner "x-ui Access"
  tri_echo "URL:      $url"
  tri_echo "Username: $u"
  tri_echo "Password: $p"
  tri_echo "Port:     $port"
  send_mail "[x-ui] Credentials for ${ip}" "Access URL: ${url}
Username: ${u}
Password: ${p}
Port:     ${port}
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
}

# ---------- Actions ----------
show_settings(){ [[ -x "$xui_bin" ]] && "$xui_bin" setting -show true || echo -e "${yellow}x-ui not installed.${plain}"; }

set_creds_no_reset(){
  [[ ! -x "$xui_bin" ]] && { echo -e "${red}x-ui not installed.${plain}"; return 1; }
  banner "Change Username/Password/Port (NO reset)"
  read -rp "New username: " U; while [[ -z "$U" ]]; do read -rp "Username cannot be empty: " U; done
  read -rp "New password (visible): " P; while [[ -z "$P" ]]; do read -rp "Password cannot be empty: " P; done
  local cur_port; cur_port=$("$xui_bin" setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
  read -rp "New port [Enter = keep ${cur_port}]: " PORT; [[ -z "$PORT" ]] && PORT="$cur_port"
  "$xui_bin" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  if _have systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce_creds "$U" "$P" "$PORT"
}

change_password_only(){
  [[ ! -x "$xui_bin" ]] && { echo -e "${red}x-ui not installed.${plain}"; return 1; }
  banner "Change Password Only (NO reset)"
  local cur_user cur_port
  cur_user=$("$xui_bin" setting -show true | grep -Eo 'username: .+' | awk '{print $2}')
  cur_port=$("$xui_bin" setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
  read -rp "New password for user '${cur_user}': " P; while [[ -z "$P" ]]; do read -rp "Password cannot be empty: " P; done
  "$xui_bin" setting -password "$P" -webBasePath ""
  if _have systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce_creds "$cur_user" "$P" "$cur_port"
}

reset_panel(){
  # legacy random (kept for explicit request)
  [[ ! -x "$xui_bin" ]] && { echo -e "${red}x-ui not installed.${plain}"; exit 1; }
  local U P PORT; U=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c10)
  P=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c14)
  PORT=$(shuf -i 1024-62000 -n 1)
  "$xui_bin" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  if _have systemctl; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  announce_creds "$U" "$P" "$PORT"
}

config_after_install_manual(){
  "$xui_bin" setting -webBasePath "" >/dev/null 2>&1 || true
  banner "Fresh install — set username/password/port"
  read -rp "Username: " U; while [[ -z "$U" ]]; do read -rp "Username cannot be empty: " U; done
  read -rp "Password (visible): " P; while [[ -z "$P" ]]; do read -rp "Password cannot be empty: " P; done
  read -rp "Panel port [Enter = random]: " PORT; [[ -z "$PORT" ]] && PORT=$(shuf -i 1024-62000 -n 1)
  "$xui_bin" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  "$xui_bin" migrate || true
  if _have systemctl; then systemctl daemon-reload; systemctl enable x-ui; systemctl restart x-ui; else rc-update add x-ui || true; rc-service x-ui restart || true; fi
  announce_creds "$U" "$P" "$PORT"
}

install_xui(){
  local tag; tag=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  [[ -z "$tag" ]] && tag=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  [[ -z "$tag" ]] && { echo -e "${red}Failed to fetch x-ui version.${plain}"; exit 1; }
  banner "Installing 3x-ui ${tag}"
  cd /usr/local/ || exit 1
  wget --inet4-only -N -O x-ui-linux-$(arch).tar.gz "https://github.com/MHSanaei/3x-ui/releases/download/${tag}/x-ui-linux-$(arch).tar.gz" || { echo -e "${red}Download failed.${plain}"; exit 1; }
  wget --inet4-only -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh || { echo -e "${red}Failed to fetch x-ui.sh${plain}"; exit 1; }
  [[ -e /usr/local/x-ui/ ]] && { if _have systemctl; then systemctl stop x-ui || true; else rc-service x-ui stop || true; fi; rm -rf /usr/local/x-ui/; }
  tar zxvf x-ui-linux-$(arch).tar.gz && rm -f x-ui-linux-$(arch).tar.gz
  cd x-ui || exit 1
  chmod +x x-ui x-ui.sh
  if [[ $(arch) == armv5 || $(arch) == armv6 || $(arch) == armv7 ]]; then mv bin/xray-linux-$(arch) bin/xray-linux-arm; chmod +x bin/xray-linux-arm; fi
  chmod +x x-ui bin/xray-linux-$(arch)
  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui && chmod +x /usr/bin/x-ui
  if [[ "$(detect_os)" == "alpine" ]]; then
    wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc || { echo -e "${red}Failed to download x-ui.rc${plain}"; exit 1; }
    chmod +x /etc/init.d/x-ui; rc-update add x-ui || true
  else
    cp -f x-ui.service /etc/systemd/system/; systemctl daemon-reload; systemctl enable x-ui
  fi
  tri_echo "x-ui files installed."
  config_after_install_manual
}

# ---------- Menu ----------
configure_notifications(){
  banner "Notifications"
  echo -e "Email enabled: ${yellow}${EMAIL_ENABLED}${plain}"
  echo -e "Recipient     : ${yellow}${EMAIL_TO}${plain}"
  read -rp "Enable email? [Y/n]: " yn; [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] && EMAIL_ENABLED="true" || EMAIL_ENABLED="false"
  read -rp "Recipient email (Enter to keep): " em; [[ -n "$em" ]] && EMAIL_TO="$em"
  read -rp "Override IP/Host for URL (Enter=auto): " ov; [[ -n "$ov" ]] && IP_OVERRIDE="$ov"
  save_config; tri_echo "Saved."
}
smtp_tips(){ cat <<'TIP'
Gmail via msmtp quick setup:
  apt/yum install msmtp (already attempted by this script)
  Create /etc/msmtprc with:
    defaults
    auth on
    tls on
    tls_trust_file /etc/ssl/certs/ca-certificates.crt
    logfile /var/log/msmtp.log
    account gmail
    host smtp.gmail.com
    port 587
    from YOUR_EMAIL@gmail.com
    user YOUR_EMAIL@gmail.com
    passwordeval "cat /root/.gmail_app_password"
    account default : gmail
  Put your 16-char App Password in /root/.gmail_app_password (chmod 600).
  Test: echo OK | msmtp you@example.com
TIP
}
main_menu(){
  clear; banner "x-ui Helper Menu"
  echo -e "  1) Install / Update x-ui"
  echo -e "  2) Change username/password/port (NO reset)"
  echo -e "  3) Change password only (NO reset)"
  echo -e "  4) Show current settings"
  echo -e "  5) Configure notifications / override IP"
  echo -e "  6) Email test"
  echo -e "  7) SMTP setup tips"
  echo -e "  8) Legacy RESET (randomize)"
  echo -e "  0) Exit"
  read -rp "Select: " s
  case "$s" in
    1) install_base; install_xui ;;
    2) set_creds_no_reset ;;
    3) change_password_only ;;
    4) show_settings; read -rp "Enter to continue..." ;;
    5) configure_notifications ;;
    6) send_mail "[x-ui] test $(hostname)" "Test at $(date -u)"; read -rp "Enter..." ;;
    7) clear; smtp_tips; echo; read -rp "Enter..." ;;
    8) reset_panel ;;
    0) exit 0 ;;
    *) echo "Invalid"; sleep 1 ;;
  esac
  main_menu
}

# ---------- Entrypoint ----------
case "$1" in
  install)    install_base; install_xui ;;
  set-cred)   set_creds_no_reset ;;
  ch-pass)    change_password_only ;;
  reset)      reset_panel ;;
  email-test) send_mail "[x-ui] test $(hostname)" "Test at $(date -u)" ;;
  menu|"")    main_menu ;;
  *)          echo "Unknown command: $1"; exit 1 ;;
esac