#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh

net_down() {
	nft delete table inet wifipay 2>/dev/null
	log "rules removed"
}

net_up() {
	lan_if=$(cfg lan_if); lip=$(cfg lan_ip); port=$(cfg portal_port)
	[ -n "$lan_if" ] && [ -n "$lip" ] && [ -n "$port" ] || { log "配置不完整，跳过"; return 1; }

	share_rule=''
	if [ "$(cfg share_enable)" = "1" ]; then
		_smax=$(jnum "$(cfg share_max_conn)" 150)
		case "$(cfg share_action)" in
			log) share_rule="ip saddr . ether saddr @allowed ct state new update @wifipay_share { ip saddr timeout 1m limit rate over ${_smax}/second burst 5 packets } counter" ;;
			*)   share_rule="ip saddr . ether saddr @allowed ct state new update @wifipay_share { ip saddr timeout 1m limit rate over ${_smax}/second burst 5 packets } counter limit rate 3/minute burst 5 packets log prefix \"wifipay-share \" drop" ;;
		esac
	fi

	v6_rule=''
	[ "$(cfg ipv6_block)" = "1" ] && v6_rule="meta nfproto ipv6 drop"

	portal_rule="ip saddr . ether saddr != @allowed tcp dport 80 redirect to :$port"
	if [ "$(cfg deploy_mode)" = "split" ]; then
		_bu=$(cfg backend_url); _bk=$(cfg backend_key)
		if [ -n "$_bu" ]; then
			_bh=$(printf '%s' "$_bu" | sed 's|^https\?://||; s|/.*||; s|:.*||')
			_bp=$(printf '%s' "$_bu" | sed 's|.*:||')
			case "$_bp" in ''|*[!0-9]*) _bp=9000 ;; esac
			[ -n "$_bh" ] && portal_rule="ip saddr . ether saddr != @allowed tcp dport 80 dnat to $_bh:$_bp"
		fi
	fi

	net_down
	nft -f - <<-EOF
	table inet wifipay {
		set allowed { type ipv4_addr . ether_addr; flags timeout; }
		set trusted { type ether_addr; }
		set grace   { type ipv4_addr . ether_addr; flags timeout; }
		set banned  { type ipv4_addr; flags timeout; }
		set wifipay_portal { type ipv4_addr; size 65535; flags dynamic,timeout; }
		set wifipay_share  { type ipv4_addr; size 65535; flags dynamic,timeout; }

		chain wp_in {
			type filter hook input priority filter - 10; policy accept;
			iifname != "$lan_if" return
			ip saddr @banned drop
			ether saddr @trusted return
			ct state established,related accept
			tcp dport 22 accept
			ct state new tcp dport $port update @wifipay_portal { ip saddr timeout 1m limit rate over 100/second burst 5 packets } drop
			tcp dport $port accept
			udp dport 53 accept
			tcp dport 53 accept
			udp dport 67 accept
			drop
		}

		chain wp_fwd {
			type filter hook forward priority filter - 10; policy accept;
			iifname != "$lan_if" return
			ether saddr @trusted accept
			ip saddr . ether saddr @grace accept
			$share_rule
			ip saddr . ether saddr @allowed accept
			udp dport { 853, 5353 } drop
			tcp dport 853 drop
			$v6_rule
			drop
		}

		chain wp_dns {
			type nat hook prerouting priority dstnat - 10; policy accept;
			iifname != "$lan_if" return
			ether saddr @trusted return
			udp dport 53 redirect to :53
			tcp dport 53 redirect to :53
			$portal_rule
		}
	}
	EOF

	[ "$(cfg dns_hijack)" = "1" ] || nft flush chain inet wifipay wp_dns 2>/dev/null
	sync_allowed
	sync_trusted
	sync_grace
	log "规则加载完成 portal=$lip:$port"
}

sync_allowed() {
	nft flush set inet wifipay allowed 2>/dev/null
	now=$(date +%s)
	[ -f $WP_D/allowed ] || return 0
	while IFS=$TAB read -r mac exp note state; do
		[ -n "$mac" ] || continue
		[ "$exp" -gt "$now" ] 2>/dev/null || continue
		[ "$state" = "grace" ] && continue
		ip=$(mac2ip "$mac")
		[ -n "$ip" ] || continue
		nft add element inet wifipay allowed "{ $ip . $mac timeout $((exp - now))s }" 2>/dev/null
	done < $WP_D/allowed
}

sync_trusted() {
	nft flush set inet wifipay trusted 2>/dev/null
	[ -f $WP_D/trusted ] || return 0
	while read -r mac; do
		[ -n "$mac" ] && nft add element inet wifipay trusted "{ $mac }" 2>/dev/null
	done < $WP_D/trusted
}

sync_grace() {
	nft flush set inet wifipay grace 2>/dev/null
	now=$(date +%s)
	g=$(( $(jnum "$(cfg grace_days)" 0) * 86400 ))
	[ "$g" -gt 0 ] || return 0
	[ -f $WP_D/allowed ] || return 0
	while IFS=$TAB read -r mac exp note state; do
		[ "$state" = "grace" ] || continue
		ip=$(mac2ip "$mac")
		[ -n "$ip" ] || continue
		left=$((exp + g - now))
		[ "$left" -gt 0 ] || continue
		nft add element inet wifipay grace "{ $ip . $mac timeout ${left}s }" 2>/dev/null
	done < $WP_D/allowed
}

trust_add() {
	wp_lock
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	sec_mac "$mac" || { wp_unlock; echo '{"ok":false,"msg":"MAC 格式不对"}'; return 1; }
	grep -qx "$mac" $WP_D/trusted 2>/dev/null || echo "$mac" >> $WP_D/trusted
	wp_unlock
	sync_trusted
	echo '{"ok":true}'
}

