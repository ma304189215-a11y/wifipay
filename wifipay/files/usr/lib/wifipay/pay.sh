#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh
. /usr/lib/wifipay/plan.sh

ORD=$WP_D/orders
WX=$WP_D/wx
touch $ORD

wx_ready() { [ -f $WX/apiclient_key.pem ] && [ -n "$(cfg wx_mchid)" ] && [ -n "$(cfg wx_appid)" ] && [ -n "$(cfg wx_serial)" ] && command -v curl >/dev/null; }

wx_auth() {   # 方法 路径 请求体
	m=$1; p=$2; b=$3
	ts=$(date +%s)
	nonce=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
	f=/tmp/wx.sign.$$
	printf '%s\n%s\n%s\n%s\n%s\n' "$m" "$p" "$ts" "$nonce" "$b" > $f
	sig=$(openssl dgst -sha256 -sign $WX/apiclient_key.pem -binary $f 2>/dev/null | base64 | tr -d '\n')
	rm -f $f
	[ -n "$sig" ] || return 1
	printf 'WECHATPAY2-SHA256-RSA2048 mchid="%s",nonce_str="%s",signature="%s",timestamp="%s",serial_no="%s"' \
		"$(cfg wx_mchid)" "$nonce" "$sig" "$ts" "$(cfg wx_serial)"
}

wx_native() {  # 订单号 金额分 描述
	body=$(printf '{"appid":"%s","mchid":"%s","description":"%s","out_trade_no":"%s","amount":{"total":%s,"currency":"CNY"}}' \
		"$(cfg wx_appid)" "$(cfg wx_mchid)" "$3" "$1" "$2")
	auth=$(wx_auth POST /v3/pay/transactions/native "$body") || return 1
	curl -sS --max-time 10 -X POST 'https://api.mch.weixin.qq.com/v3/pay/transactions/native' \
		-H "Authorization: $auth" -H 'Accept: application/json' \
		-H 'Content-Type: application/json' --data-binary "$body"
}

wx_query() {   # 订单号
	path="/v3/pay/transactions/out-trade-no/$1?mchid=$(cfg wx_mchid)"
	auth=$(wx_auth GET "$path" "") || return 1
	curl -sS --max-time 10 "https://api.mch.weixin.qq.com$path" \
		-H "Authorization: $auth" -H 'Accept: application/json'
}

order_create() {   # 套餐 mac ip
	plan=$1; mac=$2; ip=$3
	sec_id "$plan" || { echo '{"ok":false,"msg":"套餐不存在"}'; exit 0; }
	title=$(uci -q get wifipay.$plan.title)
	price=$(jnum "$(uci -q get wifipay.$plan.price)" 0)
	min=$(jnum "$(uci -q get wifipay.$plan.minutes)" 0)
	[ -n "$title" ] || { echo '{"ok":false,"msg":"套餐不存在"}'; exit 0; }
	mode=$(cfg pay_mode)
	[ "$mode" = "off" ] && { echo '{"ok":false,"msg":"暂未开放购买"}'; exit 0; }

	pending=$(awk -F"$TAB" -v m="$mac" '$5==m && $7=="pending"' $ORD 2>/dev/null | wc -l)
	[ "$pending" -ge 2 ] && { echo '{"ok":false,"msg":"你有未支付订单"}'; exit 0; }
	total=$(awk -F"$TAB" '$7=="pending"' $ORD 2>/dev/null | wc -l)
	[ "$total" -ge 300 ] && { echo '{"ok":false,"msg":"下单繁忙，请稍后再试"}'; exit 0; }

	hf=$WP_RUN/orderhour/$(printf '%s' "$ip" | tr . _)
	mkdir -p $WP_RUN/orderhour
	hn=$(( $(cat "$hf" 2>/dev/null || echo 0) + 1 ))
	echo $hn > "$hf"
	[ "$hn" -le 5 ] || { echo '{"ok":false,"msg":"下单过于频繁"}'; exit 0; }

	id=$(date +%Y%m%d)$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 6)
	wp_lock
	printf '%s\t%s\t%s\t%s\t%s\t%s\tpending\t%s\t\n' "$id" "$plan" "$price" "$min" "$mac" "$ip" "$(date +%s)" >> $ORD
	wp_unlock
	chmod 600 $ORD

	case "$mode" in
	wxpay)
		wx_ready || { echo '{"ok":false,"msg":"微信支付未配置"}'; exit 0; }
		resp=$(wx_native "$id" $((price * 100)) "$title")
		cu=$(printf '%s' "$resp" | jsonfilter -e '@.code_url' 2>/dev/null)
		if [ -z "$cu" ]; then
			log "wx native failed: $(printf '%s' "$resp" | head -c 200)"
			echo '{"ok":false,"msg":"下单失败，请稍后再试"}'
			exit 0
		fi
		qr=""
		if command -v qrencode >/dev/null 2>&1; then
			mkdir -p /www/wifipay/qr
			qrencode -o "/www/wifipay/qr/$id.png" -s 6 -m 2 "$cu" 2>/dev/null && qr="/wifipay/qr/$id.png"
		fi
		printf '{"ok":true,"mode":"wxpay","order":"%s","price":%s,"title":"%s","qr":"%s","code_url":"%s"}\n' \
			"$id" "$price" "$title" "$qr" "$cu"
		;;
	*)
		qr=$(cfg pay_qr); [ -n "$qr" ] || qr=/wifipay/pay_qr.png
		printf '{"ok":true,"mode":"manual","order":"%s","price":%s,"title":"%s","qr":"%s"}\n' \
			"$id" "$price" "$title" "$qr"
		;;
	esac
}

