#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh
. /usr/lib/wifipay/net.sh

# ---- 租期写入（不加锁）----
_allow_nolock() {   # mac 分钟 备注 [状态]
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	min=$2; note=${3:-}; state=${4:-ok}
	now=$(date +%s)
	cur=$(awk -F"$TAB" -v m="$mac" '$1==m{print $2}' $WP_D/allowed 2>/dev/null)
	[ -n "$cur" ] && [ "$cur" -gt "$now" ] && now=$cur
	exp=$((now + min * 60))
	awk -F"$TAB" -v m="$mac" '$1!=m' $WP_D/allowed 2>/dev/null > $WP_D/allowed.tmp
	printf '%s\t%s\t%s\t%s\n' "$mac" "$exp" "$note" "$state" >> $WP_D/allowed.tmp
	mv $WP_D/allowed.tmp $WP_D/allowed; chmod 600 $WP_D/allowed 2>/dev/null
	chmod 600 $WP_D/allowed
}

plan_allow() {
	wp_lock
	_allow_nolock "$@"
	wp_unlock
	exp=$(awk -F"$TAB" -v m="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '$1==m{print $2}' $WP_D/allowed)
	[ "$(cfg enabled)" = "1" ] && { sync_allowed; sync_grace; }
	printf '{"ok":true,"remain":%s}\n' $((exp - $(date +%s)))
}

plan_revoke() {
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	wp_lock
	awk -F"$TAB" -v m="$mac" '$1!=m' $WP_D/allowed 2>/dev/null > $WP_D/allowed.tmp
	mv $WP_D/allowed.tmp $WP_D/allowed; chmod 600 $WP_D/allowed 2>/dev/null
	wp_unlock
	sync_allowed 2>/dev/null
	sync_grace 2>/dev/null
	printf '{"ok":true}\n'
}

plan_status() {
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	now=$(date +%s)
	line=$(awk -F"$TAB" -v m="$mac" '$1==m' $WP_D/allowed 2>/dev/null)
	exp=$(printf '%s' "$line" | cut -f2)
	st=$(printf '%s' "$line" | cut -f4)
	rem=0; [ -n "$exp" ] && [ "$exp" -gt "$now" ] && rem=$((exp - now))
	printf '{"mac":"%s","remain":%s,"state":"%s"}\n' "$mac" "$rem" "${st:-none}"
}

# ---- 状态迁移 ----
plan_gc() {
	now=$(date +%s)
	g=$(( $(jnum "$(cfg grace_days)" 0) * 86400 ))
	wp_lock
	awk -F"$TAB" -v now="$now" -v g="$g" 'BEGIN{OFS="\t"}
		NF >= 2 {
			state = ($4 == "" ? "ok" : $4)
			if ($2 > now)                     state = "ok"
			else if (g > 0 && $2 + g > now)   state = "grace"
			else                              next
			$4 = state
			print
		}' $WP_D/allowed > $WP_D/allowed.tmp && mv $WP_D/allowed.tmp $WP_D/allowed; chmod 600 $WP_D/allowed 2>/dev/null
	wp_unlock
}

# ---- 套餐 ----
plans_json() {
	printf '['
	first=1
	for s in $(uci -q show wifipay | sed -n 's/^wifipay\.\([^.=]*\)=plan$/\1/p'); do
		printf '%s{"id":"%s","title":"%s","price":%s,"minutes":%s}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$s" \
			"$(uci -q get wifipay.$s.title)" "$(jnum "$(uci -q get wifipay.$s.price)")" \
			"$(jnum "$(uci -q get wifipay.$s.minutes)")"
		first=0
	done
	printf ']\n'
}

# ---- 试用 ----
plan_trial() {      # mac ip cookie
	mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	ip=$2; ck=$3
	seg=$(printf '%s' "$ip" | cut -d. -f1-3)
	now=$(date +%s)

	sec_mac "$mac" || { echo '{"ok":false,"msg":"识别不到设备"}'; exit 0; }
	[ "$(cfg trial_enable)" = "1" ] || { echo '{"ok":false,"msg":"未开启试用"}'; exit 0; }
	[ -f $WP_D/trial ] || : > $WP_D/trial

	wp_lock

	if awk -v m="m$mac" -v c="c$ck" -v n="$now" \
		'($1==m || $1==c) && $2 > n-86400 {f=1} END{exit !f}' $WP_D/trial 2>/dev/null; then
		wp_unlock; echo '{"ok":false,"msg":"这台设备今天的试用已用完"}'; exit 0
	fi

	max=$(jnum "$(cfg trial_seg_max)" 0)
	if [ "$max" -gt 0 ]; then
		cnt=$(awk -v s="i$seg" -v n="$now" '$1==s && $2 > n-86400' $WP_D/trial 2>/dev/null | wc -l)
		if [ "$cnt" -ge "$max" ]; then
			wp_unlock; echo '{"ok":false,"msg":"今日试用名额已满"}'; exit 0
		fi
	fi

	printf 'm%s\t%s\n' "$mac" "$now" >> $WP_D/trial
	printf 'i%s\t%s\n' "$seg" "$now" >> $WP_D/trial
	[ -n "$ck" ] && printf 'c%s\t%s\n' "$ck" "$now" >> $WP_D/trial

	awk -v o="$((now - 604800))" '$2 > o' $WP_D/trial > $WP_D/trial.tmp && mv $WP_D/trial.tmp $WP_D/trial
	chmod 600 $WP_D/trial

	_allow_nolock "$mac" "$(jnum "$(cfg trial_minutes)" 30)" trial
	wp_unlock

	[ "$(cfg enabled)" = "1" ] && sync_allowed
	log "trial mac=$mac seg=$seg"
	echo '{"ok":true,"msg":"已开通试用"}'
}

# ---- 兑换码 ----
codes_add() {       # 个数 分钟
	n=$(jnum "$1" 10); min=$(jnum "$2" "$(jnum "$(cfg default_minutes)" 60)")
	wp_lock
	i=0
	while [ "$i" -lt "$n" ]; do
		c=$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 10)
		[ -n "$c" ] || continue
		grep -q "^$c$TAB" $WP_D/codes 2>/dev/null && continue
		printf '%s\t%s\t0\t0\n' "$c" "$min" >> $WP_D/codes
		i=$((i + 1))
	done
	wp_unlock
	chmod 600 $WP_D/codes
	codes_list
}

