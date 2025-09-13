#!/data/data/com.termux/files/usr/bin/bash
# Android/Termux 环境，仅使用系统自带 iptables (/system/bin/iptables)
# 初始化 + 守护：入口(热点) -> PBR(table 200) -> tun0
# 需要 root 运行

set -eu

# ===== 可改参数 =====
TUN="tun0"          # Clash/Sing-box 的 TUN 接口名
DEV_FALLBACK="wlan0" # 自动探测失败时使用的入口接口
TABLE_ID=200        # 策略路由表编号（推荐 100~252 之间未占用）
PREF=18000          # 我们自己的规则优先级（实际用 PREF-1）
INTERVAL=3          # 巡检间隔秒
# ====================

# 固定使用系统自带工具
IP="/system/bin/ip"
IPT="/system/bin/iptables"

log() { echo "[$(date +%H:%M:%S)] $*"; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    log "ERROR: 需要 root。请用 su/tsu 运行。"
    exit 1
  fi
}

detect_dev() {
  # 优先使用 ap0（许多机型热点接口），否则 wlan0，再否则用 DEV_FALLBACK
  if $IP -br link 2>/dev/null | grep -q "^ap0\\b"; then
    echo "ap0"
  elif $IP -br link 2>/dev/null | grep -q "^wlan0\\b"; then
    echo "wlan0"
  else
    echo "$DEV_FALLBACK"
  fi
}

enable_forwarding() {
  # 不用 sysctl，直接写 /proc
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
}

ipt_ensure() {
  # 幂等追加规则：存在则不加，不存在则 -A
  # 用 -C 检查是否存在；不支持 -C 的机型会返回非0，继续 -A 尝试
  $IPT -C "$@" 2>/dev/null || $IPT -A "$@"
}

nat_available() {
  # 检测 nat 表是否可用
  $IPT -t nat -S >/dev/null 2>&1
}

ensure_fw_nat() {
  # 放行入口 -> TUN 的转发
  ipt_ensure FORWARD -i "$DEV" -o "$TUN" -j ACCEPT
  # 放行 TUN 回程
  ipt_ensure FORWARD -i "$TUN" -o "$DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT

  if nat_available; then
    ipt_ensure -t nat POSTROUTING -o "$TUN" -j MASQUERADE
  else
    # 某些 ROM 的 /system/bin/iptables 不带 nat 表
    log "WARN: 系统 iptables 不支持 nat 表，已跳过 MASQUERADE（NAT）。"
  fi
}

ensure_ip_rules() {
  # from 入口接口 -> 查我们自定义表
  if ! $IP rule | grep -q "from all iif $DEV lookup $TABLE_ID"; then
    $IP rule add from all iif "$DEV" table "$TABLE_ID" pref $(($PREF - 1)) 2>/dev/null || true
  fi
  # main 表兜底
  if ! $IP rule | grep -q "from all lookup main"; then
    $IP rule add from all table main pref "$PREF" 2>/dev/null || true
  fi
}

tun_up() {
  $IP -br link show "$TUN" 2>/dev/null | grep -q "UP"
}

ensure_table_default() {
  # TUN up 才维护默认路由
  if tun_up; then
    $IP -4 route replace default dev "$TUN" table "$TABLE_ID" 2>/dev/null || true
  fi
}

wait_tun() {
  # 初始阶段等 TUN 最多10秒
  n=0
  while [ $n -lt 10 ]; do
    if tun_up; then return 0; fi
    n=$((n+1)); sleep 1
  done
  return 1
}

# --------------- 主流程 ---------------

need_root
DEV="$(detect_dev)"
log "入口接口: $DEV, TUN: $TUN, 路由表: $TABLE_ID"

enable_forwarding
ensure_ip_rules
ensure_fw_nat
wait_tun || log "WARN: $TUN 暂未就绪，守护循环中将持续尝试。"
ensure_table_default
log "INIT done."

# 守护循环：持续修复
CONTAIN="from all iif $DEV lookup $TABLE_ID"
while :; do
  # TUN 若刚重建/UP，补默认路由
  ensure_table_default

  # 策略路由丢了就补
  if ! $IP rule | grep -q "$CONTAIN"; then
    if $IP -br link show "$DEV" 2>/dev/null | grep -q "UP"; then
      $IP rule add from all iif "$DEV" table "$TABLE_ID" pref $(($PREF - 1)) 2>/dev/null || true
      log "network changed, reset routing policy."
    else
      log "$DEV is down."
    fi
  fi

  # 转发/NAT 可能被清空，定期补强
  ensure_fw_nat

  sleep "$INTERVAL"
done
