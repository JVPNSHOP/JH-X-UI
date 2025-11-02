#!/bin/bash
# x-ui helper (Tri-color CLI • Manual Creds • Email Notify • Copy-safe Summary • jue-menu • Web UI Theme)
# - Self-installs to /usr/local/sbin/xui-helper.sh
# - Global shortcut `jue-menu` (quick creds menu)
# - Keeps last URL/USER/PASS on screen & saves to /root/xui-last.txt
# - Web Panel theme: apply / rollback (tri-color accents)

set -euo pipefail

# ---------------- Colors (CLI only) ----------------
plain='\033[0m'; red='\033[0;31m'; yellow='\033[0;33m'
tri1='\033[0;34m'; tri2='\033[0;33m'; tri3='\033[0;35m'  # basic ANSI (blue/yellow/magenta)

tri_echo(){ local msg="$*"; local len=${#msg}; local a=$((len/3)); local b=$((2*len/3))
  echo -e "${tri1}${msg:0:$a}${tri2}${msg:$a:$((b-a))}${tri3}${msg:$b}${plain}"; }
banner(){ tri_echo "┌─────────────────────────────────────────────────────────────┐"
         tri_echo "│  $*"
         tri_echo "└─────────────────────────────────────────────────────────────┘"; }

# ---------------- Paths / Globals ----------------
CONF_FILE="/etc/xui-helper.conf"
EMAIL_ENABLED="true"; EMAIL_TO="juevpn@gmail.com"; IP_OVERRIDE=""
SUMMARY_FILE="/root/xui-last.txt"
LAST_XUI_USER=""; LAST_XUI_PASS=""; LAST_XUI_PORT=""
XUI_BIN="/usr/local/x-ui/x-ui"

INSTALL_PATH="/usr/local/sbin/xui-helper.sh"   # canonical path for wrappers

# Load config if exists
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
save_config(){ cat >"$CONF_FILE"<<EOF
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
IP_OVERRIDE="$IP_OVERRIDE"
EOF
chmod 600 "$CONF_FILE" || true; }

# ---------------- Root & OS ----------------
[[ $EUID -ne 0 ]] && { echo -e "${red}Fatal:${plain} run as root."; exit 1; }

detect_os(){ local r=""; if [[ -f /etc/os-release ]]; then source /etc/os-release; r=$ID
elif [[ -f /usr/lib/os-release ]]; then source /usr/lib/os-release; r=$ID
else echo "OS detect fail"; exit 1; fi; echo "$r"; }

arch(){ case "$(uname -m)" in
  x86_64|x64|amd64) echo amd64;; i*86|x86) echo 386;;
  armv8*|arm64|aarch64) echo arm64;; armv7*|arm) echo armv7;;
  armv6*) echo armv6;; armv5*) echo armv5;; s390x) echo s390x;;
  *) echo -e "${yellow}Unsupported CPU${plain}"; exit 1;; esac; }

install_base(){ local r; r="$(detect_os)"; case "$r" in
  ubuntu|debian|armbian) apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates gnupg mailutils msmtp-mta || true ;;
  centos|rhel|almalinux|rocky|ol) yum -y update && yum install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
  fedora|amzn|virtuozzo) dnf -y update && dnf install -y -q wget curl tar tzdata ca-certificates mailx msmtp || true ;;
  arch|manjaro|parch)    pacman -Syu --noconfirm && pacman -S --noconfirm wget curl tar tzdata ca-certificates msmtp-mta mailutils || true ;;
  opensuse-* )           zypper refresh && zypper -q install -y wget curl timezone ca-certificates msmtp mailx || true ;;
  alpine)                apk update && apk add wget curl tar tzdata ca-certificates msmtp mailx || true ;;
  *)                     apt-get update && apt-get install -y -q wget curl tar tzdata ca-certificates mailutils msmtp-mta || true ;;
esac; }

