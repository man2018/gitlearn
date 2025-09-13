#!/data/data/com.termux/files/usr/bin/bash
# Termux + Clash/Sing-box(TUN) 初始化 + 守护（强制使用 Termux 版 iptables）
# 需要 root 运行（建议 tsu）

set -eu

# ===== 可按需修改 =====
TUN="tun0"             # TUN 接口名
DEV_FALLBACK="wlan0"   # 自动探测不到入口时的回退（常见 ap0 或 wlan0）
TABLE_ID=200           # 策略路由表编号
PREF=18000             # 我们规则优先级（实际用 PREF-1）
INTERVAL=3             # 守护巡检间隔（秒）
# =====================

# 固定命令路径
IP="/system/bin/ip"
IPT="/data/data/com.termux/files/usr/bin/iptables"  # Termux 版（xtables-nft）

log(){ echo "[$(date +%H:%M:%S)] $*"; }
need_root(){ [ "$(id -u)" = "0" ] || { log "ERROR: 需要 root（用 tsu -c 运行）"; exit 1; }; }

# ====== 关键自检（避免走到 /system/bin/iptables）======
selfcheck() {
  if [ ! -x "$IPT" ]; then
    log "ERROR: 未找到 Termux iptables：$IPT"
    log "请先执行：pkg install iptables -y"
    exit 1
  fi
  # 显示当前将使用的 iptables 与版本
  "$IPT" -V || { log "ERROR: 运行 $IPT 失败"; exit 1; }
  # 测试 nat 表是否可用
  if ! "$IPT" -t nat -S >/dev/null 2>&1; then
    log "ERROR: $IPT 的 nat 表不可用（请确认安装了 Termux 版本 iptables）"
    exit 1
  fi
}
# =====================================================

detect_dev() {
  if $IP -br link 2>/dev/null | grep -q "^ap0\\b"; then echo ap0
  elif $IP -br link 2>/dev/null | grep -q "^wlan0\\b"; then echo wlan0
  else echo "$DEV_FALLBACK"; fi
}

enable_forward(){ echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true; }
tun_up(){ $IP -br link show "$TUN" 2>/dev/null | grep -q "UP"; }

# 幂等追加 iptables 规则：存在则跳过
ipt_ensure(){ "$IPT" -C "$@" 2>/dev/null || "$IPT" -A "$@"; }

# 放行转发 + NAT（使用 Termux iptables 的 nat 表）
ensure_fw_nat() {
  # FORWARD 放行
  ipt_ensure FORWARD -i "$DEV" -o "$TUN" -j ACCEPT
  ipt_ensure FORWARD -i "$TUN" -o "$DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT
  # 出 TUN 做源地址伪装
  ipt_ensure -t nat POSTROUTING -o "$TUN" -j MASQUERADE
}

# 策略路由：入口接口 → 查表 200；main 表兜底
ensure_ip_rules() {
  $IP rule | grep -q "from all iif $DEV lookup $TABLE_ID" || \
    $IP rule add from all iif "$DEV" table "$TABLE_ID" pref $(($PREF-1)) 2>/dev/null || true
  $IP rule | grep -q "from all lookup main" || \
    $IP rule add from all table main pref "$PREF" 2>/dev/null || true
}

# 表 200 维持默认路由指向 TUN（TUN up 时操作）
ensure_tbl_default(){
  tun_up && $IP -4 route replace default dev "$TUN" table "$TABLE_ID" 2>/dev/null || true
}

wait_tun(){
  for i in 1 2 3 4 5 6 7 8 9 10; do tun_up && return 0; sleep 1; done; return 1;
}

# --------------- 主流程 ---------------
need_root
selfcheck   # <<< 先自检：确保用的是 Termux iptables 并且 nat 可用

DEV="$(detect_dev)"
log "入口: $DEV, TUN: $TUN, 表: $TABLE_ID"

enable_forward
ensure_ip_rules
ensure_fw_nat
wait_tun || log "WARN: $TUN 未就绪，守护循环将持续尝试"
ensure_tbl_default
log "INIT done. (Termux iptables @ $IPT)"

CONTAIN="from all iif $DEV lookup $TABLE_ID"
while :; do
  # TUN 若刚起来/重建，补默认路由
  ensure_tbl_default

  # 策略路由丢失就补
  if ! $IP rule | grep -q "$CONTAIN"; then
    if $IP -br link show "$DEV" 2>/dev/null | grep -q "UP"; then
      $IP rule add from all iif "$DEV" table "$TABLE_ID" pref $(($PREF-1)) 2>/dev/null || true
      log "network changed, reset routing policy."
    else
      log "$DEV is down."
    fi
  fi

  # FORWARD/NAT 可能被清空，定期补强（幂等）
  ensure_fw_nat

  sleep "$INTERVAL"
done
