#!/usr/bin/env bash
# vpskit (vk) —— 小白一键工具  v0.2
# 适配: Ubuntu 22/24, Debian 11/12   需要 root
# 用法: bash vk.sh    安装后直接输入: vk

VK_VERSION="0.2"
VK_DIR="/etc/vpskit"
VK_CONF="$VK_DIR/vpskit.conf"
VK_NODES="$VK_DIR/nodes.txt"
VK_FWD="$VK_DIR/forwards.txt"
VK_BAK="/var/backups/vpskit"
VK_BIN="/usr/local/bin/vk"

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'
ok()   { echo -e "${G}✓ $*${N}"; }
warn() { echo -e "${Y}! $*${N}"; }
err()  { echo -e "${R}✗ $*${N}"; }
info() { echo -e "${B}$*${N}"; }
line() { echo "------------------------------"; }
pause(){ echo; read -rp "按回车继续..." _; }
ask()  { local a; read -rp "$1" a; echo "$a"; }
confirm(){ local a; read -rp "$1 [y/n]: " a; [[ "$a" == "y" || "$a" == "Y" ]]; }

# ---------- 配置 ----------
PORT_MIN=""; PORT_MAX=""; PORT_EXCLUDE=""; NAT=0; NAT_SAMEPORT=1; PUBLIC_HOST=""
PANEL=""; PANEL_PORT=""; PANEL_PATH=""; PANEL_USER=""; PANEL_PASS=""
PANEL_SCHEME="http"; API_TOKEN=""; SUB_PORT=""; SUB_PATH=""; KOMARI_PORT=""; KOMARI_USER=""; KOMARI_PASS=""; KOMARI_DOMAIN=""
CONF_KEYS="PORT_MIN PORT_MAX PORT_EXCLUDE NAT NAT_SAMEPORT PUBLIC_HOST PANEL PANEL_PORT PANEL_PATH PANEL_USER PANEL_PASS PANEL_SCHEME API_TOKEN SUB_PORT SUB_PATH KOMARI_PORT KOMARI_USER KOMARI_PASS KOMARI_DOMAIN"

load_conf(){ [[ -f "$VK_CONF" ]] && . "$VK_CONF"; return 0; }
save_conf(){
  mkdir -p "$VK_DIR"; chmod 700 "$VK_DIR"
  : > "$VK_CONF.tmp"
  local k
  for k in $CONF_KEYS; do printf '%s=%q\n' "$k" "${!k}" >> "$VK_CONF.tmp"; done
  mv "$VK_CONF.tmp" "$VK_CONF"; chmod 600 "$VK_CONF"
}

need_root(){ [[ $EUID -eq 0 ]] || { err "请用 root 运行（先输入 sudo -i 再运行）"; exit 1; }; }

install_deps(){
  local miss="" c
  for c in curl jq openssl qrencode wget tar ss; do
    command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
  done
  [[ -z "$miss" ]] && return 0
  info "正在安装必要组件:$miss"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq openssl qrencode wget tar iproute2 >/dev/null 2>&1
  else
    err "只支持 Ubuntu/Debian 系统"; return 1
  fi
  for c in curl jq openssl; do
    command -v "$c" >/dev/null 2>&1 || { err "组件 $c 安装失败，请检查网络"; return 1; }
  done
}

self_install(){
  if [[ -f "$0" && "$(readlink -f "$0")" != "$VK_BIN" ]]; then
    cp -f "$0" "$VK_BIN" 2>/dev/null && chmod +x "$VK_BIN"
  fi
}