order_claim() {
	id=$1; sec_oid "$id" || { echo '{"ok":false}'; exit 0; }
	wp_lock
	st=$(awk -F"$TAB" -v i="$id" '$1==i{print $7}' $ORD)
	case "$st" in
		pending)
			awk -F"$TAB" -v i="$id" 'BEGIN{OFS="\t"} $1==i{$7="claimed"} {print}' $ORD > $ORD.tmp && mv $ORD.tmp $ORD
			wp_unlock; echo '{"ok":true,"msg":"已通知店主，确认后自动开通"}' ;;
		claimed) wp_unlock; echo '{"ok":true,"msg":"已提交，请稍候"}' ;;
		"")      wp_unlock; echo '{"ok":false,"msg":"订单不存在"}' ;;
		*)       wp_unlock; echo '{"ok":true,"msg":"已处理"}' ;;
	esac
}

order_poll() {
	id=$1; sec_oid "$id" || { echo '{"ok":false}'; exit 0; }
	st=$(awk -F"$TAB" -v i="$id" '$1==i{print $7}' $ORD)
	[ "$st" = "granted" ] && { echo '{"ok":true,"state":"granted"}'; exit 0; }
	[ -n "$st" ] || { echo '{"ok":false,"state":"none"}'; exit 0; }
	wx_ready || { echo '{"ok":false,"state":"noconf"}'; exit 0; }

	resp=$(wx_query "$id")
	ts=$(printf '%s' "$resp" | jsonfilter -e '@.trade_state' 2>/dev/null)
	total=$(printf '%s' "$resp" | jsonfilter -e '@.amount.total' 2>/dev/null)

	if [ "$ts" = "SUCCESS" ]; then
		price=$(awk -F"$TAB" -v i="$id" '$1==i{print $3}' $ORD)
		if [ "$total" != "$(( ${price:-0} * 100 ))" ]; then
			log "金额不符 order=$id total=$total"
			echo '{"ok":false,"state":"amount_mismatch"}'
			exit 0
		fi
		order_confirm "$id" >/dev/null
		echo '{"ok":true,"state":"granted"}'
	else
		printf '{"ok":true,"state":"%s"}\n' "${ts:-NOTPAY}"
	fi
}

order_confirm() {
	id=$1; sec_oid "$id" || { echo '{"ok":false}'; exit 0; }
	wp_lock
	line=$(awk -F"$TAB" -v i="$id" '$1==i' $ORD)
	[ -n "$line" ] || { wp_unlock; echo '{"ok":false,"msg":"订单不存在"}'; exit 0; }
	st=$(printf '%s' "$line" | cut -f7)
	mac=$(printf '%s' "$line" | cut -f5)
	min=$(printf '%s' "$line" | cut -f4)
	if [ "$st" = "granted" ]; then wp_unlock; echo '{"ok":true,"msg":"已开通，勿重复确认"}'; exit 0; fi
	awk -F"$TAB" -v i="$id" -v t="$(date '+%F %T')" 'BEGIN{OFS="\t"} $1==i{$7="granted";$9=t} {print}' \
		$ORD > $ORD.tmp && mv $ORD.tmp $ORD
	_allow_nolock "$mac" "$min" "订单$id"
	wp_unlock
	[ "$(cfg enabled)" = "1" ] && sync_allowed
	log "order granted $id mac=$mac min=$min"
	echo '{"ok":true}'
}

order_revoke() {
	id=$1; sec_oid "$id" || { echo '{"ok":false}'; exit 0; }
	mac=$(awk -F"$TAB" -v i="$id" '$1==i{print $5}' $ORD)
	[ -n "$mac" ] || { echo '{"ok":false,"msg":"订单不存在"}'; exit 0; }
	wp_lock
	awk -F"$TAB" -v i="$id" 'BEGIN{OFS="\t"} $1==i{$7="revoked"} {print}' $ORD > $ORD.tmp && mv $ORD.tmp $ORD
	wp_unlock
	plan_revoke "$mac" >/dev/null
	echo '{"ok":true}'
}

order_list() {
	printf '['; first=1
	[ -f $ORD ] && while IFS=$TAB read -r id plan price min mac ip st ts note; do
		[ -n "$id" ] || continue
		printf '%s{"id":"%s","plan":"%s","price":%s,"minutes":%s,"mac":"%s","state":"%s","ts":%s,"note":"%s"}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$id" "$plan" "$(jnum "$price" 0)" \
			"$(jnum "$min" 0)" "$mac" "$st" "$(jnum "$ts" 0)" "$note"
		first=0
	done < $ORD
	printf ']\n'
}

order_stats() {
	awk -F"$TAB" '$7=="granted"{n++; s+=$3} END{ printf "{\"count\":%d,\"amount\":%d}\n", n+0, s+0 }' $ORD 2>/dev/null || echo '{"count":0,"amount":0}'
}

order_gc() {
	now=$(date +%s)
	awk -F"$TAB" -v now="$now" 'BEGIN{OFS="\t"}
		$7=="pending" && now-$8>1800 {$7="expired"} {print}' $ORD > $ORD.tmp 2>/dev/null && mv $ORD.tmp $ORD
	tail -n 2000 $ORD > $ORD.tmp 2>/dev/null && mv $ORD.tmp $ORD
}

pay_cmd() {
	case "$1" in
		create)  order_create "$2" "$3" "$4" ;;
		claim)   order_claim "$2" ;;
		poll)    order_poll "$2" ;;
		confirm) order_confirm "$2" ;;
		revoke)  order_revoke "$2" ;;
		list)    order_list ;;
		stats)   order_stats ;;
	esac
}
