#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh

ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
bad()  { echo "[BAD]  $*"; }

do_doctor() {
	mode=$(cfg detected_mode); lip=$(cfg lan_ip); guest=$(cfg guest_net)
	port=$(cfg portal_port)
	lan_if=$(cfg lan_if)

	echo "===== 模式 ====="
	case "$mode" in
		bypass)  warn "旁路由：客户端网关必须为 $lip，否则流量不经过本机，拦截无效" ;;
		gateway) ok "主路由：流量必经本机" ;;
		*)       bad "无法判断模式，请在设置里手动指定" ;;
	esac
	echo "LAN  接口   $lan_if"
	echo "LAN  IP     $lip"
	echo "客人网段    $guest"
	echo "portal      $lip:$port"

	echo "===== DNS 与端口 ====="
	[ "$(cfg dns_hijack)" = "1" ] && ok "DNS 劫持已开" || warn "DNS 劫持关闭，客户端手填 DNS 可绕过"
	[ "$(cfg ipv6_block)" = "1" ] && ok "IPv6 已封堵" || warn "IPv6 未封堵，计费可被绕过"

	echo "===== nft ====="
	if nft list table inet wifipay >/dev/null 2>&1; then
		ok "规则表已加载"
		n=$(nft list set inet wifipay allowed 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | wc -l)
		echo "已放行设备  $n 台"
		nft list chain inet wifipay wp_fwd 2>/dev/null | grep -q counter && ok "防共享计数已启用"
	else
		warn "规则未加载（拦截未启用或启动失败）"
	fi

	[ -f $WP_RUN/panic ] && bad "PANIC 生效中，全部放行"
	[ -f $WP_RUN/fuse ] && warn "熔断生效中，portal 限速"

	echo "===== 限速能力 ====="
	if command -v tc >/dev/null 2>&1; then
		if ip link show ifb-wifipay >/dev/null 2>&1; then
			ok "限速可用（tc + ifb）"
		else
			warn "有 tc 但缺 ifb，上行限速不生效"
		fi
	else
		warn "没有 tc，完全不做限速"
	fi

	echo "===== 时间 ====="
	y=$(date +%Y)
	if [ "$y" -ge 2024 ]; then ok "系统时间正常（$(date '+%F %T')）"; else bad "系统时间异常，租期会算错"; fi

	echo "===== 依赖 ====="
	for c in nft uci jsonfilter; do
		command -v $c >/dev/null 2>&1 && ok "$c" || warn "缺 $c"
	done
	command -v curl >/dev/null 2>&1 && ok "curl（微信支付需要）" || warn "缺 curl，微信支付不可用"
	command -v qrencode >/dev/null 2>&1 && ok "qrencode" || warn "缺 qrencode，微信二维码不生成"
}