# ---------- 基础工具 ----------
arch_name(){
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo unknown ;;
  esac
}
port_in_use(){ ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
in_range(){
  [[ -z "$PORT_MIN" ]] && return 0
  (( $1 >= PORT_MIN && $1 <= PORT_MAX ))
}
port_excluded(){
  # 用户声明"已经在商家后台映射给别的用途"的端口，不再分配
  local e
  for e in $PORT_EXCLUDE; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}
pick_port(){
  local lo=${PORT_MIN:-20000} hi=${PORT_MAX:-60000} p i
  for i in $(seq 1 200); do
    p=$(( lo + (RANDOM * 32768 + RANDOM) % (hi - lo + 1) ))
    port_excluded "$p" && continue
    port_in_use "$p" || { echo "$p"; return 0; }
  done
  return 1
}
get_ip(){
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -s -m 6 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}
get_host(){
  if [[ -z "$PUBLIC_HOST" ]]; then
    PUBLIC_HOST=$(get_ip) || PUBLIC_HOST=""
    [[ -n "$PUBLIC_HOST" ]] && save_conf
  fi
  echo "$PUBLIC_HOST"
}
ext_port(){
  # NAT 机内外端口不一致时，询问外部端口
  if [[ "$NAT" == "1" && "$NAT_SAMEPORT" == "0" ]]; then
    local e
    e=$(ask "内部端口 $1 对应的【外部端口】是多少: ")
    valid_port "$e" && { echo "$e"; return; }
  fi
  echo "$1"
}
open_fw(){
  local p=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p" >/dev/null 2>&1 && ok "系统防火墙已放行端口 $p"
  fi
}
proto_net(){
  # 协议走 TCP 还是 UDP（NAT 机做端口映射时要选对）
  case "$1" in
    hysteria2|tuic) echo "UDP" ;;
    ss2022|relay)   echo "TCP 和 UDP" ;;
    *)              echo "TCP" ;;
  esac
}
nat_hint(){
  # nat_hint 内部端口 协议类型 用途
  [[ "$NAT" == "1" ]] || return 0
  line
  warn "NAT 机：请到商家后台添加端口映射，否则外面连不上"
  if [[ "$NAT_SAMEPORT" == "1" ]]; then
    echo "  外部端口 $1  →  内部端口 $1    协议: $2    （用途: $3）"
  else
    echo "  外部端口 (你分配的)  →  内部端口 $1    协议: $2    （用途: $3）"
  fi
  [[ "$2" == *UDP* ]] && echo "  注意: 协议一定要包含 UDP，只选 TCP 这个节点不会通"
  line
}
gen_uuid(){ cat /proc/sys/kernel/random/uuid; }
rand_str(){ openssl rand -hex "${1:-6}"; }
b64url(){ base64 -w0 | tr '+/' '-_' | tr -d '='; }
gen_x25519(){
  # 输出: 私钥 公钥 (Reality 用的 base64url 格式)
  local f; f=$(mktemp)
  openssl genpkey -algorithm X25519 -out "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  local priv pub
  priv=$(openssl pkey -in "$f" -outform DER 2>/dev/null | tail -c 32 | b64url)
  pub=$(openssl pkey -in "$f" -pubout -outform DER 2>/dev/null | tail -c 32 | b64url)
  rm -f "$f"
  [[ ${#priv} -eq 43 && ${#pub} -eq 43 ]] || return 1
  echo "$priv $pub"
}
pick_sni(){
  local d
  for d in addons.mozilla.org www.microsoft.com www.amazon.com; do
    curl -sI --tlsv1.3 -m 5 "https://$d" >/dev/null 2>&1 && { echo "$d"; return; }
  done
  echo "www.microsoft.com"
}
show_link(){
  local name=$1 link=$2
  line; ok "节点: $name"
  echo "$link"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 -m 1 "$link"
  fi
  info "手机: 用代理软件扫上面的二维码，或复制链接导入"
}
save_node(){ mkdir -p "$VK_DIR"; echo "$1|$2|$3|$4" >> "$VK_NODES"; }

# ---------- 备份 / 撤销 ----------
backup_now(){
  mkdir -p "$VK_BAK"
  local f="$VK_BAK/$(date +%Y%m%d-%H%M%S)-${1:-manual}.tar.gz" paths=""
  local p
  for p in "$VK_DIR" /usr/local/s-ui/db /etc/x-ui; do [[ -e "$p" ]] && paths="$paths $p"; done
  [[ -z "$paths" ]] && return 0
  # shellcheck disable=SC2086
  tar -czf "$f" $paths 2>/dev/null && echo "$f"
  # 只保留最近 10 份
  ls -1t "$VK_BAK"/*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
}
menu_backup(){
  clear; info "== 备份与撤销 =="
  echo "1. 立即备份"
  echo "2. 恢复到某个备份（撤销）"
  echo "0. 返回"
  case "$(ask '请选择: ')" in
    1) local f; f=$(backup_now manual); [[ -n "$f" ]] && ok "已备份: $f" || warn "没有可备份的内容" ;;
    2)
      local list; mapfile -t list < <(ls -1t "$VK_BAK"/*.tar.gz 2>/dev/null)
      [[ ${#list[@]} -eq 0 ]] && { warn "还没有备份"; pause; return; }
      local i
      for i in "${!list[@]}"; do echo "$((i+1)). $(basename "${list[$i]}")"; done
      local n; n=$(ask "恢复第几个: ")
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#list[@]} )) || { err "输入不对"; pause; return; }
      confirm "确认恢复？当前配置会被覆盖" || return
      backup_now before-restore >/dev/null
      systemctl stop s-ui x-ui 2>/dev/null
      tar -xzf "${list[$((n-1))]}" -C / && ok "已恢复" || err "恢复失败"
      systemctl start s-ui 2>/dev/null; systemctl start x-ui 2>/dev/null
      load_conf ;;
  esac
  pause
}

# ---------- 体检 ----------
do_check(){
  clear; info "== 开机体检 =="
  . /etc/os-release 2>/dev/null
  local virt mem disk ip arch
  virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  disk=$(df -h / | awk 'NR==2{print $4}')
  arch=$(arch_name)
  ip=$(get_ip) || ip=""
  echo "系统: ${PRETTY_NAME:-未知}"
  echo "架构: $arch   虚拟化: $virt"
  echo "内存: ${mem}MB   剩余硬盘: $disk"
  echo "公网IP: ${ip:-获取失败}"
  line
  case "${ID:-}" in
    ubuntu|debian) ok "系统受支持" ;;
    *) err "系统不受支持（只支持 Ubuntu/Debian）" ;;
  esac
  [[ "$arch" == "unknown" ]] && err "CPU 架构不受支持"
  [[ -z "$ip" ]] && err "无法访问外网，请先检查网络"
  (( mem < 200 )) && warn "内存很小，面板可能不稳定"
  if [[ "$virt" == "lxc" || "$virt" == "openvz" ]]; then
    warn "这是容器型机器：BBR 加速、WARP 等功能可能用不了"
  fi
  if [[ -n "$ip" ]] && ! ip -4 addr 2>/dev/null | grep -q "inet $ip/"; then
    warn "网卡上没有这个公网IP：可能是 NAT 机"
    echo "  （部分云厂商的普通机器也会这样，不一定是 NAT）"
  fi
  curl -s -m 8 -o /dev/null https://github.com && ok "能访问 GitHub（下载面板需要）" \
    || err "访问不了 GitHub，装面板会失败"
  if [[ -n "$PORT_MIN" ]]; then
    echo "已设置可用端口范围: $PORT_MIN-$PORT_MAX"
  fi
}

# ---------- 端口范围 (NAT) ----------
set_ports(){
  clear; info "== 机器类型与端口 =="
  echo "1. 普通机器（端口随便用）"
  echo "2. NAT 机（商家只给一段端口）"
  case "$(ask '请选择: ')" in
    1) NAT=0; NAT_SAMEPORT=1; PORT_MIN=""; PORT_MAX=""; PORT_EXCLUDE="" ;;
    2)
      NAT=1
      echo "请看商家后台给你的端口范围，例如 10000-10020"
      local r; r=$(ask "端口范围: ")
      # 容错: 去掉空格，全角/长横线、波浪号都当作分隔符
      r=$(echo "$r" | sed -e 's/[[:space:]]//g' -e 's/－/-/g; s/—/-/g; s/–/-/g; s/~/-/g; s/～/-/g')
      local lo="" hi=""
      # 先把两段存下来: valid_port 内部也用正则，会清掉 BASH_REMATCH
      if [[ "$r" =~ ^([0-9]+)-([0-9]+)$ ]]; then lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}; fi
      if valid_port "$lo" && valid_port "$hi" && (( lo <= hi )); then
        PORT_MIN=$lo; PORT_MAX=$hi
      else
        err "格式不对，应为 起始-结束"; pause; return 1
      fi
      echo "外部端口和机器内部端口是同一个数字吗？"
      echo "（多数商家是同一个。不确定就选 y）"
      if confirm "是同一个"; then NAT_SAMEPORT=1; else NAT_SAMEPORT=0; fi
      echo "这段端口里，有没有已经在商家后台映射给别的用途的？"
      echo "（最常见的是 SSH 登录用的那个端口。多个用空格隔开，没有就直接回车）"
      local ex e; ex=$(ask "已占用的端口: "); PORT_EXCLUDE=""
      for e in $ex; do
        if valid_port "$e"; then PORT_EXCLUDE="$PORT_EXCLUDE $e"; else warn "忽略无效的端口: $e"; fi
      done
      PORT_EXCLUDE=${PORT_EXCLUDE# }
      [[ -n "$PORT_EXCLUDE" ]] && ok "这些端口不会被分配: $PORT_EXCLUDE" ;;
    *) return 1 ;;
  esac
  local h; h=$(get_ip) || h=""
  echo "检测到的公网IP: ${h:-无}"
  echo "如果商家给的是另一个IP或域名，请输入；否则直接回车"
  local c; c=$(ask "连接地址: ")
  PUBLIC_HOST=${c:-$h}
  save_conf; ok "已保存"
}

# ---------- 面板 ----------
panel_installed(){
  [[ -x /usr/local/s-ui/sui ]] && { echo sui; return; }
  [[ -x /usr/local/x-ui/x-ui ]] && { echo xui; return; }
  echo ""
}
panel_service(){ [[ "$PANEL" == "sui" ]] && echo s-ui || echo x-ui; }
panel_url(){
  local h; h=$(get_host)
  local p; p=$(ext_port_quiet "$PANEL_PORT")
  echo "${PANEL_SCHEME}://${h}:${p}/${PANEL_PATH:+$PANEL_PATH/}"
}
ext_port_quiet(){ echo "$1"; }

show_panel(){
  [[ -z "$PANEL" ]] && { warn "还没装面板"; return 1; }
  line
  echo "面板: $([[ "$PANEL" == "sui" ]] && echo s-ui || echo 3x-ui)"
  echo "地址: $(panel_url)"
  echo "账号: $PANEL_USER"
  echo "密码: $PANEL_PASS"
  [[ "$NAT" == "1" && "$NAT_SAMEPORT" == "0" ]] && warn "NAT 机: 地址里的端口要换成对应的外部端口"
  line
}

download(){
  # download URL 目标文件
  wget -q --timeout=30 --tries=2 -O "$2" "$1" && [[ -s "$2" ]]
}

install_panel(){
  clear; info "== 安装面板 =="
  local cur; cur=$(panel_installed)
  if [[ -n "$cur" ]]; then
    warn "本机已装有面板: $([[ "$cur" == "sui" ]] && echo s-ui || echo 3x-ui)"
    echo "一台机器只装一个面板。"
    if [[ -z "$PANEL" ]]; then
      confirm "要让本工具接管这个面板（会重设端口、账号、密码）吗" || return 1
      PANEL=$cur; configure_panel; return $?
    fi
    show_panel; return 0
  fi
  echo "1. s-ui   （sing-box 内核，支持 Hysteria2）"
  echo "2. 3x-ui  （Xray 内核，用的人最多）"
  echo "0. 返回"
  local c; c=$(ask "请选择: ")
  local arch; arch=$(arch_name)
  [[ "$arch" == "unknown" ]] && { err "CPU 架构不支持"; return 1; }
  local tmp; tmp=$(mktemp -d)
  case "$c" in
    1)
      info "正在下载 s-ui ..."
      download "https://github.com/alireza0/s-ui/releases/latest/download/s-ui-linux-${arch}.tar.gz" "$tmp/p.tar.gz" \
        || { err "下载失败：服务器连不上 GitHub，稍后再试"; rm -rf "$tmp"; return 1; }
      tar -xzf "$tmp/p.tar.gz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
      [[ -f "$tmp/s-ui/sui" ]] || { err "安装包结构和预期不同，请把这句话发给开发者"; rm -rf "$tmp"; return 1; }
      chmod +x "$tmp/s-ui/sui" "$tmp/s-ui/s-ui.sh" 2>/dev/null
      [[ -f "$tmp/s-ui/s-ui.sh" ]] && cp -f "$tmp/s-ui/s-ui.sh" /usr/bin/s-ui
      cp -rf "$tmp/s-ui" /usr/local/
      cp -f "$tmp"/s-ui/*.service /etc/systemd/system/ 2>/dev/null
      systemctl daemon-reload
      ensure_resolved || warn "域名解析服务没能启动，装完后请运行【一键排查并修复】"
      systemctl enable s-ui --now >/dev/null 2>&1
      PANEL=sui ;;
    2)
      info "正在下载 3x-ui ..."
      download "https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${arch}.tar.gz" "$tmp/p.tar.gz" \
        || { err "下载失败：服务器连不上 GitHub，稍后再试"; rm -rf "$tmp"; return 1; }
      tar -xzf "$tmp/p.tar.gz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
      [[ -f "$tmp/x-ui/x-ui" ]] || { err "安装包结构和预期不同，请把这句话发给开发者"; rm -rf "$tmp"; return 1; }
      chmod +x "$tmp/x-ui/x-ui" "$tmp/x-ui/x-ui.sh" "$tmp"/x-ui/bin/xray-linux-* 2>/dev/null
      [[ -f "$tmp/x-ui/x-ui.sh" ]] && cp -f "$tmp/x-ui/x-ui.sh" /usr/bin/x-ui
      local svc=""
      for svc in "$tmp/x-ui/x-ui.service" "$tmp/x-ui/x-ui.service.debian"; do
        [[ -f "$svc" ]] && { cp -f "$svc" /etc/systemd/system/x-ui.service; break; }
      done
      [[ -f /etc/systemd/system/x-ui.service ]] || { err "安装包里没找到服务文件，请把这句话发给开发者"; rm -rf "$tmp"; return 1; }
      rm -rf /usr/local/x-ui; mv "$tmp/x-ui" /usr/local/
      systemctl daemon-reload
      systemctl enable x-ui >/dev/null 2>&1
      systemctl restart x-ui
      PANEL=xui ;;
    *) rm -rf "$tmp"; return 1 ;;
  esac
  rm -rf "$tmp"
  sleep 2
  configure_panel
}

configure_panel(){
  info "正在设置面板端口、账号和密码 ..."
  PANEL_PORT=$(pick_port) || { err "端口范围内没有空闲端口"; return 1; }
  PANEL_USER="u$(rand_str 3)"
  PANEL_PASS="$(rand_str 8)"
  PANEL_PATH="$(rand_str 4)"
  API_TOKEN=""
  if [[ "$PANEL" == "sui" ]]; then
    SUB_PORT=$(pick_port); SUB_PATH="$(rand_str 4)"
    /usr/local/s-ui/sui setting -port "$PANEL_PORT" -path "/$PANEL_PATH/" \
        -subPort "$SUB_PORT" -subPath "/$SUB_PATH/" >/dev/null 2>&1 \
      || warn "设置端口的命令返回了错误"
    /usr/local/s-ui/sui admin -username "$PANEL_USER" -password "$PANEL_PASS" >/dev/null 2>&1 \
      || warn "设置账号的命令返回了错误"
    systemctl restart s-ui
    PANEL_SCHEME=http
    open_fw "$SUB_PORT"
  else
    /usr/local/x-ui/x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" \
        -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" >/dev/null 2>&1 \
      || warn "设置面板的命令返回了错误"
    systemctl restart x-ui
    sleep 2
    detect_scheme
  fi
  open_fw "$PANEL_PORT"
  save_conf
  sleep 2
  if port_in_use "$PANEL_PORT"; then
    ok "面板已启动"
  else
    err "面板没有在端口 $PANEL_PORT 上启动，请运行【一键排查】"
  fi
  nat_hint "$PANEL_PORT" "TCP" "面板"
  [[ "$PANEL" == "sui" ]] && nat_hint "$SUB_PORT" "TCP" "订阅"
  show_panel
  warn "请截图保存上面的地址、账号、密码"
}

detect_scheme(){
  local code
  code=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH:+$PANEL_PATH/}")
  if [[ "$code" != "000" ]]; then PANEL_SCHEME=https; else PANEL_SCHEME=http; fi
}

# ---------- 面板 API ----------
# s-ui 用面板账号密码在本机自动登录（会话存在 cookie 文件里），不需要手动创建令牌
SUI_CJ="$VK_DIR/.sui-cookie"
sui_base(){ echo "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH:+$PANEL_PATH/}api"; }
sui_curl(){
  # 面板要求带 X-Requested-With；Host 用公网地址，面板生成的链接才是对的
  curl -s -b "$SUI_CJ" -H "X-Requested-With: XMLHttpRequest" \
    -H "Host: ${PUBLIC_HOST:-127.0.0.1}:${PANEL_PORT}" "$@"
}
sui_get(){ sui_curl -m 15 "$(sui_base)/$1"; }
sui_save(){
  # sui_save 对象 动作 JSON
  sui_curl -m 30 --data-urlencode "object=$1" --data-urlencode "action=$2" \
    --data-urlencode "data=$3" "$(sui_base)/save"
}
sui_login(){
  mkdir -p "$VK_DIR"; : > "$SUI_CJ"; chmod 600 "$SUI_CJ"
  local r
  r=$(sui_curl -m 10 -c "$SUI_CJ" --data-urlencode "user=$PANEL_USER" \
        --data-urlencode "pass=$PANEL_PASS" "$(sui_base)/login")
  sui_ok "$r"
}
sui_find_id(){
  # sui_find_id 接口 字段 值
  sui_get "$1" | jq -r --arg k "$2" --arg v "$3" \
    '[.. | objects | select(has($k) and .[$k] == $v) | .id] | map(select(. != null)) | first // empty' 2>/dev/null
}
sui_ok(){ [[ "$(echo "$1" | jq -r '.success' 2>/dev/null)" == "true" ]]; }

sui_token(){
  # 名字沿用旧的；现在是自动登录，全程不用用户动手
  get_host >/dev/null
  [[ -s "$SUI_CJ" ]] && sui_ok "$(sui_get inbounds)" && return 0
  local i
  for i in 1 2 3 4 5; do sui_login && return 0; sleep 2; done
  if ! systemctl is-active --quiet s-ui; then
    err "面板没有在运行，请先运行【一键排查并修复】"; return 1
  fi
  line
  warn "用保存的账号密码登录面板失败（你可能在面板里改过密码）"
  echo "请输入现在的面板账号和密码，只需这一次："
  PANEL_USER=$(ask "面板账号: ")
  read -rsp "面板密码（输入时不显示）: " PANEL_PASS; echo
  if sui_login; then save_conf; ok "登录成功，已保存"
  else err "还是登录不上，请核对账号密码后再试"; return 1; fi
}

xui_base(){ echo "${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}/${PANEL_PATH:+$PANEL_PATH/}panel/api"; }
xui_get(){ curl -sk -m 15 -H "Authorization: Bearer $API_TOKEN" "$(xui_base)/$1"; }
xui_post(){
  curl -sk -m 20 -X POST -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" -d "$2" "$(xui_base)/$1"
}
xui_token(){
  detect_scheme
  if [[ -n "$API_TOKEN" ]]; then
    [[ "$(xui_get inbounds/list | jq -r '.success' 2>/dev/null)" == "true" ]] && return 0
  fi
  API_TOKEN=$(/usr/local/x-ui/x-ui setting -getApiToken true 2>/dev/null \
      | grep -Eo 'apiToken: .+' | awk '{print $2}')
  if [[ -z "$API_TOKEN" ]]; then
    err "没能从 3x-ui 取得 API 令牌（可能版本太旧）"; return 1
  fi
  save_conf
  sleep 1
  if [[ "$(xui_get inbounds/list | jq -r '.success' 2>/dev/null)" == "true" ]]; then
    return 0
  fi
  err "令牌取到了，但面板接口没有正常响应，请运行【一键排查】"; return 1
}

# ---------- 建节点 ----------
node_done(){
  # node_done 名称 协议 端口 链接 [udp]
  local name=$1 proto=$2 port=$3 link=$4
  open_fw "$port"
  save_node "$name" "$proto" "$port" "$link"
  sleep 2
  if port_in_use "$port"; then
    ok "端口 $port 已在监听，节点搭建成功"
  else
    warn "端口 $port 还没监听，正在重启面板再试 ..."
    systemctl restart "$(panel_service)"; sleep 4
    port_in_use "$port" && ok "重启后正常了" || err "仍未监听，请运行【一键排查】并把诊断报告发给开发者"
  fi
  nat_hint "$port" "$(proto_net "$proto")" "节点 $name"
  show_link "$name" "$link"
}

sui_vless_reality(){
  local port uuid keys priv pub sid sni tag host eport r tls_id in_id
  port=$(pick_port) || { err "没有空闲端口"; return 1; }
  uuid=$(gen_uuid); sid=$(openssl rand -hex 4); sni=$(pick_sni)
  keys=$(gen_x25519) || { err "生成密钥失败"; return 1; }
  priv=${keys% *}; pub=${keys#* }
  tag="${1:-vk-vless}-$port"; LAST_TAG=""
  r=$(sui_save tls new "$(jq -cn --arg n "$tag" --arg sni "$sni" --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
    '{name:$n,
      server:{enabled:true,server_name:$sni,
              reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$priv,short_id:[$sid]}},
      client:{utls:{enabled:true,fingerprint:"chrome"},reality:{public_key:$pub,short_id:$sid}}}')")
  sui_ok "$r" || { err "创建 TLS 配置失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  tls_id=$(sui_find_id tls name "$tag")
  [[ -z "$tls_id" ]] && { err "找不到刚创建的 TLS 配置"; return 1; }
  r=$(sui_save inbounds new "$(jq -cn --arg t "$tag" --argjson p "$port" --argjson tid "$tls_id" \
    '{type:"vless",tag:$t,listen:"::",listen_port:$p,tls_id:$tid,addrs:[],out_json:{}}')")
  sui_ok "$r" || { err "创建入站失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  in_id=$(sui_find_id inbounds tag "$tag")
  [[ -z "$in_id" ]] && { err "找不到刚创建的入站"; return 1; }
  r=$(sui_save clients new "$(jq -cn --arg n "$tag" --arg u "$uuid" --argjson i "$in_id" \
    '{enable:true,name:$n,inbounds:[$i],links:[],volume:0,expiry:0,
      config:{vless:{name:$n,uuid:$u,flow:"xtls-rprx-vision"}}}')")
  sui_ok "$r" || { err "创建用户失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  host=$(get_host); eport=$(ext_port "$port")
  LAST_TAG=$tag
  node_done "$tag" "vless-reality" "$port" \
    "vless://${uuid}@${host}:${eport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#${tag}"
}

sui_tuic(){
  local port uuid pass tag host eport r tls_id in_id cdir="$VK_DIR/cert" sni="bing.com"
  port=$(pick_port) || { err "没有空闲端口"; return 1; }
  uuid=$(gen_uuid); pass=$(rand_str 8); tag="vk-tuic-$port"
  mkdir -p "$cdir"
  if [[ ! -f "$cdir/self.crt" ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$cdir/self.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$cdir/self.key" -out "$cdir/self.crt" -subj "/CN=$sni" 2>/dev/null \
      || { err "生成自签证书失败"; return 1; }
    chmod 644 "$cdir/self.crt"; chmod 600 "$cdir/self.key"
  fi
  r=$(sui_save tls new "$(jq -cn --arg n "$tag" --arg sni "$sni" --arg c "$cdir/self.crt" --arg k "$cdir/self.key" \
    '{name:$n,
      server:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$c,key_path:$k},
      client:{insecure:true}}')")
  sui_ok "$r" || { err "创建 TLS 配置失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  tls_id=$(sui_find_id tls name "$tag")
  [[ -z "$tls_id" ]] && { err "找不到刚创建的 TLS 配置"; return 1; }
  r=$(sui_save inbounds new "$(jq -cn --arg t "$tag" --argjson p "$port" --argjson tid "$tls_id" \
    '{type:"tuic",tag:$t,listen:"::",listen_port:$p,tls_id:$tid,congestion_control:"bbr",addrs:[],out_json:{}}')")
  sui_ok "$r" || { err "创建入站失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  in_id=$(sui_find_id inbounds tag "$tag")
  [[ -z "$in_id" ]] && { err "找不到刚创建的入站"; return 1; }
  r=$(sui_save clients new "$(jq -cn --arg n "$tag" --arg u "$uuid" --arg pw "$pass" --argjson i "$in_id" \
    '{enable:true,name:$n,inbounds:[$i],links:[],volume:0,expiry:0,
      config:{tuic:{name:$n,uuid:$u,password:$pw}}}')")
  sui_ok "$r" || { err "创建用户失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  host=$(get_host); eport=$(ext_port "$port")
  warn "TUIC 走 UDP：NAT 机的端口映射要选 UDP"
  echo "手机端提示: 节点里要打开“允许不安全”；小火箭测速方式改成 CONNECT 才测得出延迟"
  node_done "$tag" "tuic" "$port" \
    "tuic://${uuid}:${pass}@${host}:${eport}?security=tls&insecure=1&allow_insecure=1&sni=${sni}&alpn=h3&congestion_control=bbr#${tag}"
}

sui_hysteria2(){
  local port pass tag host eport r tls_id in_id cdir="$VK_DIR/cert" sni="bing.com"
  port=$(pick_port) || { err "没有空闲端口"; return 1; }
  pass=$(rand_str 12); tag="vk-hy2-$port"
  mkdir -p "$cdir"
  if [[ ! -f "$cdir/self.crt" ]]; then
    openssl ecparam -genkey -name prime256v1 -out "$cdir/self.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$cdir/self.key" -out "$cdir/self.crt" -subj "/CN=$sni" 2>/dev/null \
      || { err "生成自签证书失败"; return 1; }
    chmod 644 "$cdir/self.crt" "$cdir/self.key"
  fi
  r=$(sui_save tls new "$(jq -cn --arg n "$tag" --arg sni "$sni" --arg c "$cdir/self.crt" --arg k "$cdir/self.key" \
    '{name:$n,
      server:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$c,key_path:$k},
      client:{insecure:true}}')")
  sui_ok "$r" || { err "创建 TLS 配置失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  tls_id=$(sui_find_id tls name "$tag")
  [[ -z "$tls_id" ]] && { err "找不到刚创建的 TLS 配置"; return 1; }
  r=$(sui_save inbounds new "$(jq -cn --arg t "$tag" --argjson p "$port" --argjson tid "$tls_id" \
    '{type:"hysteria2",tag:$t,listen:"::",listen_port:$p,tls_id:$tid,addrs:[],out_json:{}}')")
  sui_ok "$r" || { err "创建入站失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  in_id=$(sui_find_id inbounds tag "$tag")
  [[ -z "$in_id" ]] && { err "找不到刚创建的入站"; return 1; }
  r=$(sui_save clients new "$(jq -cn --arg n "$tag" --arg pw "$pass" --argjson i "$in_id" \
    '{enable:true,name:$n,inbounds:[$i],links:[],volume:0,expiry:0,
      config:{hysteria2:{name:$n,password:$pw}}}')")
  sui_ok "$r" || { err "创建用户失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  host=$(get_host); eport=$(ext_port "$port")
  warn "Hysteria2 走 UDP：NAT 机需确认商家的端口同时支持 UDP"
  node_done "$tag" "hysteria2" "$port" \
    "hysteria2://${pass}@${host}:${eport}/?insecure=1&sni=${sni}#${tag}"
}

xui_fix_link(){
  # 把面板返回链接里的本机地址换成公网地址
  local host=$1 port=$2 eport=$3
  sed -E "s#@(127\.0\.0\.1|localhost|\[::1\]):${port}#@${host}:${eport}#"
}
xui_finish(){
  # xui_finish 返回JSON 名称 协议 端口 校验串 自建链接 邮箱
  local r=$1 name=$2 proto=$3 port=$4 probe=$5 mylink=$6 email=$7 id link host eport
  if [[ "$(echo "$r" | jq -r '.success' 2>/dev/null)" != "true" ]]; then
    err "创建入站失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"
    [[ -z "$r" ]] && err "面板没有返回内容，请运行【一键排查】"
    return 1
  fi
  id=$(echo "$r" | jq -r '.obj.id // empty' 2>/dev/null)
  link=$mylink
  if [[ -n "$id" ]] && ! xui_get "inbounds/get/$id" | grep -q "$probe"; then
    # 新版面板的用户需单独创建，改用面板生成的链接
    xui_post clients/add "$(jq -cn --arg e "$email" --argjson i "$id" \
      '{client:{email:$e,enable:true},inboundIds:[$i]}')" >/dev/null
    host=$(get_host); eport=${mylink##*:}; eport=${eport%%[?/#]*}
    local got
    got=$(xui_get "clients/links/$email" | jq -r '.. | strings' 2>/dev/null \
          | grep -E '^(vless|ss|trojan|vmess)://' | head -n1 | xui_fix_link "$host" "$port" "$eport")
    [[ -n "$got" ]] && link=$got || warn "没能取到面板生成的链接，下面的链接可能需要到面板里核对"
  fi
  node_done "$name" "$proto" "$port" "$link"
}

xui_vless_reality(){
  local port uuid keys priv pub sid sni name email host eport r
  port=$(pick_port) || { err "没有空闲端口"; return 1; }
  uuid=$(gen_uuid); sid=$(openssl rand -hex 4); sni=$(pick_sni)
  keys=$(gen_x25519) || { err "生成密钥失败"; return 1; }
  priv=${keys% *}; pub=${keys#* }
  name="vk-vless-$port"; email="vk$port"
  r=$(xui_post inbounds/add "$(jq -cn --arg rm "$name" --argjson p "$port" --arg u "$uuid" --arg e "$email" \
      --arg sni "$sni" --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
    '{enable:true,remark:$rm,listen:"",port:$p,protocol:"vless",expiryTime:0,total:0,
      settings:{clients:[{id:$u,email:$e,flow:"xtls-rprx-vision",enable:true}],decryption:"none"},
      streamSettings:{network:"tcp",security:"reality",
        realitySettings:{show:false,xver:0,dest:($sni+":443"),target:($sni+":443"),serverNames:[$sni],
          privateKey:$priv,shortIds:[$sid],
          settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},
        tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}},
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}}')")
  host=$(get_host); eport=$(ext_port "$port")
  xui_finish "$r" "$name" "vless-reality" "$port" "$uuid" \
    "vless://${uuid}@${host}:${eport}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&spx=%2F&type=tcp#${name}" "$email"
}

xui_ss2022(){
  local port spw cpw name email host eport r method="2022-blake3-aes-128-gcm" ui
  port=$(pick_port) || { err "没有空闲端口"; return 1; }
  spw=$(openssl rand -base64 16); cpw=$(openssl rand -base64 16)
  name="vk-ss-$port"; email="vk$port"
  r=$(xui_post inbounds/add "$(jq -cn --arg rm "$name" --argjson p "$port" --arg m "$method" \
      --arg spw "$spw" --arg cpw "$cpw" --arg e "$email" \
    '{enable:true,remark:$rm,listen:"",port:$p,protocol:"shadowsocks",expiryTime:0,total:0,
      settings:{method:$m,password:$spw,network:"tcp,udp",
        clients:[{method:"",password:$cpw,email:$e,enable:true}]},
      streamSettings:{network:"tcp",security:"none",
        tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}},
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}}')")
  host=$(get_host); eport=$(ext_port "$port")
  ui=$(printf '%s' "${method}:${spw}:${cpw}" | b64url)
  warn "Shadowsocks 直接过境容易被识别，建议只放在中转后面用"
  xui_finish "$r" "$name" "ss2022" "$port" "$cpw" "ss://${ui}@${host}:${eport}#${name}" "$email"
}

menu_node(){
  clear; info "== 一键搭建节点 =="
  [[ -z "$PANEL" ]] && { warn "请先安装面板"; pause; return; }
  if [[ "$PANEL" == "sui" ]]; then
    echo "1. VLESS + Reality  [推荐]"
    echo "   优点: 不要域名证书，伪装强，NAT 机可用"
    echo "   缺点: 线路差时速度一般"
    echo "2. Hysteria2"
    echo "   优点: 线路差时提速明显"
    echo "   缺点: 走 UDP，可能被限速，部分 NAT 机不支持"
    echo "3. TUIC"
    echo "   优点: 延迟低，连接快"
    echo "   缺点: 走 UDP，部分手机网络下不稳定"
  else
    echo "1. VLESS + Reality  [推荐]"
    echo "   优点: 不要域名证书，伪装强，NAT 机可用"
    echo "   缺点: 线路差时速度一般"
    echo "2. Shadowsocks 2022"
    echo "   优点: 轻量省资源，适合放中转后面"
    echo "   缺点: 直接过境容易被识别"
  fi
  echo "0. 返回"
  local c; c=$(ask "请选择: ")
  [[ "$c" == "1" || "$c" == "2" || ( "$c" == "3" && "$PANEL" == "sui" ) ]] || return
  if [[ "$PANEL" == "sui" ]]; then sui_token || { pause; return; }
  else xui_token || { pause; return; }; fi
  backup_now before-node >/dev/null
  case "$PANEL:$c" in
    sui:1) sui_vless_reality ;;
    sui:2) sui_hysteria2 ;;
    sui:3) sui_tuic ;;
    xui:1) xui_vless_reality ;;
    xui:2) xui_ss2022 ;;
  esac
  pause
}

list_nodes(){
  clear; info "== 我的节点 =="
  [[ -s "$VK_NODES" ]] || { warn "还没有通过本工具创建的节点"; pause; return; }
  local i=0 name proto port link
  while IFS='|' read -r name proto port link; do
    i=$((i+1)); echo "$i. $name  ($proto, 端口 $port)"
  done < "$VK_NODES"
  local n; n=$(ask "输入序号查看链接和二维码（回车返回）: ")
  [[ "$n" =~ ^[0-9]+$ ]] || return
  local l; l=$(sed -n "${n}p" "$VK_NODES")
  [[ -z "$l" ]] && return
  IFS='|' read -r name proto port link <<< "$l"
  show_link "$name" "$link"; pause
}

# ---------- 中转 (realm 纯端口转发) ----------
realm_install(){
  [[ -x /usr/local/bin/realm ]] && return 0
  local a tmp
  case "$(uname -m)" in
    x86_64|amd64) a=x86_64 ;;
    aarch64|arm64) a=aarch64 ;;
    *) err "CPU 架构不支持"; return 1 ;;
  esac
  tmp=$(mktemp -d)
  info "正在下载转发程序 realm ..."
  download "https://github.com/zhboner/realm/releases/latest/download/realm-${a}-unknown-linux-gnu.tar.gz" "$tmp/r.tar.gz" \
    && tar -xzf "$tmp/r.tar.gz" -C "$tmp" && [[ -f "$tmp/realm" ]] \
    || { err "下载 realm 失败，稍后再试"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/realm" /usr/local/bin/realm; rm -rf "$tmp"
  cat > /etc/systemd/system/vpskit-realm.service <<'EOF'
[Unit]
Description=vpskit realm port forward
After=network-online.target

[Service]
ExecStart=/usr/local/bin/realm -c /etc/vpskit/realm.toml
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}
realm_apply(){
  mkdir -p "$VK_DIR"
  {
    echo '[network]'; echo 'no_tcp = false'; echo 'use_udp = true'
    local lp rh rp
    while IFS='|' read -r lp rh rp; do
      [[ -z "$lp" ]] && continue
      echo; echo '[[endpoints]]'
      echo "listen = \"0.0.0.0:$lp\""
      echo "remote = \"$rh:$rp\""
    done < "$VK_FWD"
  } > "$VK_DIR/realm.toml"
  if [[ -s "$VK_FWD" ]]; then
    systemctl enable vpskit-realm >/dev/null 2>&1
    systemctl restart vpskit-realm
  else
    systemctl disable vpskit-realm --now >/dev/null 2>&1
  fi
}
relink(){
  # relink 链接 新地址 新端口  -> 把节点链接指向中转机
  echo "$1" | sed -E "s#@[^:@/?\#]+:[0-9]+#@$2:$3#"
}
fwd_add(){
  touch "$VK_FWD"
  info "这台机器将作为【中转机】"
  local rh rp lp
  rh=$(ask "落地机的 IP: ")
  rp=$(ask "落地机上节点的端口: ")
  [[ -n "$rh" ]] && valid_port "$rp" || { err "输入不对"; return 1; }
  lp=$(pick_port) || { err "没有空闲端口"; return 1; }
  realm_install || return 1
  backup_now before-forward >/dev/null
  echo "$lp|$rh|$rp" >> "$VK_FWD"
  realm_apply; open_fw "$lp"; sleep 1
  if port_in_use "$lp"; then ok "转发已生效: 本机 $lp -> $rh:$rp"
  else err "转发没有启动，请运行【一键排查】"; return 1; fi
  nat_hint "$lp" "TCP 和 UDP" "中转转发"
  local host eport link
  host=$(get_host); eport=$(ext_port "$lp")
  echo "把落地机的节点链接粘贴到这里，自动生成中转版链接"
  link=$(ask "节点链接（没有就回车跳过）: ")
  if [[ -n "$link" ]]; then
    local nl; nl=$(relink "$link" "$host" "$eport")
    save_node "relay-$lp" "relay" "$lp" "$nl"
    show_link "中转-$lp" "$nl"
  else
    echo "手动改法: 把节点里的地址改成 $host，端口改成 $eport"
  fi
}
chain_add(){
  # 链式代理：本机新开一个 VLESS-Reality 入口，进来的流量经面板内核转发到落地机
  [[ "$PANEL" == "sui" ]] || { warn "链式代理目前只支持 s-ui 面板；3x-ui 请用【纯端口转发】"; return 1; }
  sui_token || return 1
  info "这台机器将作为【中转机】，流量从落地机出去"
  echo "请粘贴落地机的节点链接（vless:// 等，整行复制）"
  local link; link=$(ask "落地机节点链接: ")
  link=$(echo "$link" | tr -d '\r' | sed 's/^ *//;s/ *$//')
  [[ "$link" == *"://"* ]] || { err "这不是节点链接"; return 1; }
  local dh dp
  dh=$(echo "$link" | sed -nE 's#^[a-z0-9+]+://[^@]+@\[?([^]:/?\#]+)\]?:([0-9]+).*#\1#p')
  dp=$(echo "$link" | sed -nE 's#^[a-z0-9+]+://[^@]+@\[?([^]:/?\#]+)\]?:([0-9]+).*#\2#p')
  if [[ -n "$dh" && -n "$dp" && "$link" != tuic://* && "$link" != hy* ]]; then
    if timeout 6 bash -c "</dev/tcp/$dh/$dp" 2>/dev/null; then ok "本机到落地机 $dh:$dp 连通正常"
    else err "本机连不上落地机 $dh:$dp（落地机没开、端口没映射，或两台之间不通）"; return 1; fi
  fi
  local r out out_tag
  r=$(sui_curl -m 15 --data-urlencode "link=$link" "$(sui_base)/linkConvert")
  sui_ok "$r" || { err "面板不认识这条链接: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  out_tag="vk-out-$(rand_str 3)"
  out=$(echo "$r" | jq -c --arg t "$out_tag" '.obj | .tag=$t | del(.id)' 2>/dev/null)
  [[ -n "$out" && "$out" != "null" ]] || { err "链接转换结果异常"; return 1; }
  backup_now before-chain >/dev/null
  r=$(sui_save outbounds new "$out")
  sui_ok "$r" || { err "创建出站失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  ok "已添加通往落地机的出站 $out_tag"
  sui_vless_reality "vk-chain" || { err "创建中转入口失败"; return 1; }
  [[ -n "$LAST_TAG" ]] || { err "创建中转入口失败"; return 1; }
  local cfg new
  cfg=$(sui_get config | jq -c '.obj.config' 2>/dev/null)
  [[ -n "$cfg" && "$cfg" != "null" ]] || { err "读取面板核心配置失败，中转规则没有加上"; return 1; }
  new=$(echo "$cfg" | jq -c --arg i "$LAST_TAG" --arg o "$out_tag" \
    '.route.rules = ((.route.rules // []) + [{inbound:[$i],action:"route",outbound:$o}])')
  r=$(sui_save config new "$new")
  sui_ok "$r" || { err "保存路由规则失败: $(echo "$r" | jq -r '.msg' 2>/dev/null)"; return 1; }
  sleep 6
  local lp=${LAST_TAG##*-}
  if port_in_use "$lp"; then
    ok "链式中转已生效: 你 → 本机($LAST_TAG) → 落地机"
    echo "用上面那条 $LAST_TAG 的链接/二维码连接即可，出口 IP 会是落地机的"
  else
    err "中转入口端口 $lp 没有监听，请运行【一键排查并修复】"; return 1
  fi
}
fwd_del(){
  [[ -s "$VK_FWD" ]] || { warn "没有转发规则"; return; }
  nl -w1 -s'. ' "$VK_FWD" | sed 's/|/ -> /; s/|/:/'
  local n; n=$(ask "删除第几条: ")
  [[ "$n" =~ ^[0-9]+$ ]] || return
  sed -i "${n}d" "$VK_FWD"; realm_apply; ok "已删除"
}
menu_relay(){
  clear; info "== 中转 / 端口转发 =="
  echo "1. 纯端口转发  [推荐，NAT 机可用]"
  echo "   优点: 最简单，延迟最低，最省资源"
  echo "   缺点: 过境段无额外保护"
  echo "   适合: 专线或线路好的中转机"
  echo "2. 加密隧道中转  (下一版)"
  echo "   优点: 过境多一层伪装，更抗封"
  echo "   缺点: 两端都要配置，速度略损耗"
  echo "3. 链式代理  [落地机被墙时用这个，需 s-ui 面板]"
  echo "   优点: 过境段有 Reality 伪装，面板里可管理和分流"
  echo "   缺点: 比纯转发多占一点资源"
  line
  echo "4. 查看已有转发"
  echo "5. 删除转发"
  echo "0. 返回"
  case "$(ask '请选择: ')" in
    1) fwd_add ;;
    2) warn "这个组合在下一版加入" ;;
    3) chain_add ;;
    4) [[ -s "$VK_FWD" ]] && nl -w1 -s'. ' "$VK_FWD" | sed 's/|/ -> /; s/|/:/' || warn "没有转发规则" ;;
    5) fwd_del ;;
    *) return ;;
  esac
  pause
}

# ---------- Komari 探针 ----------
KM_DIR="/opt/komari"                    # 和官方脚本用同一个目录，方便以后用官方脚本升级
KM_AGENT_CONF="$VK_DIR/komari-agent.json"
km_arch(){ local a; a=$(arch_name); [[ "$a" == "unknown" ]] && return 1; echo "$a"; }
km_server_installed(){ [[ -x "$KM_DIR/komari" ]]; }
km_agent_installed(){ [[ -x "$KM_DIR/agent" ]]; }
km_server_url(){
  if [[ -n "$KOMARI_DOMAIN" ]]; then echo "https://$KOMARI_DOMAIN"
  else echo "http://$(get_host):${KOMARI_PORT}"; fi
}

km_setup_needed(){
  # 探针面板首次启动会停在"安装向导"，这里问它还需不需要初始化
  local r
  r=$(curl -s -m 8 "http://127.0.0.1:${KOMARI_PORT}/api/install/status" 2>/dev/null)
  echo "$r" | jq -e '.. | objects | select(has("required")) | .required == true' >/dev/null 2>&1
}
km_setup(){
  # 代替网页上的安装向导：创建管理员、站点名、监控数据库，全部用默认值
  local i r code body
  for i in $(seq 1 15); do port_in_use "$KOMARI_PORT" && break; sleep 1; done
  if ! km_setup_needed; then return 2; fi
  KOMARI_USER="admin$(rand_str 2)"
  KOMARI_PASS="Km$(rand_str 7)9x"          # 面板要求同时有大写、小写和数字
  body=$(jq -cn --arg u "$KOMARI_USER" --arg p "$KOMARI_PASS" \
    '{username:$u,password:$p,sitename:"Komari",description:"",metric_dsn:"./data/metrics.db"}')
  r=$(curl -s -m 40 -w '\n%{http_code}' -H 'Content-Type: application/json' \
        -d "$body" "http://127.0.0.1:${KOMARI_PORT}/api/install/complete" 2>/dev/null)
  code=${r##*$'\n'}
  if [[ "$code" != "200" ]]; then
    KOMARI_USER=""; KOMARI_PASS=""
    err "自动初始化没成功（返回 $code）: $(echo "${r%$'\n'*}" | cut -c1-160)"
    return 1
  fi
  save_conf
  # 初始化完成后面板会切换到正常模式，等它重新就绪
  sleep 3
  for i in $(seq 1 20); do port_in_use "$KOMARI_PORT" && break; sleep 1; done
  return 0
}
km_show_login(){
  line
  echo "探针面板地址: $(km_server_url)"
  if [[ -n "$KOMARI_USER" ]]; then
    echo "账号: $KOMARI_USER"
    echo "密码: $KOMARI_PASS"
  fi
  line
}
km_after_install(){
  km_setup
  case $? in
    0) ok "探针面板已初始化好，不用再走网页上的安装向导"
       km_show_login
       warn "请截图保存上面的地址、账号、密码" ;;
    2) km_show_login
       [[ -z "$KOMARI_USER" ]] && echo "这个面板已经初始化过了，用你当时设置的账号密码登录" ;;
    *) km_show_login
       warn "请【现在】就用浏览器打开上面的地址，按网页上的安装向导创建管理员账号"
       echo "第一个打开网页的人会成为管理员，所以不要拖，也不要把地址发给别人" ;;
  esac
  echo
  echo "添加被监控机器的方法:"
  echo "  1) 登录探针网页后台，点“添加节点”，它会给出一条安装命令"
  echo "  2) 到要监控的机器上运行 vk → 13 → 2，把那条命令整行粘贴进去"
  echo "  （本机也要被监控的话，在本机同样做一遍第 2 步）"
}
km_server_install(){
  if km_server_installed; then
    warn "本机已经装了探针面板"
    if [[ -n "$KOMARI_PORT" ]] && km_setup_needed; then
      info "它还停在安装向导那一步，现在替你自动完成 ..."
      km_after_install
    else
      km_status
    fi
    return 0
  fi
  local a tmp
  a=$(km_arch) || { err "CPU 架构不支持"; return 1; }
  info "探针面板只需要装在【一台】机器上，其他机器装客户端连过来就行"
  echo "建议装在国内能直连、不会被墙的那台上，否则你打不开它的网页"
  confirm "就装在这台吗" || return 1
  tmp=$(mktemp -d)
  info "正在下载 Komari 面板 ..."
  download "https://github.com/komari-monitor/komari/releases/latest/download/komari-linux-${a}" "$tmp/komari" \
    || { err "下载失败：服务器连不上 GitHub，稍后再试"; rm -rf "$tmp"; return 1; }
  KOMARI_PORT=$(pick_port) || { err "没有空闲端口"; rm -rf "$tmp"; return 1; }
  mkdir -p "$KM_DIR"
  install -m 755 "$tmp/komari" "$KM_DIR/komari"; rm -rf "$tmp"
  cat > /etc/systemd/system/komari.service <<EOF
[Unit]
Description=Komari Monitor Service
After=network.target

[Service]
Type=simple
Environment="GODEBUG=disablethp=1"
ExecStart=$KM_DIR/komari server -l 0.0.0.0:${KOMARI_PORT}
WorkingDirectory=$KM_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable komari >/dev/null 2>&1
  systemctl restart komari
  save_conf; open_fw "$KOMARI_PORT"; sleep 3
  if ! port_in_use "$KOMARI_PORT"; then
    err "探针面板没有启动，最近的日志:"
    journalctl -u komari -n 8 --no-pager 2>/dev/null | cut -c1-200
    return 1
  fi
  ok "探针面板已启动"
  nat_hint "$KOMARI_PORT" "TCP" "探针面板"
  km_after_install
}

