#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh
. /usr/lib/wifipay/net.sh
. /usr/lib/wifipay/plan.sh
. /usr/lib/wifipay/pay.sh
. /usr/lib/wifipay/ad.sh
. /usr/lib/wifipay/room.sh

fuse_check() {
	[ "$(cfg fuse_enable)" = "1" ] || return 0
	port=$(cfg portal_port)
	n=$(grep -c "dport=$port " /proc/net/nf_conntrack 2>/dev/null)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	[ "$n" -gt "$(jnum "$(cfg fuse_conns)" 150)" ] || return 0
	nft list chain inet wifipay wp_in 2>/dev/null | grep -q wifipay-fuse && return 0
	nft insert rule inet wifipay wp_in \
		ether saddr != @trusted tcp dport $port ct state new \
		limit rate over 5/second counter drop comment "wifipay-fuse" 2>/dev/null
	echo "$(date +%s)" > $WP_RUN/fuse
	log "熔断：portal 并发 $n"
}

fuse_release() {
	[ -f $WP_RUN/fuse ] || return 0
	port=$(cfg portal_port); limit=$(jnum "$(cfg fuse_conns)" 150)
	n=$(grep -c "dport=$port " /proc/net/nf_conntrack 2>/dev/null)
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	[ "$n" -ge $((limit / 2)) ] && { date +%s > $WP_RUN/fuse; return 0; }
	[ $(( $(date +%s) - $(cat $WP_RUN/fuse) )) -gt 120 ] || return 0
	for h in $(nft -a list chain inet wifipay wp_in 2>/dev/null | awk '/wifipay-fuse/{print $NF}'); do
		nft delete rule inet wifipay wp_in handle $h 2>/dev/null
	done
	rm -f $WP_RUN/fuse
	log "熔断解除"
}

gc_net() {
	_lan=$(cfg lan_if)
	for _ip in $(ip neigh show dev "$_lan" 2>/dev/null | awk '$NF=="FAILED"||$NF=="INCOMPLETE"{print $1}'); do
		ip neigh del "$_ip" dev "$_lan" 2>/dev/null
	done
	cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
	max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
	case "$cur$max" in ''|*[!0-9]*) return 0 ;; esac
	[ "$max" -gt 0 ] || return 0
	pct=$((cur * 100 / max))
	if [ "$pct" -ge 80 ]; then
		echo 1800 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null
		if [ ! -f $WP_RUN/ctgc ]; then
			date +%s > $WP_RUN/ctgc
			log "连接表 $cur/$max 偏高，已缩短超时"
		fi
	elif [ "$pct" -lt 50 ]; then
		rm -f $WP_RUN/ctgc 2>/dev/null
	fi
	n=$(nft list set inet wifipay wifipay_portal 2>/dev/null | grep -c "expires")
	[ "${n:-0}" -gt 2000 ] && nft flush set inet wifipay wifipay_portal 2>/dev/null
}

portal_wd() {
	[ "$(cfg enabled)" = "1" ] || return 0
	[ -f $WP_RUN/panic ] && return 0
	[ "$(cfg wd_enable 2>/dev/null)" = "0" ] && return 0
	local port pf n
	port=$(cfg portal_port)
	pf=$WP_RUN/pfail
	if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null; then
		rm -f $pf 2>/dev/null
		return 0
	fi
	n=$(cat $pf 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
	n=$((n + 1))
	echo $n > $pf
	if [ "$n" -ge 3 ]; then
		log "看门狗：portal 连续 ${n} 次无响应，自动放行 30 分钟"
		panic_on 30
		rm -f $pf 2>/dev/null
	fi
}

sync_backend() {
	[ "$(cfg deploy_mode)" = "split" ] || return 0
	url=$(cfg backend_url); key=$(cfg backend_key)
	[ -n "$url" ] || return 0
	itv=$(jnum "$(cfg sync_interval)" 60); [ "$itv" -lt 10 ] && itv=10
	last=$(cat $WP_RUN/bsync 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
	now=$(date +%s)
	[ $((now - last)) -ge "$itv" ] || return 0
	resp=$(curl -s --max-time 8 -H "X-WP-Key: $key" "${url%/}/api/sync" 2>/dev/null)
	case "$resp" in
		'#WIFIPAY-SYNC-1'*) ;;
		*) [ -f $WP_RUN/bdown ] || { log "后端同步失败"; : > $WP_RUN/bdown; }; return 1 ;;
	esac
	rm -f $WP_RUN/bdown 2>/dev/null
	printf '%s\n' "$resp" | tail -n +2 | grep -E '^[0-9a-f]{2}:' > $WP_D/allowed.tmp 2>/dev/null
	mv $WP_D/allowed.tmp $WP_D/allowed
	chmod 600 $WP_D/allowed 2>/dev/null
	echo "$now" > $WP_RUN/bsync
	sync_allowed
}

day_clean() {
	find $WP_RUN/day  -type f ! -name "$(date +%Y%m%d).*" -delete 2>/dev/null
	find $WP_RUN/rl   -type f -mmin +10 -delete 2>/dev/null
	find $WP_RUN/adsh -type f ! -name "$(date +%Y%m%d).*" -delete 2>/dev/null
	find $WP_RUN/orderhour -type f -mmin +60 -delete 2>/dev/null
}

tick=0
while true; do
	sleep 60
	tick=$((tick + 1))

	# 数据维护：不管开没开拦截都跑
	plan_gc
	order_gc
	rooms_gc
	sync_backend
	portal_wd
	[ $((tick % 5)) -eq 0 ] && gc_net
	[ $((tick % 60)) -eq 0 ] && day_clean

	# 网络动作：按条件跳过
	[ -f $WP_RUN/panic ] && continue
	[ "$(cfg enabled)" = "1" ] || continue

	nft list table inet wifipay >/dev/null 2>&1 || net_up
	sync_allowed
	sync_trusted
	sync_grace
	rate_sync
	fuse_check
	fuse_release
done
