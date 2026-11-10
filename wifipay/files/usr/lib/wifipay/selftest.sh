#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh

P=0; F=0
ck() {
	if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; P=$((P + 1))
	else echo "FAIL  $1"; F=$((F + 1)); fi
}
cklog() {
	if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"
	else echo "WARN  $1"; fi
}

do_selftest() {
	echo "===== 基础 ====="
	ck "配置文件存在"     "[ -f /etc/config/wifipay ]"
	ck "主命令可执行"     "[ -x /usr/sbin/wifipay ]"
	ck "cgi 可执行"       "[ -x /www/cgi-bin/wifipay ]"
	ck "portal 首页存在"  "[ -f /www/wifipay/index.html ]"
	ck "管理台页面存在"   "[ -f /www/luci-static/resources/view/wifipay/overview.js ]"
	ck "白名单非空"       "[ -s \$WP_D/trusted ]"

	echo "===== 环境 ====="
	ck "nft 可用"         "command -v nft"
	ck "tc 可用"          "command -v tc"
	cklog "ifb 可用"      "modprobe ifb && [ -d /sys/class/net/ifb-wifipay ]"
	ck "系统时间正常"     "[ \$(date +%Y) -ge 2024 ]"
	ck "overlay 有余量"   "[ \$(df -k /overlay 2>/dev/null | awk 'NR==2{print \$4}') -gt 2048 ]"

	echo "===== nft 规则 ====="
	if [ "$(cfg enabled)" = "1" ]; then
		ck "规则表存在"       "nft list table inet wifipay"
		ck "放行集是配对类型"  "nft list set inet wifipay allowed | grep -q 'ipv4_addr . ether_addr'"
		ck "宽限集存在"       "nft list set inet wifipay grace"
		ck "封禁集存在"       "nft list set inet wifipay banned"
		ck "IPv6 已封堵"      "nft list chain inet wifipay wp_fwd | grep -q 'nfproto ipv6 drop'"
		ck "DNS 重定向在"     "nft list chain inet wifipay wp_dns | grep -q 'redirect to :53'"
	else
		echo "SKIP  拦截未启用"
	fi

	echo "===== cgi 动作白名单 ====="
	for a in whoami status plans trial redeem ads adsq hit order claim orderstatus bind; do
		ck "act $a" "sec_act $a"
	done

	echo "===== 权限 ====="
	ck "码表 600"        "[ \"\$(ls -l \$WP_D/codes 2>/dev/null | cut -c1-10)\" = '-rw-------' ]"
	ck "www 下无脚本"    "! find /www/wifipay -name '*.sh' 2>/dev/null | grep -q ."

	echo "===== 输入校验 ====="
	ck "码格式校验"      "! sec_code 'abc'"
	ck "MAC 格式校验"    "! sec_mac 'zz:zz'"
	ck "IP 格式校验"     "! sec_ip '1.2.3'"

	echo
	if [ "$F" -eq 0 ]; then
		echo "===== 全部通过（$P 项）====="
	else
		echo "===== $P 通过 / $F 失败 ====="
	fi
	[ "$F" -eq 0 ]
}

do_manifest() {
	mkdir -p $WP_D
	: > /etc/wifipay/manifest.new
	for f in /usr/sbin/wifipay /etc/init.d/wifipay /www/cgi-bin/wifipay \
	         /usr/lib/wifipay/* /www/wifipay/*.html \
	         /www/luci-static/resources/view/wifipay/*.js \
	         /usr/share/luci/menu.d/luci-app-wifipay.json \
	         /usr/share/rpcd/acl.d/luci-app-wifipay.json; do
		[ -f "$f" ] && printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f" >> /etc/wifipay/manifest.new
	done
	mv /etc/wifipay/manifest.new /etc/wifipay/manifest
	chmod 600 /etc/wifipay/manifest
	echo "manifest: $(wc -l < /etc/wifipay/manifest) 个文件"
}

do_verify() {
	M=/etc/wifipay/manifest
	[ -f "$M" ] || { echo "没有 manifest，先执行 wifipay manifest"; return 1; }
	bad=0; n=0
	while read -r sum path; do
		[ -n "$path" ] || continue
		n=$((n + 1))
		if [ ! -f "$path" ]; then echo "缺失  $path"; bad=$((bad + 1)); continue; fi
		[ "$(sha256sum "$path" | cut -d' ' -f1)" = "$sum" ] || { echo "被改  $path"; bad=$((bad + 1)); }
	done < "$M"
	if [ "$bad" -eq 0 ]; then
		echo "全部通过（$n 个文件）"
	else
		echo "$bad / $n 个文件异常"
	fi
	[ "$bad" -eq 0 ]
}