km_parse(){
  # km_parse 文本 短参数 长参数  -> 取出参数值（支持从官方安装命令里整行解析）
  echo "$1" | tr -d '\r' | sed -nE "s/.*(^|[[:space:]])(-$2|--$3)[[:space:]=]+[\"']?([^\"'[:space:]]+).*/\\3/p"
}
km_agent_install(){
  local a tmp inp ep tk rc="true"
  a=$(km_arch) || { err "CPU 架构不支持"; return 1; }
  if km_agent_installed; then
    warn "本机已经装了探针客户端，继续会用新的地址和密钥覆盖"
    confirm "继续吗" || return 0
  fi
  info "这台机器将被探针面板监控"
  echo "到探针网页后台点“添加节点”，复制它给出的安装命令，整行粘贴到这里。"
  echo "（没有安装命令也行：直接回车，然后分别输入面板地址和密钥）"
  inp=$(ask "粘贴安装命令: ")
  ep=$(km_parse "$inp" e endpoint); tk=$(km_parse "$inp" t token)
  if [[ -z "$ep" ]]; then
    local def=""
    km_server_installed && [[ -n "$KOMARI_PORT" ]] && def="http://127.0.0.1:${KOMARI_PORT}"
    ep=$(ask "探针面板地址（如 http://1.2.3.4:25774）${def:+，本机直接回车}: ")
    ep=${ep:-$def}
  fi
  [[ -z "$tk" ]] && tk=$(ask "节点密钥 (token): ")
  ep=$(echo "$ep" | tr -d '[:space:]'); ep=${ep%/}; tk=$(echo "$tk" | tr -d '[:space:]')
  [[ "$ep" =~ ^https?://[^/]+ && -n "$tk" ]] || { err "地址或密钥不对。地址要以 http:// 或 https:// 开头"; return 1; }
  local code
  code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "$ep/" 2>/dev/null)
  if [[ "$code" == "000" || -z "$code" ]]; then
    err "这台机器连不上探针面板 $ep"
    echo "常见原因: 地址或端口写错、面板那台的端口没放行（NAT 机要做端口映射）"
    confirm "仍然继续安装吗" || return 1
  else
    ok "能连上探针面板"
  fi
  line
  echo "要不要允许从探针网页【远程控制】这台机器（网页终端、远程执行命令）？"
  echo "  选 n: 只上报监控数据，最安全  [推荐]"
  echo "  选 y: 方便，但探针面板的账号一旦泄露，这台机器也会被控制"
  confirm "允许远程控制" && rc="false"
  tmp=$(mktemp -d)
  info "正在下载 Komari 客户端 ..."
  download "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-${a}" "$tmp/agent" \
    || { err "下载失败：服务器连不上 GitHub，稍后再试"; rm -rf "$tmp"; return 1; }
  mkdir -p "$KM_DIR" "$VK_DIR"
  systemctl stop komari-agent 2>/dev/null
  install -m 755 "$tmp/agent" "$KM_DIR/agent"; rm -rf "$tmp"
  # 密钥放在只有 root 能读的配置文件里，不写进服务文件（那里谁都能看到）
  ( umask 077; jq -n --arg e "$ep" --arg t "$tk" --argjson d "$rc" \
      '{endpoint:$e,token:$t,disable_web_ssh:$d}' > "$KM_AGENT_CONF" )
  chmod 600 "$KM_AGENT_CONF"
  cat > /etc/systemd/system/komari-agent.service <<EOF
[Unit]
Description=Komari Agent Service
After=network.target

[Service]
Type=simple
ExecStart=$KM_DIR/agent --config $KM_AGENT_CONF
WorkingDirectory=$KM_DIR
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable komari-agent >/dev/null 2>&1
  systemctl restart komari-agent
  sleep 4
  if systemctl is-active --quiet komari-agent; then
    ok "探针客户端已启动"
    echo "回到探针网页看一下，这台机器应该在几秒内显示为在线"
    [[ "$rc" == "true" ]] && echo "远程控制: 已关闭" || warn "远程控制: 已开启"
    if journalctl -u komari-agent --since "10 sec ago" --no-pager 2>/dev/null | grep -qiE 'unauthorized|invalid token|401|403'; then
      warn "日志里有认证失败的字样，密钥可能不对。到探针后台重新复制安装命令再试"
    fi
  else
    err "探针客户端启动失败，最近的日志:"
    journalctl -u komari-agent -n 8 --no-pager 2>/dev/null | cut -c1-200
    return 1
  fi
}

km_status(){
  line
  if km_server_installed; then
    echo "探针面板  : $(systemctl is-active komari 2>/dev/null)   地址: $(km_server_url)"
    [[ -n "$KOMARI_USER" ]] && echo "            账号: $KOMARI_USER   密码: $KOMARI_PASS"
  else echo "探针面板  : 本机未安装"; fi
  if km_agent_installed; then
    local ep rc
    ep=$(jq -r '.endpoint // "未知"' "$KM_AGENT_CONF" 2>/dev/null)
    rc=$(jq -r 'if .disable_web_ssh then "关闭" else "开启" end' "$KM_AGENT_CONF" 2>/dev/null)
    echo "探针客户端: $(systemctl is-active komari-agent 2>/dev/null)   连接到: ${ep:-未知}   远程控制: ${rc:-未知}"
  else echo "探针客户端: 本机未安装"; fi
  line
}

km_uninstall(){
  echo "1. 卸载探针客户端"
  echo "2. 卸载探针面板（监控历史数据会一起删除）"
  echo "0. 返回"
  case "$(ask '请选择: ')" in
    1)
      km_agent_installed || { warn "本机没装探针客户端"; return; }
      confirm "确认卸载探针客户端" || return
      systemctl disable komari-agent --now >/dev/null 2>&1
      rm -f /etc/systemd/system/komari-agent.service "$KM_DIR/agent" "$KM_AGENT_CONF"
      systemctl daemon-reload; ok "已卸载探针客户端"
      echo "探针网页后台里这台机器的记录需要你手动删除" ;;
    2)
      km_server_installed || { warn "本机没装探针面板"; return; }
      warn "卸载后，所有机器的监控历史和探针后台的账号都会删除，无法恢复"
      confirm "确认卸载探针面板" || return
      systemctl disable komari --now >/dev/null 2>&1
      rm -f /etc/systemd/system/komari.service "$KM_DIR/komari"
      rm -rf "$KM_DIR/data"
      systemctl daemon-reload; cloudflared service uninstall >/dev/null 2>&1; KOMARI_PORT=""; KOMARI_USER=""; KOMARI_PASS=""; KOMARI_DOMAIN=""; save_conf; ok "已卸载探针面板" ;;
  esac
}