codes_list() {
	printf '['; first=1
	[ -f $WP_D/codes ] && while IFS=$TAB read -r c min used ts; do
		[ -n "$c" ] || continue
		printf '%s{"code":"%s","minutes":%s,"used":%s,"ts":%s}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$c" "$(jnum "$min" 60)" \
			"$([ "${used:-0}" = "1" ] && echo true || echo false)" "$(jnum "$ts" 0)"
		first=0
	done < $WP_D/codes
	printf ']\n'
}

codes_export() {
	printf 'code,minutes,used,time\n'
	[ -f $WP_D/codes ] && while IFS=$TAB read -r c min used ts; do
		[ -n "$c" ] || continue
		printf '%s,%s,%s,%s\n' "$c" "$min" "$used" "${ts:-0}"
	done < $WP_D/codes
}

plan_redeem() {     # 码 mac
	code=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
	mac=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
	sec_code "$code" || { echo '{"ok":false,"msg":"兑换码格式不对"}'; exit 0; }
	sec_mac "$mac" || { echo '{"ok":false,"msg":"识别不到设备，请重连 WiFi"}'; exit 0; }

	wp_lock
	min=$(awk -F"$TAB" -v c="$code" '$1==c && $3=="0"{print $2}' $WP_D/codes 2>/dev/null)
	if [ -z "$min" ]; then
		wp_unlock
		sec_fail "$(cfg lan_ip)" 2>/dev/null
		echo '{"ok":false,"msg":"兑换码无效或已使用"}'; exit 0
	fi
	awk -F"$TAB" -v c="$code" -v t="$(date +%s)" 'BEGIN{OFS="\t"} $1==c{$3=1;$4=t} {print}' \
		$WP_D/codes > $WP_D/codes.tmp && mv $WP_D/codes.tmp $WP_D/codes
	_allow_nolock "$mac" "$min" "码$(sec_mask "$code")"
	wp_unlock
	[ "$(cfg enabled)" = "1" ] && sync_allowed
	log "redeem $(sec_mask "$code") mac=$mac"
	exp=$(awk -F"$TAB" -v m="$mac" '$1==m{print $2}' $WP_D/allowed)
	printf '{"ok":true,"remain":%s}\n' $((exp - $(date +%s)))
}

# ---- 设备列表 ----
allowed_list() {
	now=$(date +%s)
	printf '['
	awk -F"$TAB" -v now="$now" '
		BEGIN {
			while ((getline l < "/tmp/dhcp.leases") > 0) {
				n = split(l, f, " ")
				if (n >= 3) { ip[f[2]] = f[3]; host[f[2]] = (n >= 4 ? f[4] : "") }
			}
		}
		NF >= 2 {
			printf "%s{\"mac\":\"%s\",\"ip\":\"%s\",\"host\":\"%s\",\"remain\":%d,\"note\":\"%s\",\"state\":\"%s\"}",
				(first++ ? "," : ""), $1, ($1 in ip ? ip[$1] : ""),
				(host[$1] == "*" ? "" : host[$1]), $2 - now,
				($3 == "" ? "" : $3), ($4 == "" ? "ok" : $4)
		}' $WP_D/allowed 2>/dev/null
	printf ']\n'
}
