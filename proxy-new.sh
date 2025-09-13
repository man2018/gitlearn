#!/data/data/com.termux/files/usr/bin/bash
# Termux + Clash(TUN) 初始化 + 守护脚本
# 功能：wlan0 -> PBR(table 200) -> tun0，含NAT/转发/幂等修复
set -Eeuo pipefail

# ======== 可按需修改的参数 ========
TUN="tun0"          # Clash/TUN 的虚拟接口名
DEV="wlan0"         # 上游入口接口：手机Wi-Fi/热点；如你的机型是 ap0，请改成 ap0
TABLE_ID=200        # 自定义策略路由表号（用数字，避免 rt_tables 注册）
PREF=18000          # 我们自家规则优先级（实际用 PREF-1）
INTERVAL=3          # 巡检间隔（秒）
# =================================

# 确保使用 Termux 的工具链
export PATH="/data/data/com.termux/files/usr/bin:$PATH"

# 确保是 root；若可用 tsu 则自动提权重启本脚本
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v tsu >/dev/null 2>&1; then
    exec tsu -c "$0"
  else
    echo "[ERR] 需要 root 权限（推荐先安装：pkg i tsu）" >&2
    exit 1
  fi
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

# 幂等添加 iptables 规则
ipt_add() { iptables "$@" 2>/dev/null || true; }
ipt_ensure() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }

# 允许转发 + NAT（幂等）
ensure_fw_nat() {
  # 放行 DEV -> TUN 方向数据
  ipt_ensure FORWARD -i "$DEV" -o "$TUN" -j ACCEPT
  # 放行回程（已建立连接）
  ipt_ensure FORWARD -i "$TUN" -o "$DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT
  # 出 TUN 做源地址伪装
  ipt_ensure -t nat POSTROUTING -o "$TUN" -j MASQUERADE
}

# 确保策略路由规则在（幂等）
ensure_ip_rules() {
  ip rule | grep -q "from all iif $DEV lookup $TABLE_ID" \
    || ip rule add from all iif "$DEV" table "$TABLE_ID" pref $((PREF-1)) 2>/dev/null || true
  ip rule | grep -q "from all lookup main" \
    || ip rule add from all table main pref "$PREF" 2>/dev/null || true
}

# 写入/维持 table 200 的默认路由（仅当 TUN 已 up）
ensure_table_default() {
  if ip -br link show "$TUN" 2>/dev/null | grep -q "UP"; then
    ip -4 route replace default dev "$TUN" table "$TABLE_ID" 2>/dev/null || true
  fi
}

# 开启 IPv4 转发
enable_forwarding() {
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
}

# 初始阶段：尝试等待 TUN 就绪（最多 10 秒）
wait_tun_up() {
  for _ in $(seq 1 10); do
    if ip -br link show "$TUN" 2>/dev/null | grep -q "UP"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ============ 初始化 ============ #
enable_forwarding
ensure_ip_rules
ensure_fw_nat
wait_tun_up && ensure_table_default

log "INIT done: DEV=$DEV  TUN=$TUN  TABLE=$TABLE_ID"

# ============ 守护巡检 ============ #
contain="from all iif $DEV lookup $TABLE_ID"

while :; do
  # 1) 若 TUN 刚重建/UP，补默认路由
  ensure_table_default

  # 2) 若策略路由被其他进程改动，补回
  if ! ip rule | grep -q "$contain"; then
    if ip -br link show "$DEV" 2>/dev/null | grep -q "UP"; then
      ip rule add from all iif "$DEV" table "$TABLE_ID" pref $((PREF-1)) 2>/dev/null || true
      log "network changed, reset the routing policy."
    else
      log "$DEV is down."
    fi
  fi

  # 3) 允许转发/NAT 可能被清空，定期补强
  ensure_fw_nat

  sleep "$INTERVAL"
done