km_domain_tunnel(){
  # 用 Cloudflare 隧道把域名接到本机的探针面板：不占 443，不用申请证书，不用开端口
  km_server_installed && [[ -n "$KOMARI_PORT" ]] || { err "本机没有装探针面板，先做 13 → 1"; return 1; }
  if [[ -n "$KOMARI_DOMAIN" ]]; then
    echo "当前已绑定域名: $KOMARI_DOMAIN"
    echo "1. 重新绑定    2. 解除绑定    0. 返回"
    case "$(ask '请选择: ')" in
      1) ;;
      2) cloudflared service uninstall >/dev/null 2>&1
         systemctl disable cloudflared --now >/dev/null 2>&1
         KOMARI_DOMAIN=""; save_conf; ok "已解除，探针地址恢复为 $(km_server_url)"
         echo "Cloudflare 后台里的隧道和域名记录需要你手动删除"; return 0 ;;
      *) return 0 ;;
    esac
  fi
  local a
  case "$(arch_name)" in amd64) a=amd64 ;; arm64) a=arm64 ;; *) err "CPU 架构不支持"; return 1 ;; esac
  info "需要域名的 DNS 在 Cloudflare 上。先在 Cloudflare 网页上做这几步:"
  echo "  1) 登录 Cloudflare，进入 Zero Trust（第一次进会让你起个团队名，选免费套餐）"
  echo "  2) 找到 Networks（网络）→ Tunnels（隧道）→ 创建隧道，类型选 Cloudflared，随便起个名字"
  echo "  3) 页面会显示一条安装命令，里面有一长串 eyJ 开头的字符。复制整条命令"
  echo "  4) 下一步“公共主机名 / Public Hostname”里这样填:"
  echo "       子域名: 自己起，如 status      域名: 选你的域名"
  echo "       类型(Service): HTTP          URL: localhost:${KOMARI_PORT}"
  info "     ↑ 这个端口号 ${KOMARI_PORT} 要照抄"
  echo "  5) 保存"
  line
  local inp tok dom tmp code i
  inp=$(ask "粘贴第 3 步复制的命令（或只粘贴 eyJ 开头那串）: ")
  tok=$(echo "$inp" | tr -d '\r' | grep -oE 'eyJ[A-Za-z0-9_=-]{40,}' | head -n1)
  [[ -n "$tok" ]] || { err "没找到 eyJ 开头的隧道令牌，请重新复制"; return 1; }
  dom=$(ask "你在第 4 步填的完整域名（如 status.example.com）: ")
  dom=$(echo "$dom" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##' | tr 'A-Z' 'a-z')
  [[ "$dom" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { err "域名格式不对"; return 1; }
  if [[ ! -x /usr/local/bin/cloudflared ]]; then
    tmp=$(mktemp -d)
    info "正在下载 Cloudflare 隧道程序 ..."
    download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${a}" "$tmp/cf" \
      || { err "下载失败：服务器连不上 GitHub，稍后再试"; rm -rf "$tmp"; return 1; }
    install -m 755 "$tmp/cf" /usr/local/bin/cloudflared; rm -rf "$tmp"
  fi
  cloudflared service uninstall >/dev/null 2>&1
  if ! cloudflared service install "$tok" >/dev/null 2>&1; then
    err "隧道服务安装失败，令牌可能不完整。请回 Cloudflare 重新复制安装命令"; return 1
  fi
  systemctl enable cloudflared >/dev/null 2>&1; systemctl restart cloudflared 2>/dev/null
  sleep 5
  systemctl is-active --quiet cloudflared || {
    err "隧道没有运行，最近的日志:"; journalctl -u cloudflared -n 6 --no-pager 2>/dev/null | cut -c1-200; return 1; }
  ok "隧道已连上 Cloudflare"
  info "正在检查 https://$dom 能不能打开 ..."
  code=000
  for i in 1 2 3 4 5 6; do
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$dom/" 2>/dev/null)
    [[ "$code" =~ ^(200|301|302|307|308)$ ]] && break
    sleep 5
  done
  KOMARI_DOMAIN=$dom; save_conf
  if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then
    ok "域名已生效"
  else
    warn "域名暂时还打不开（返回 $code），通常是这几个原因:"
    echo "  · 刚保存，等一两分钟再试"
    echo "  · Cloudflare 里的 URL 没填成 localhost:${KOMARI_PORT}，或类型没选 HTTP"
    echo "  · 填的域名和 Cloudflare 里的公共主机名不一致"
  fi
  line
  echo "探针地址: https://$dom"
  line
  echo "以后添加被监控机器时，探针后台给的安装命令里会用你打开网页时的这个域名。"
  echo "已经挂上的机器不受影响，不用重装。"
}

km_set_port(){
  # 把探针面板换到指定端口，并让本机的客户端跟着改
  local new=$1 old=$KOMARI_PORT f=/etc/systemd/system/komari.service
  [[ "$new" == "$old" ]] && return 0
  [[ -f "$f" ]] || { err "没找到探针的服务文件"; return 1; }
  sed -i -E "s#(server -l [0-9.]+:)[0-9]+#\1${new}#" "$f"
  grep -q ":${new}\$" "$f" || grep -q ":${new} " "$f" || { err "修改探针端口失败"; return 1; }
  KOMARI_PORT=$new; save_conf
  systemctl daemon-reload; systemctl restart komari; sleep 3
  if ! port_in_use "$new"; then
    err "探针在端口 $new 上没启动，正在改回 $old ..."
    sed -i -E "s#(server -l [0-9.]+:)[0-9]+#\1${old}#" "$f"
    KOMARI_PORT=$old; save_conf; systemctl daemon-reload; systemctl restart komari
    return 1
  fi
  open_fw "$new"
  if [[ -f "$KM_AGENT_CONF" ]] && grep -q "127.0.0.1:${old}\"" "$KM_AGENT_CONF"; then
    local t; t=$(mktemp)
    jq --arg e "http://127.0.0.1:${new}" '.endpoint=$e' "$KM_AGENT_CONF" > "$t" && command cat "$t" > "$KM_AGENT_CONF"
    rm -f "$t"; systemctl restart komari-agent 2>/dev/null
  fi
  ok "探针端口已从 $old 改为 $new"
}
KM_NGX_CONF="/etc/nginx/conf.d/vpskit-komari.conf"
km_nginx_proxy(){
  # km_nginx_proxy 域名  -> 让已有的 nginx 把这个域名的访问转给探针，别的站点不动
  local dom=$1 bak=""
  [[ -d /etc/nginx/conf.d ]] || { err "没找到 nginx 的配置目录 /etc/nginx/conf.d"; return 1; }
  if grep -rlE "server_name[^;]*[[:space:]]${dom//./\\.}[[:space:];]" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null \
       | grep -qv "^${KM_NGX_CONF}\$"; then
    err "nginx 里已经有别的站点在用 $dom 这个域名了，请换一个子域名"; return 1
  fi
  [[ -f "$KM_NGX_CONF" ]] && { bak=$(mktemp); command cp -f "$KM_NGX_CONF" "$bak"; }
  cat > "$KM_NGX_CONF" <<EOF
# 由 vpskit 生成: 把 $dom 的访问转给本机的 Komari 探针
server {
    listen 80;
    listen [::]:80;
    server_name $dom;
    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:${KOMARI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$http_x_forwarded_proto;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
  if ! nginx -t >/dev/null 2>&1; then
    err "nginx 检查新配置没通过，已撤销，原有网站不受影响。报错如下:"
    nginx -t 2>&1 | tail -n 3
    if [[ -n "$bak" ]]; then command cp -f "$bak" "$KM_NGX_CONF"; else rm -f "$KM_NGX_CONF"; fi
    [[ -n "$bak" ]] && rm -f "$bak"
    return 1
  fi
  [[ -n "$bak" ]] && rm -f "$bak"
  systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null
  sleep 1
  local c
  c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Host: $dom" http://127.0.0.1:80/ 2>/dev/null)
  if [[ "$c" =~ ^(200|301|302|307|308)$ ]]; then ok "nginx 已经把 $dom 转给探针了"
  else warn "nginx 规则加上了，但本机试访问返回 $c，稍后看域名检查的结果"; fi
}
km_domain_simple(){
  # 最简单的办法: 探针开在 80 端口，Cloudflare 加一条开着小黄云的解析
  if [[ "$NAT" == "1" ]]; then
    warn "NAT 机用不了 80 端口，这个办法不行，请改用【隧道】方式"; return 1
  fi
  local via_nginx=0
  if [[ "$KOMARI_PORT" != "80" ]] && port_in_use 80; then
    if command -v nginx >/dev/null 2>&1 && ss -lntpH 2>/dev/null | awk '$4 ~ /:80$/' | grep -q nginx; then
      via_nginx=1
      info "本机 80 端口上已经有 nginx 在运行。"
      echo "工具会给它加一条规则：只有用你的探针域名访问时才转给探针，nginx 上原有的网站不受影响。"
      line
    else
      err "本机的 80 端口已经被别的程序占用了，这个办法不行，请改用【隧道】方式"
      ss -lntpH 2>/dev/null | awk '$4 ~ /:80$/ {print "  占用者: " $NF}' | head -n 2
      return 1
    fi
  fi
  local ip dom code i
  ip=$(get_host)
  info "先在 Cloudflare 网页上做两件事:"
  echo "  1) 点你的域名 → DNS → 添加记录:"
  echo "       类型: A     名称: 自己起，如 status     IPv4 地址: $ip"
  echo "       代理状态: 打开（云朵是橙色的）"
  echo "  2) 点你的域名 → SSL/TLS → 概述 → 加密模式，选【灵活 / Flexible】"
  line
  warn "两点说明:"
  echo "  · 【灵活】模式对这个域名下的所有网站都生效。域名上还有别的网站在用的话先别选，改用隧道"
  echo "  · 你到 Cloudflare 这段是加密的；Cloudflare 到这台服务器这段不加密"
  line
  dom=$(ask "你在第 1 步设置的完整域名（如 status.example.com；回车取消）: ")
  [[ -z "$dom" ]] && return 0
  dom=$(echo "$dom" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##' | tr 'A-Z' 'a-z')
  [[ "$dom" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { err "域名格式不对"; return 1; }
  if (( via_nginx )); then
    km_nginx_proxy "$dom" || return 1
  elif [[ "$KOMARI_PORT" != "80" ]]; then
    warn "探针要换到 80 端口。已经挂上的【其他机器】会连不上，需要在它们上面重新粘贴一次安装命令"
    confirm "继续吗" || return 0
    km_set_port 80 || return 1
  fi
  info "正在检查 https://$dom 能不能打开 ..."
  code=000
  for i in 1 2 3 4 5 6; do
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$dom/" 2>/dev/null)
    [[ "$code" =~ ^(200|301|302|307|308)$ ]] && break
    sleep 5
  done
  KOMARI_DOMAIN=$dom; save_conf
  if [[ "$code" =~ ^(200|301|302|307|308)$ ]]; then ok "域名已生效"
  else
    warn "域名暂时还打不开（返回 $code），对照检查:"
    echo "  · 刚加的解析，等一两分钟再试"
    echo "  · 返回 521 / 522 / 525: 加密模式没选成【灵活】，或云朵不是橙色"
    echo "  · 解析里的 IP 是不是 $ip"
  fi
  line
  echo "探针地址: https://$dom"
  line
}
km_domain(){
  km_server_installed && [[ -n "$KOMARI_PORT" ]] || { err "本机没有装探针面板，先做 13 → 1"; return 1; }
  if [[ -n "$KOMARI_DOMAIN" ]]; then
    echo "当前已绑定域名: $KOMARI_DOMAIN"
    echo "1. 重新绑定    2. 解除绑定    0. 返回"
    case "$(ask '请选择: ')" in
      1) KOMARI_DOMAIN="" ;;
      2) cloudflared service uninstall >/dev/null 2>&1
         systemctl disable cloudflared --now >/dev/null 2>&1
         if [[ -f "$KM_NGX_CONF" ]]; then rm -f "$KM_NGX_CONF"; nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null; fi
         KOMARI_DOMAIN=""; save_conf; ok "已解除，探针地址恢复为 $(km_server_url)"
         echo "Cloudflare 后台里的解析记录（或隧道）需要你手动删除"; return 0 ;;
      *) return 0 ;;
    esac
  fi
  echo "域名的 DNS 需要在 Cloudflare 上。选一种方式:"
  echo "1. 加一条解析就行  [最简单]"
  echo "   探针会换到 80 端口；需要把域名的加密模式设为【灵活】"
  echo "2. Cloudflare 隧道"
  echo "   设置步骤多一些，但全程加密、不用开端口，NAT 机或 80 端口被占用时用这个"
  echo "0. 返回"
  case "$(ask '请选择: ')" in
    1) km_domain_simple ;;
    2) km_domain_tunnel ;;
  esac
}

menu_komari(){
  clear; info "== Komari 探针（看所有机器的在线、流量、负载） =="
  km_status
  echo "1. 安装探针面板   （只在一台机器上装，用浏览器看）"
  echo "2. 安装探针客户端 （每台要监控的机器都装）"
  echo "3. 重启探针"
  echo "4. 卸载"
  echo "5. 给探针绑定域名 （用 Cloudflare，网址变成 https://你的域名）"
  echo "0. 返回"
  case "$(ask '请选择: ')" in
    1) km_server_install ;;
    2) km_agent_install ;;
    3) km_server_installed && systemctl restart komari
       km_agent_installed && systemctl restart komari-agent
       sleep 2; km_status ;;
    4) km_uninstall ;;
    5) km_domain ;;
    *) return ;;
  esac
  pause
}