gen_random_string(){ local n="$1"; LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$n" | head -n1; }

# ---------------- Network / Email ----------------
get_server_ip(){ if [[ -n "$IP_OVERRIDE" ]]; then echo "$IP_OVERRIDE"; return; fi
  local urls=("https://api4.ipify.org" "https://ipv4.icanhazip.com" "https://v4.api.ipinfo.io/ip" "https://ipv4.myexternalip.com/raw" "https://4.ident.me")
  local ip=""; for u in "${urls[@]}"; do ip=$(curl -fsS --max-time 3 "$u" 2>/dev/null | tr -d '[:space:]') || true; [[ -n "$ip" ]] && break; done
  [[ -z "$ip" ]] && ip="SERVER_IP"; echo "$ip"; }

_have_cmd(){ command -v "$1" >/dev/null 2>&1; }
send_mail(){ local subject="$1"; shift; local body="$*"; [[ "$EMAIL_ENABLED" != "true" || -z "$EMAIL_TO" ]] && return 0
  if _have_cmd mail; then echo -e "$body" | mail -s "$subject" "$EMAIL_TO" && return 0; fi
  if _have_cmd sendmail; then { echo "Subject: $subject"; echo "To: $EMAIL_TO"; echo "Content-Type: text/plain; charset=UTF-8"; echo; echo -e "$body"; } | sendmail -t && return 0; fi
  if _have_cmd msmtp; then { echo "Subject: $subject"; echo "To: $EMAIL_TO"; echo "Content-Type: text/plain; charset=UTF-8"; echo; echo -e "$body"; } | msmtp "$EMAIL_TO" && return 0; fi
  echo -e "${yellow}Email tools not configured; skip.${plain}"; return 1; }

send_creds_email(){ local u="$1" p="$2" q="$3"; local ip; ip=$(get_server_ip); local url="http://${ip}:${q}/"
  send_mail "[x-ui] Credentials for ${ip}" "Server IP/Host: ${ip}
Access URL: ${url}
Username: ${u}
Password: ${p}
Port:     ${q}
Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"; }

# ---------------- X-UI Ops ----------------
show_current_settings(){ [[ -x "$XUI_BIN" ]] || { echo -e "${yellow}x-ui binary not found. Install first.${plain}"; return; }; "$XUI_BIN" setting -show true; }

write_summary_and_pause(){
  local ip; ip=$(get_server_ip); local url="http://${ip}:${LAST_XUI_PORT}/"
  {
    echo "x-ui panel summary"
    echo "Access URL: ${url}"
    echo "Username:   ${LAST_XUI_USER}"
    echo "Password:   ${LAST_XUI_PASS}"
    echo "Port:       ${LAST_XUI_PORT}"
    echo "Saved:      $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  } > "$SUMMARY_FILE"; chmod 600 "$SUMMARY_FILE" || true

  echo; tri_echo "========================================"
  tri_echo "x-ui panel summary"
  tri_echo "Access URL: ${url}"
  tri_echo "Username:   ${LAST_XUI_USER}"
  tri_echo "Password:   ${LAST_XUI_PASS}"
  tri_echo "Port:       ${LAST_XUI_PORT}"
  tri_echo "File copy:  ${SUMMARY_FILE}"
  tri_echo "========================================"; echo
  [[ -t 1 ]] && read -rp $'Press Enter to continue (copy first if you need)...' _d || true
}

set_creds_no_reset(){
  [[ -x "$XUI_BIN" ]] || { echo -e "${red}x-ui not installed yet.${plain}"; return 1; }
  echo; banner "Change x-ui Credentials (NO RESET)"
  read -rp "New username: " U; while [[ -z "$U" ]]; do read -rp "Username cannot be empty. New username: " U; done
  read -rp "New password: " P; echo; while [[ -z "$P" ]]; do read -rp "Password cannot be empty. New password: " P; echo; done
  read -rp "New panel port (leave blank = keep current): " NEWPORT
  local cur_port=$("$XUI_BIN" setting -show true | grep -Eo 'port: .+' | awk '{print $2}') || true
  [[ -z "${NEWPORT:-}" ]] && NEWPORT="${cur_port:-2053}"
  "$XUI_BIN" setting -username "$U" -password "$P" -port "$NEWPORT" -webBasePath ""
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  LAST_XUI_USER="$U"; LAST_XUI_PASS="$P"; LAST_XUI_PORT="$NEWPORT"
  tri_echo "✓ Credentials updated successfully."; write_summary_and_pause; }

reset_panel(){
  local U; U=$(gen_random_string 10); local P; P=$(gen_random_string 14); local PORT; PORT=$(shuf -i 1024-62000 -n 1)
  [[ -x "$XUI_BIN" ]] || { echo -e "${red}x-ui binary not found. Install first.${plain}"; exit 1; }
  "$XUI_BIN" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui || true; else rc-service x-ui restart || true; fi
  LAST_XUI_USER="$U"; LAST_XUI_PASS="$P"; LAST_XUI_PORT="$PORT"
  banner "Randomized Credentials"; write_summary_and_pause; send_creds_email "$U" "$P" "$PORT"; }

config_after_install_manual(){
  "$XUI_BIN" setting -webBasePath "" >/dev/null 2>&1 || true
  banner "Fresh install — set your own username/password/port"
  read -rp "Username: " U; while [[ -z "$U" ]]; do read -rp "Username cannot be empty. Username: " U; done
  read -rp "Password: " P; echo; while [[ -z "$P" ]]; do read -rp "Password cannot be empty. Password: " P; echo; done
  read -rp "Panel port (e.g., 2053) [leave blank = random]: " PORT; [[ -z "${PORT:-}" ]] && PORT=$(shuf -i 1024-62000 -n 1)
  "$XUI_BIN" setting -username "$U" -password "$P" -port "$PORT" -webBasePath ""; "$XUI_BIN" migrate || true
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; systemctl enable x-ui; systemctl restart x-ui
  else rc-update add x-ui || true; rc-service x-ui restart || true; fi
  LAST_XUI_USER="$U"; LAST_XUI_PASS="$P"; LAST_XUI_PORT="$PORT"
  banner "x-ui ready"; write_summary_and_pause; send_creds_email "$U" "$P" "$PORT"; }

install_xui(){
  local r; r="$(detect_os)"; cd /usr/local/ || exit 1
  local tag; tag=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true
  [[ -z "$tag" ]] && { tag=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); [[ -z "$tag" ]] && { echo -e "${red}Fetch x-ui version failed.${plain}"; exit 1; }; }
  banner "Installing 3x-ui ${tag}"
  wget --inet4-only -N -O /usr/local/x-ui-linux-$(arch).tar.gz "https://github.com/MHSanaei/3x-ui/releases/download/${tag}/x-ui-linux-$(arch).tar.gz"
  wget --inet4-only -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
  if [[ -e /usr/local/x-ui/ ]]; then if [[ "$r" == "alpine" ]]; then rc-service x-ui stop || true; else systemctl stop x-ui || true; fi; rm -rf /usr/local/x-ui/; fi
  tar zxvf "x-ui-linux-$(arch).tar.gz"; rm -f "x-ui-linux-$(arch).tar.gz"; cd x-ui || exit 1
  chmod +x x-ui x-ui.sh
  if [[ $(arch) == armv5 || $(arch) == armv6 || $(arch) == armv7 ]]; then mv bin/xray-linux-$(arch) bin/xray-linux-arm; chmod +x bin/xray-linux-arm; fi
  chmod +x x-ui bin/xray-linux-$(arch)
  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui; chmod +x /usr/bin/x-ui
  if [[ "$r" == "alpine" ]]; then wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc; chmod +x /etc/init.d/x-ui; rc-update add x-ui || true
  else cp -f x-ui.service /etc/systemd/system/; systemctl daemon-reload; systemctl enable x-ui; fi
  tri_echo "x-ui ${tag} files installed."; config_after_install_manual; }

# ---------------- Web Panel Theme (apply / rollback) ----------------
find_panel_index(){ find /usr/local/x-ui -maxdepth 3 -type f -name index.html 2>/dev/null | head -n1; }

apply_web_theme(){
  local idx; idx="$(find_panel_index)"; [[ -z "$idx" ]] && { echo "index.html not found under /usr/local/x-ui"; return 1; }
  local dir; dir="$(dirname "$idx")"
  cp -a "$idx" "${idx}.bak.$(date +%s)" || true
  cat >/usr/local/x-ui/custom.css <<'CSS'
:root{ --primary:#2563eb; --warning:#f59e0b; --accent:#e11d48; }
[class*="header"] h1,[class*="header"] .title,.navbar .title,.brand,.logo-text{
  background:linear-gradient(90deg,#2563eb 0%,#f59e0b 50%,#e11d48 100%);
  -webkit-background-clip:text;background-clip:text;color:transparent!important;
}
button,.btn,.el-button--primary,.n-button--primary,.ant-btn-primary{
  background:var(--primary)!important;border-color:var(--primary)!important;color:#fff!important;
}
button:hover,.btn:hover,.el-button--primary:hover,.n-button--primary:hover,.ant-btn-primary:hover{ filter:brightness(1.08); }
.el-switch.is-checked .el-switch__core,.ant-switch-checked,.n-switch--active{ background:var(--primary)!important; }
.el-progress-bar__inner,.ant-progress-bg,.n-progress{ background:linear-gradient(90deg,#2563eb,#f59e0b,#e11d48)!important; }
.sidebar .is-active,.menu .is-active,.n-menu-item--active,.el-menu-item.is-active,.ant-menu-item-selected{ color:var(--primary)!important; }
a,.link{ color:var(--primary); } a:hover{ color:#1e40af; }
.card,.panel,.el-card,.n-card,.ant-card{ border-radius:12px; box-shadow:0 8px 24px rgba(37,99,235,.08); }
.alert-danger,.el-alert--error,.ant-alert-error{ border-radius:10px; }
CSS
  grep -q '/custom.css' "$idx" || sed -i 's#</head>#  <link rel="stylesheet" href="/custom.css" />\n</head>#' "$idx"
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui; else rc-service x-ui restart || true; fi
  tri_echo "✓ Web panel theme applied. Hard-refresh browser if you don't see it."
}

rollback_web_theme(){
  local idx; idx="$(find_panel_index)"; [[ -z "$idx" ]] && { echo "index.html not found."; return 1; }
  sed -i '/custom\.css/d' "$idx" || true
  rm -f /usr/local/x-ui/custom.css || true
  if command -v systemctl >/dev/null 2>&1; then systemctl restart x-ui; else rc-service x-ui restart || true; fi
  tri_echo "✓ Web panel theme removed."
}

# ---------------- Self-install & Shortcuts ----------------
self_install_if_needed(){
  # ensure the running script is at canonical path for wrappers
  if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_PATH" ]]; then
    mkdir -p "$(dirname "$INSTALL_PATH")"
    cat "$0" > "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
  fi
}

ensure_shortcuts(){
  self_install_if_needed
  cat >/usr/local/bin/jue-menu <<WRAP
#!/bin/bash
exec "$INSTALL_PATH" quick
WRAP
  chmod +x /usr/local/bin/jue-menu || true
  cat >/usr/bin/jue-menu <<WRAP2
#!/bin/bash
exec "$INSTALL_PATH" quick
WRAP2
  chmod +x /usr/bin/jue-menu || true
}

# ---------------- Menus ----------------
configure_notifications(){
  banner "Email & Misc Settings"
  echo -e "Current: enabled=${EMAIL_ENABLED}, to=${EMAIL_TO}, IP_OVERRIDE=${IP_OVERRIDE:-none}"
  read -rp "Enable email notifications? [Y/n]: " yn; [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] && EMAIL_ENABLED="true" || EMAIL_ENABLED="false"
  read -rp "Recipient email (Enter=keep: ${EMAIL_TO}): " newmail; [[ -n "$newmail" ]] && EMAIL_TO="$newmail"
  read -rp "Override IP/Host for access URL (blank=auto, current: ${IP_OVERRIDE:-none}): " ipov; [[ -n "$ipov" ]] && IP_OVERRIDE="$ipov"
  save_config; tri_echo "Saved."
}

quick_menu(){
  while true; do
    clear; banner "jue-menu • Quick Credentials Menu"
    echo "  1) Change credentials (NO reset)"
    echo "  2) Legacy RESET (randomize)"
    echo "  3) Apply Web Theme (tri-color)"
    echo "  4) Remove Web Theme"
    echo "  0) Exit"
    echo
    read -rp "Select: " opt
    case "$opt" in
      1) set_creds_no_reset ;;
      2) reset_panel ;;
      3) apply_web_theme ;;
      4) rollback_web_theme ;;
      0) break ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

main_menu(){
  ensure_shortcuts
  while true; do
    clear; banner "x-ui Helper (Tri-color CLI • Manual Creds • Email Notify • Theme)"
    echo "  1) Install / Update x-ui"
    echo "  2) Change credentials (NO reset)"
    echo "  3) Show current settings"
    echo "  4) Configure notifications / override IP"
    echo "  5) Apply Web Theme (tri-color)"
    echo "  6) Remove Web Theme"
    echo "  7) Email test (send dummy mail)"
    echo "  8) Open Quick Menu (same as: jue-menu)"
    echo "  9) Legacy RESET (randomize)"
    echo "  0) Exit"
    echo
    read -rp "Select: " opt
    case "$opt" in
      1) install_base; install_xui ;;
      2) set_creds_no_reset ;;
      3) show_current_settings; read -rp "Press Enter..." ;;
      4) configure_notifications ;;
      5) apply_web_theme ;;
      6) rollback_web_theme ;;
      7) send_mail "[x-ui] test from $(hostname)" "This is a test message at $(date -u)"; read -rp "Press Enter..." ;;
      8) quick_menu ;;
      9) reset_panel ;;
      0) break ;;
      *) echo "Invalid."; sleep 1 ;;
    esac
  done
}

# ---------------- Entrypoint ----------------
case "${1:-menu}" in
  install)    install_base; ensure_shortcuts; install_xui ;;
  set-cred)   ensure_shortcuts; set_creds_no_reset ;;
  reset)      ensure_shortcuts; reset_panel ;;
  email-test) send_mail "[x-ui] test from $(hostname)" "This is a test message at $(date -u)";;
  quick)      ensure_shortcuts; quick_menu ;;
  menu|*)     main_menu ;;
esac