trust_del() {
	wp_lock
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	awk -v m="$mac" '$1!=m' $WP_D/trusted > $WP_D/trusted.tmp 2>/dev/null
	mv $WP_D/trusted.tmp $WP_D/trusted
	wp_unlock
	sync_trusted
	echo '{"ok":true}'
}

trust_online() {
	wp_lock
	ip neigh 2>/dev/null | awk '$4=="lladdr"{print $5}' | sort -u >> $WP_D/trusted
	sort -u $WP_D/trusted -o $WP_D/trusted
	wp_unlock
	sync_trusted
	log "在线设备已全部加白"
	echo '{"ok":true}'
}

rate_init() {
	dev=$(cfg lan_if); ifb=ifb-wifipay
	modprobe ifb 2>/dev/null
	ip link show $ifb >/dev/null 2>&1 || ip link add $ifb type ifb 2>/dev/null
	ip link set $ifb up 2>/dev/null

	tc qdisc show dev $dev 2>/dev/null | grep -q 'ingress ffff:' || \
		tc qdisc add dev $dev handle ffff: ingress
	tc filter show dev $dev parent ffff: 2>/dev/null | grep -q mirred || \
		tc filter add dev $dev parent ffff: protocol ip u32 match u32 0 0 \
			action mirred egress redirect dev $ifb 2>/dev/null

	tc qdisc replace dev $ifb root handle 1: htb default 9999 2>/dev/null
	tc qdisc replace dev $dev root handle 1: htb default 9999 2>/dev/null
	tc class replace dev $ifb parent 1: classid 1:9999 htb rate 1000mbit ceil 1000mbit 2>/dev/null
	tc class replace dev $dev parent 1: classid 1:9999 htb rate 1000mbit ceil 1000mbit 2>/dev/null
}

rate_sync() {
	[ "$(jnum "$(cfg rate_down)" 0)" -gt 0 ] || { rate_off; return 0; }
	command -v tc >/dev/null 2>&1 || { log "没有 tc，跳过限速"; return 0; }
	modprobe ifb 2>/dev/null
	ip link show ifb-wifipay >/dev/null 2>&1 || log "没有 ifb 接口，上行限速可能不可用"

	rate_init
	dev=$(cfg lan_if); ifb=ifb-wifipay
	now=$(date +%s)
	cur=$WP_RUN/rate.cur; new=$WP_RUN/rate.new
	: > $new

	tc filter del dev $ifb parent 1: 2>/dev/null
	tc filter del dev $dev parent 1: 2>/dev/null

	while IFS=$TAB read -r mac exp note state; do
		[ -n "$mac" ] || continue
		keep=0
		[ "$exp" -gt "$now" ] 2>/dev/null && keep=1
		[ "$state" = "grace" ] && keep=1
		[ "$keep" = "1" ] || continue

		ip=$(mac2ip "$mac")
		[ -n "$ip" ] || continue
		sec_ip "$ip" || continue
		last=$(printf '%s' "$ip" | cut -d. -f4)
		case "$last" in ''|*[!0-9]*) continue ;; esac
		{ [ "$last" -ge 1 ] && [ "$last" -le 254 ]; } || continue
		cid=$((last + 100))

		rd=$(jnum "$(cfg rate_down)" 10240); ru=$(jnum "$(cfg rate_up)" 10240)
		if [ "$note" = "trial" ]; then
			rd=$(jnum "$(cfg trial_rate)" 3072); ru=$rd
		elif [ "$state" = "grace" ]; then
			rd=$(jnum "$(cfg grace_rate)" 1024); ru=$rd
		fi

		tc class replace dev $dev parent 1: classid 1:$cid htb rate ${rd}kbit ceil ${rd}kbit 2>/dev/null
		tc filter add dev $dev parent 1: protocol ip u32 match ip dst $ip/32 flowid 1:$cid 2>/dev/null
		tc class replace dev $ifb parent 1: classid 1:$cid htb rate ${ru}kbit ceil ${ru}kbit 2>/dev/null
		tc filter add dev $ifb parent 1: protocol ip u32 match ip src $ip/32 flowid 1:$cid 2>/dev/null

		printf '%s %s\n' "$ip" "$cid" >> $new
	done < $WP_D/allowed

	if [ -f $cur ]; then
		while read -r ip cid; do
			[ -n "$cid" ] || continue
			grep -q " $cid\$" $new && continue
			tc class del dev $ifb parent 1: classid 1:$cid 2>/dev/null
			tc class del dev $dev parent 1: classid 1:$cid 2>/dev/null
		done < $cur
	fi
	mv $new $cur
}

rate_off() {
	dev=$(cfg lan_if)
	tc qdisc del dev $dev root 2>/dev/null
	tc qdisc del dev $dev handle ffff: ingress 2>/dev/null
	tc qdisc del dev ifb-wifipay root 2>/dev/null
	rm -f $WP_RUN/rate.cur
}

panic_on() {
	min=${1:-10}
	net_down
	rate_off
	echo "$min" > $WP_RUN/panic
	log "PANIC: 全部放行 ${min} 分钟"
	(
		sleep $((min * 60))
		if [ -f $WP_RUN/panic ]; then
			rm -f $WP_RUN/panic
			if [ "$(cfg enabled)" = "1" ]; then
				net_up
				sync_grace
				rate_sync
			fi
			log "PANIC 解除"
		fi
	) >/dev/null 2>&1 &
}

panic_off() {
	rm -f $WP_RUN/panic
	if [ "$(cfg enabled)" = "1" ]; then
		net_up
		sync_grace
		rate_sync
	fi
	log "PANIC 手动解除"
}