# ---------- 被墙检测 ----------
check_block(){
  clear; info "== 检测 IP / 端口是否被墙 =="
  local host port
  host=$(get_host)
  [[ -z "$host" ]] && { err "拿不到公网IP"; pause; return; }
  if [[ -s "$VK_NODES" ]]; then
    echo "已有节点端口:"; awk -F'|' '{print "  "$3"  ("$1")"}' "$VK_NODES"
  fi
  port=$(ask "要检测的端口: ")
  valid_port "$port" || { err "端口不对"; pause; return; }
  echo "检测对象: $host:$port"
  line
  echo "[1/3] 本机是否在监听"
  if port_in_use "$port"; then ok "端口在监听"
  else err "本机没有程序在用这个端口 → 不是被墙，是服务没起来，请运行【一键排查】"; pause; return; fi
  local tport=$port is_udp=0
  if grep -qE "\|(hysteria2|tuic)\|${port}\|" "$VK_NODES" 2>/dev/null; then
    is_udp=1
    warn "这是 UDP 节点，外部检测工具只能测 TCP，没法直接测它"
    if [[ -n "$PANEL_PORT" ]] && port_in_use "$PANEL_PORT"; then
      tport=$PANEL_PORT
      echo "改用面板端口 $tport 来判断这个 IP 有没有被墙"
    else
      err "本机没有可用来代测的 TCP 端口，请先装面板或建一个 VLESS 节点再测"; pause; return
    fi
  fi
  echo "[2/3] 从国外多个地点连接测试"
  local r id res total good foreign="skip"
  r=$(curl -s -m 15 -H 'Accept: application/json' "https://check-host.net/check-tcp?host=${host}:${tport}&max_nodes=8")
  id=$(echo "$r" | jq -r '.request_id // empty' 2>/dev/null)
  if [[ -z "$id" ]]; then
    warn "国外检测服务暂时不可用，跳过这一步"
  else
    sleep 8
    res=$(curl -s -m 15 -H 'Accept: application/json' "https://check-host.net/check-result/$id")
    total=$(echo "$res" | jq 'length' 2>/dev/null)
    good=$(echo "$res" | jq '[.[] | select(. != null) | .[0] | select(type=="object" and .time != null)] | length' 2>/dev/null)
    echo "国外检测点: ${good:-0} / ${total:-0} 个能连上"
    if [[ "${good:-0}" -ge 1 ]]; then ok "国外能连上 → 服务器本身正常"; foreign="ok"
    else err "国外也连不上"; foreign="fail"; fi
  fi
  if [[ "$foreign" == "fail" ]]; then
    block_verdict "不是被墙，是服务器这边端口没通到外面" \
      "$([[ "$NAT" == "1" ]] \
          && echo "到商家后台检查端口映射: 外部 $tport → 内部 $tport，协议 TCP，状态为启用" \
          || echo "到商家后台的【防火墙 / 安全组】里放行端口 $tport")" \
      "改完后重新运行本检测；仍不通就运行菜单 9【一键排查并修复】"
    pause; return
  fi
  echo "[3/3] 从国内测试（需要你动手一步）"
  echo "手机或电脑【关掉代理】后，用浏览器打开:  https://www.itdog.cn/tcping/"
  echo "输入下面这串，点测试:"
  info "    $host:$tport"
  echo "看地图颜色，然后回来选:"
  echo "1. 基本全绿（国内大部分地方能连）"
  echo "2. 基本全红（国内大部分地方超时）"
  echo "0. 现在没法测，先跳过"
  local a b other=""
  a=$(ask "请选择: ")
  case "$a" in
    1)
      if (( is_udp )); then
        block_verdict "IP 没有被墙" \
          "这个节点走 UDP，连不上多半是 UDP 被拦: NAT 机检查端口 $port 的映射协议是否选了 UDP" \
          "手机客户端打开“允许不安全”；小火箭测速方式改成 CONNECT" \
          "还不行就换用 VLESS + Reality 节点（走 TCP，最稳）"
      else
        block_verdict "线路正常，IP 和端口都没有被墙" \
          "问题在你的手机/电脑这边: 更新代理软件，删掉节点后重新导入链接" \
          "检查设备时间是否准确（差几分钟就会连不上）" \
          "能连上但打不开网页: 运行菜单 9【一键排查并修复】"
      fi ;;
    2)
      # 再测一个端口，区分"只封了这个端口"和"整个 IP 被墙"
      if [[ -n "$PANEL_PORT" && "$PANEL_PORT" != "$tport" ]] && port_in_use "$PANEL_PORT"; then other=$PANEL_PORT
      else other=$(awk -F'|' -v p="$tport" '$2!="hysteria2" && $2!="tuic" && $2!="relay" && $3!=p {print $3; exit}' "$VK_NODES" 2>/dev/null); fi
      b=2
      if [[ -n "$other" ]]; then
        line
        echo "再测一个端口，看是只封了这一个端口，还是整个 IP 都不通。"
        echo "在 itdog 里把输入换成:"
        info "    $host:$other"
        echo "1. 这个基本全绿    2. 这个也基本全红"
        b=$(ask "请选择: ")
      fi
      if [[ "$b" == "1" ]]; then
        block_verdict "只有端口 $tport 被封，IP 没事" \
          "运行菜单 5【一键搭建节点】重新建一个（会自动换新端口）" \
          "旧节点可以在面板的“入站”页面里删掉"
      else
        block_verdict "这台机器的 IP 被墙了，换端口、换协议都没用" \
          "办法一（推荐）: 找一台国内能直连的机器当中转。在那台上运行 vk → 7 → 3【链式代理】，粘贴下面的链接" \
          "办法二: 找商家换 IP，换完回来运行菜单 3 更新连接地址"
        local nl
        nl=$(awk -F'|' '$2=="vless-reality"{print $4; exit}' "$VK_NODES" 2>/dev/null)
        [[ -z "$nl" ]] && nl=$(awk -F'|' '$2!="relay"{print $4; exit}' "$VK_NODES" 2>/dev/null)
        if [[ -n "$nl" ]]; then
          echo "本机节点链接（给中转机用，整行复制）:"; echo "$nl"
        else
          echo "本机还没有节点: 先运行菜单 5 建一个 VLESS + Reality，再拿它的链接去中转机"
        fi
      fi ;;
    *)
      echo "之后测完可以再运行本检测。判断方法:"
      echo "国内全绿 → 没被墙；国内全红 → 被墙（走中转或换 IP）" ;;
  esac
  pause
}
block_verdict(){
  # block_verdict 结论 办法1 [办法2] [办法3]
  line
  info "结论: $1"
  shift
  echo "接下来这样做:"
  local s
  for s in "$@"; do echo "  · $s"; done
  line
}

