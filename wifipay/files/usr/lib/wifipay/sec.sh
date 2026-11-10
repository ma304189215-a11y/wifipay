#!/bin/sh
[ -n "${WP_RUN:-}" ] || . /usr/lib/wifipay/env.sh

# ---- 输入校验：所有不可信输入必须过这里 ----
sec_act()  { case "$1" in whoami|status|plans|trial|redeem|ads|adsq|hit|order|claim|orderstatus|bind) return 0 ;; *) return 1 ;; esac; }
sec_mac()  { printf '%s' "$1" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
sec_code() { printf '%s' "$1" | grep -qE '^[A-Z0-9]{8,12}$'; }
sec_rcode(){ printf '%s' "$1" | grep -qE '^[A-Z0-9]{1,12}-[A-Z0-9]{4}$'; }
sec_id()   { printf '%s' "$1" | grep -qE '^[a-z0-9]{1,32}$'; }
sec_oid()  { printf '%s' "$1" | grep -qE '^[A-Z0-9]{8,24}$'; }
sec_ip()   { printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }
sec_mask() { printf '%s****' "$(printf '%s' "$1" | cut -c1-2)"; }

sec_in_net() {
	ip=$1; net=$2; pref=${net%/*}; bits=${net#*/}
	[ "$bits" = "$net" ] && bits=32
	case "$bits" in
		24) [ "${ip%.*}" = "${pref%.*}" ] ;;
		16) [ "$(printf '%s' "$ip" | cut -d. -f1-2)" = "$(printf '%s' "$pref" | cut -d. -f1-2)" ] ;;
		8)  [ "${ip%%.*}" = "${pref%%.*}" ] ;;
		*)  [ "$ip" = "$pref" ] ;;
esac
}

# ---- 限流 ----
sec_rate_act() {
	ip=$1; act=$2
	case "$act" in
		whoami|status|plans|ads|adsq) max=60 ;;
		orderstatus)                 max=25 ;;
		redeem|trial|bind)           max=6  ;;
		order|claim)                 max=4  ;;
		*)                           max=20 ;;
esac
	mkdir -p $WP_RUN/rl 2>/dev/null
	f=$WP_RUN/rl/$(printf '%s' "$ip" | tr . _).$act.$(date +%M)
	n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$f"
	[ "$(ls $WP_RUN/rl 2>/dev/null | wc -l)" -gt 400 ] && rm -f $WP_RUN/rl/*
	[ "$n" -le "$max" ]
}

sec_day() {
	cap=$(jnum "$(cfg day_quota)" 500)
	mkdir -p $WP_RUN/day
	d=$WP_RUN/day/$(date +%Y%m%d).$(printf '%s' "$1" | tr . _)
	n=$(( $(cat "$d" 2>/dev/null || echo 0) + 1 ))
	echo $n > "$d"
	if [ "$n" -gt "$cap" ]; then
		echo "$(date +%s)" > $WP_RUN/ban/$1 2>/dev/null || { mkdir -p $WP_RUN/ban; echo "$(date +%s)" > $WP_RUN/ban/$1; }
		nft add element inet wifipay banned "{ $1 timeout 3600s }" 2>/dev/null
		log "日配额超限: $1 ($n 次)"
		return 1
	fi
	return 0
}

sec_fail() {
	mkdir -p $WP_RUN/fail
	f=$WP_RUN/fail/$(printf '%s' "$1" | tr . _)
	n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
	echo $n > "$f"
	if [ "$n" -ge 5 ]; then
		mkdir -p $WP_RUN/ban
		echo "$(date +%s)" > "$WP_RUN/ban/$1"
		nft add element inet wifipay banned "{ $1 timeout 600s }" 2>/dev/null
		log "ban $1 (失败 ${n} 次)"
	fi
}

sec_banned() {
	f=$WP_RUN/ban/$1
	[ -f "$f" ] || return 1
	[ $(( $(date +%s) - $(cat "$f") )) -lt 600 ]
}