# ---------- 排查与修复 ----------
has_resolved(){ systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; }
ensure_resolved(){
  # s-ui 的内核通过 systemd-resolved 查域名；它没运行时节点"连得上但打不开网页"
  has_resolved || return 0
  systemctl is-active --quiet systemd-resolved && return 0
  systemctl enable --now systemd-resolved >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet systemd-resolved
}
dns_works(){ timeout 8 getent hosts github.com >/dev/null 2>&1; }
fix_dns(){
  # 在 diagnose 里调用，直接累加它的 fixed / bad
  local restart_panel=0
  if has_resolved && ! systemctl is-active --quiet systemd-resolved; then
    warn "系统的域名解析服务没有运行，正在启动 ..."
    if ensure_resolved; then ok "域名解析服务已启动"; fixed=$((fixed+1)); restart_panel=1
    else err "域名解析服务启动失败"; bad=$((bad+1)); fi
  fi
  if ! dns_works; then
    warn "域名解析失败，尝试修复 ..."
    if [[ -L /etc/resolv.conf ]] && has_resolved; then
      mkdir -p /etc/systemd/resolved.conf.d
      printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=9.9.9.9\n' > /etc/systemd/resolved.conf.d/vpskit.conf
      systemctl restart systemd-resolved >/dev/null 2>&1; sleep 2
    else
      [[ -e /etc/resolv.conf && ! -e /etc/resolv.conf.vkbak ]] && cp -fP /etc/resolv.conf /etc/resolv.conf.vkbak 2>/dev/null
      rm -f /etc/resolv.conf
      printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    fi
    if dns_works; then ok "域名解析已修复"; fixed=$((fixed+1)); restart_panel=1
    else err "域名解析修复失败"; bad=$((bad+1)); fi
  else
    ok "域名解析正常"
  fi
  # 面板日志里的解析报错：系统看着正常，但内核查不到域名
  if [[ "$PANEL" == "sui" ]] && journalctl -u s-ui --since "15 min ago" --no-pager 2>/dev/null \
       | grep -q 'org.freedesktop.resolve1'; then
    warn "面板日志里有域名解析报错（节点会连得上但打不开网页）"
    if has_resolved && ! timeout 8 resolvectl query github.com >/dev/null 2>&1; then
      err "系统内部通信卡住了，需要重启服务器才能恢复"; bad=$((bad+1))
      if confirm "现在重启服务器吗（约 1-2 分钟后重新连接即可）"; then reboot; exit 0; fi
      return
    fi
    restart_panel=1
  fi
  if (( restart_panel )) && [[ -n "$PANEL" ]]; then
    systemctl restart "$(panel_service)"; sleep 3
    ok "已重启面板，让它用上修好的域名解析"
  fi
}
diagnose(){
  clear; info "== 一键排查并修复 =="
  local fixed=0 bad=0 svc
  # 网络
  if curl -s -m 8 -o /dev/null https://www.cloudflare.com; then ok "外网连接正常"
  else err "服务器访问不了外网（请联系商家）"; bad=$((bad+1)); fi
  fix_dns
  # 时间
  if command -v timedatectl >/dev/null 2>&1; then
    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then ok "系统时间已同步"
    else
      timedatectl set-ntp true >/dev/null 2>&1
      warn "系统时间未同步，已尝试开启自动同步（时间不准会导致节点连不上）"; fixed=$((fixed+1))
    fi
  fi
  # 硬盘
  local use; use=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
  if (( use >= 95 )); then err "硬盘快满了 (${use}%)，面板可能无法保存"; bad=$((bad+1)); else ok "硬盘空间够用 (${use}%)"; fi
  # 面板
  if [[ -n "$PANEL" ]]; then
    svc=$(panel_service)
    if systemctl is-active --quiet "$svc"; then ok "面板服务在运行"
    else
      warn "面板服务没在运行，正在重启 ..."
      systemctl restart "$svc"; sleep 3
      if systemctl is-active --quiet "$svc"; then ok "已重启成功"; fixed=$((fixed+1))
      else
        err "面板启动失败，最近的错误日志:"; bad=$((bad+1))
        journalctl -u "$svc" -n 8 --no-pager 2>/dev/null | cut -c1-200
      fi
    fi
    if port_in_use "$PANEL_PORT"; then ok "面板端口 $PANEL_PORT 正常"
    else err "面板端口 $PANEL_PORT 没有监听"; bad=$((bad+1)); fi
    if [[ -n "$PORT_MIN" ]] && ! in_range "$PANEL_PORT"; then
      err "面板端口不在 NAT 可用范围内，外面访问不到 → 请重新运行【安装面板】"; bad=$((bad+1))
    fi
  else
    warn "还没安装面板"
  fi
  # 节点端口
  if [[ -s "$VK_NODES" ]]; then
    local name proto port link down=0
    while IFS='|' read -r name proto port link; do
      [[ "$proto" == "relay" ]] && continue
      if port_in_use "$port"; then ok "节点 $name 端口正常"
      else err "节点 $name 端口 $port 没有监听"; down=1; fi
    done < "$VK_NODES"
    if (( down )) && [[ -n "$PANEL" ]]; then
      warn "尝试重启面板来恢复节点 ..."
      systemctl restart "$(panel_service)"; sleep 4
      local still=0
      while IFS='|' read -r name proto port link; do
        [[ "$proto" == "relay" ]] && continue
        port_in_use "$port" || still=1
      done < "$VK_NODES"
      if (( still )); then err "仍有节点没恢复（可能在面板里被删了）"; bad=$((bad+1))
      else ok "节点已恢复"; fixed=$((fixed+1)); fi
    fi
  fi
  # 转发
  if [[ -s "$VK_FWD" ]]; then
    if systemctl is-active --quiet vpskit-realm; then ok "中转转发在运行"
    else
      systemctl restart vpskit-realm; sleep 1
      systemctl is-active --quiet vpskit-realm && { ok "中转转发已重启"; fixed=$((fixed+1)); } \
        || { err "中转转发启动失败"; bad=$((bad+1)); }
    fi
  fi
  # 探针
  local ksvc
  for ksvc in komari komari-agent; do
    [[ -f "/etc/systemd/system/$ksvc.service" ]] || continue
    if systemctl is-active --quiet "$ksvc"; then ok "探针服务 $ksvc 在运行"
    else
      systemctl restart "$ksvc"; sleep 2
      systemctl is-active --quiet "$ksvc" && { ok "探针服务 $ksvc 已重启"; fixed=$((fixed+1)); } \
        || { err "探针服务 $ksvc 启动失败"; bad=$((bad+1)); }
    fi
  done
  # 防火墙
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local p ports=""
    [[ -n "$PANEL_PORT" ]] && ports="$PANEL_PORT"
    [[ -s "$VK_NODES" ]] && ports="$ports $(awk -F'|' '{print $3}' "$VK_NODES" | tr '\n' ' ')"
    for p in $ports; do
      ufw status | grep -qE "^$p(/| )" || { ufw allow "$p" >/dev/null 2>&1; warn "防火墙未放行 $p，已放行"; fixed=$((fixed+1)); }
    done
    ok "系统防火墙检查完成"
  else
    ok "系统防火墙未开启（不会拦截）"
  fi
  line
  echo "自动修复: $fixed 项   仍有问题: $bad 项"
  if (( bad == 0 )); then
    echo "本机检查都正常。如果还是连不上，常见原因是:"
    echo "1) 商家后台的防火墙/安全组没放行端口"
    echo "2) IP 或端口被墙 → 用【被墙检测】"
    echo "3) 手机代理软件太旧，不支持该协议"
  else
    echo "请运行【生成诊断报告】，把内容发给开发者"
  fi
  pause
}

report(){
  local f="/root/vpskit-report.txt" svc
  {
    echo "=== vpskit 诊断报告 v$VK_VERSION  $(date '+%F %T') ==="
    . /etc/os-release 2>/dev/null; echo "系统: ${PRETTY_NAME:-?}  内核: $(uname -r)  架构: $(uname -m)"
    echo "虚拟化: $(systemd-detect-virt 2>/dev/null)  内存: $(awk '/MemTotal/{printf "%dMB", $2/1024}' /proc/meminfo)"
    echo "面板: ${PANEL:-无}  面板端口: ${PANEL_PORT:-无}  协议: $PANEL_SCHEME"
    echo "NAT: $NAT  端口范围: ${PORT_MIN:-不限}-${PORT_MAX:-不限}  内外同端口: $NAT_SAMEPORT  保留端口: ${PORT_EXCLUDE:-无}"
    echo "令牌: $([[ -n "$API_TOKEN" ]] && echo 已设置 || echo 未设置)"
    echo "--- 节点 ---"
    [[ -s "$VK_NODES" ]] && awk -F'|' '{print $1" "$2" "$3}' "$VK_NODES"
    echo "--- 转发 ---"
    [[ -s "$VK_FWD" ]] && sed -E 's/\|[^|]+\|/|<落地IP>|/' "$VK_FWD"
    echo "--- 监听端口 ---"
    ss -lntuH 2>/dev/null | awk '{print $1, $5, $7}' | head -n 40
    for svc in s-ui x-ui vpskit-realm komari komari-agent cloudflared; do
      systemctl list-unit-files 2>/dev/null | grep -q "^$svc.service" || continue
      echo "--- 服务 $svc: $(systemctl is-active "$svc" 2>/dev/null) ---"
      journalctl -u "$svc" -n 25 --no-pager 2>/dev/null | cut -c1-220
    done
    echo "--- 防火墙 ---"
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 20
  } 2>&1 | sed -E 's/([0-9]{1,3}\.[0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}/\1.x.x/g' > "$f"
  clear; cat "$f"; line
  ok "报告已保存到 $f（已隐藏密码和完整IP）"
  echo "把上面的内容全部复制，发给开发者即可"
  pause
}

# ---------- 新手向导 ----------
wizard(){
  do_check; pause
  set_ports || return
  pause
  install_panel || { pause; return; }
  pause
  if confirm "现在就建一个推荐节点（VLESS + Reality）吗"; then
    if [[ "$PANEL" == "sui" ]]; then sui_token && sui_vless_reality
    else xui_token && xui_vless_reality; fi
  fi
  pause
}

# ---------- 主菜单 ----------
main_menu(){
  while true; do
    clear
    info "=== vpskit 一键工具 v$VK_VERSION ==="
    local st="未安装面板"
    [[ "$PANEL" == "sui" ]] && st="s-ui"
    [[ "$PANEL" == "xui" ]] && st="3x-ui"
    echo "面板: $st   $([[ "$NAT" == "1" ]] && echo "NAT 机 $PORT_MIN-$PORT_MAX" || echo "普通机器")"
    line
    echo " 1. 新手向导（第一次用选这个）"
    echo " 2. 开机体检"
    echo " 3. 机器类型与端口（NAT 机设置）"
    echo " 4. 安装面板"
    echo " 5. 一键搭建节点"
    echo " 6. 查看我的节点"
    echo " 7. 中转 / 端口转发"
    echo " 8. 检测是否被墙"
    echo " 9. 一键排查并修复"
    echo "10. 生成诊断报告"
    echo "11. 备份与撤销"
    echo "12. 查看面板地址和密码"
    echo "13. Komari 探针（监控所有机器）"
    echo " 0. 退出"
    line
    case "$(ask '请输入数字: ')" in
      1) wizard ;;
      2) do_check; pause ;;
      3) set_ports; pause ;;
      4) install_panel; pause ;;
      5) menu_node ;;
      6) list_nodes ;;
      7) menu_relay ;;
      8) check_block ;;
      9) diagnose ;;
      10) report ;;
      11) menu_backup ;;
      12) show_panel; pause ;;
      13) menu_komari ;;
      0) exit 0 ;;
    esac
  done
}

main(){
  need_root
  load_conf
  install_deps || exit 1
  self_install
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
