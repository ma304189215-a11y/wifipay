#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh
. /usr/lib/wifipay/net.sh
. /usr/lib/wifipay/plan.sh

SUB=$WP_D/subjects
BIND=$WP_D/bindings
touch $SUB $BIND

sub_code() {
	r=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | sed 's/[^A-Z0-9]//g' | cut -c1-12)
	printf '%s-%s' "$r" "$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 4)"
}

sub_line() { awk -F"$TAB" -v r="$1" '$1==r' $SUB 2>/dev/null; }

rooms_add() {   # 房间号 [名额]
	r=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | sed 's/[^A-Z0-9]//g' | cut -c1-12)
	[ -n "$r" ] || { echo '{"ok":false,"msg":"房间号只能用字母和数字"}'; exit 0; }
	seats=$(jnum "$2" 1)
	[ -n "$(sub_line "$r")" ] && { echo '{"ok":false,"msg":"房间已存在"}'; exit 0; }

	i=0
	while [ $i -lt 5 ]; do
		c=$(sub_code "$r")
		awk -F"$TAB" -v c="$c" '$2==c{f=1} END{exit !f}' $SUB 2>/dev/null || break
		i=$((i + 1))
	done

	wp_lock
	printf '%s\t%s\t%s\t0\t\n' "$r" "$c" "$seats" >> $SUB
	wp_unlock
	printf '{"ok":true,"room":"%s","code":"%s","seats":%s}\n' "$r" "$c" "$seats"
}

rooms_bind() {   # 入住码 mac
	code=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
	mac=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
	sec_mac "$mac" || { echo '{"ok":false,"msg":"识别不到设备"}'; exit 0; }

	line=$(awk -F"$TAB" -v c="$code" '$2==c' $SUB 2>/dev/null)
	[ -n "$line" ] || { echo '{"ok":false,"msg":"入住码无效"}'; exit 0; }
	room=$(printf '%s' "$line" | cut -f1)
	seats=$(jnum "$(printf '%s' "$line" | cut -f3)" 1)
	exp=$(jnum "$(printf '%s' "$line" | cut -f4)" 0)
	now=$(date +%s)

	[ "$exp" -gt "$now" ] || { echo '{"ok":false,"msg":"房间已到期，请联系房东续费"}'; exit 0; }

	if ! awk -F"$TAB" -v m="$mac" '$1==m{f=1} END{exit !f}' $BIND 2>/dev/null; then
		used=$(awk -F"$TAB" -v r="$room" '$2==r' $BIND 2>/dev/null | wc -l)
		if [ "$seats" -gt 0 ] && [ "$used" -ge "$seats" ]; then
			case "$(cfg seat_policy)" in
				replace_oldest)
					old=$(awk -F"$TAB" -v r="$room" '$2==r{print $1; exit}' $BIND)
					if [ -n "$old" ]; then
						wp_lock
						awk -F"$TAB" -v m="$old" '$1!=m' $BIND > $BIND.tmp && mv $BIND.tmp $BIND
						wp_unlock
						plan_revoke "$old" >/dev/null
						log "seat replace: room=$room old=$old new=$mac"
					fi ;;
				*)
					echo '{"ok":false,"msg":"名额已满，请联系房东增开"}'; exit 0 ;;
			esac
		fi
		wp_lock
		printf '%s\t%s\t%s\n' "$mac" "$room" "$now" >> $BIND
		wp_unlock
	fi

	plan_allow "$mac" "$(( (exp - now) / 60 ))" "房间$room" >/dev/null
	printf '{"ok":true,"room":"%s","exp":%s}\n' "$room" "$exp"
}

rooms_unbind() {   # 房间 mac
	room=$1; mac=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
	wp_lock
	awk -F"$TAB" -v m="$mac" -v r="$room" '!($1==m && $2==r)' $BIND > $BIND.tmp && mv $BIND.tmp $BIND
	wp_unlock
	plan_revoke "$mac" >/dev/null
	printf '{"ok":true}\n'
}

rooms_unbindall() {   # 房间
	room=$1
	awk -F"$TAB" -v r="$room" '$2==r{print $1}' $BIND 2>/dev/null | while read -r m; do
		[ -n "$m" ] && plan_revoke "$m" >/dev/null
	done
	wp_lock
	awk -F"$TAB" -v r="$room" '$2!=r' $BIND > $BIND.tmp && mv $BIND.tmp $BIND
	wp_unlock
	printf '{"ok":true}\n'
}

rooms_renew() {   # 房间 天数
	room=$1; days=$(jnum "$2" 30)
	line=$(sub_line "$room")
	[ -n "$line" ] || { echo '{"ok":false,"msg":"房间不存在"}'; exit 0; }
	now=$(date +%s)
	exp=$(jnum "$(printf '%s' "$line" | cut -f4)" 0)
	[ "$exp" -gt "$now" ] || exp=$now
	newexp=$((exp + days * 86400))

	wp_lock
	awk -F"$TAB" -v r="$room" -v e="$newexp" 'BEGIN{OFS="\t"} $1==r{$4=e} {print}' $SUB > $SUB.tmp && mv $SUB.tmp $SUB
	wp_unlock

	awk -F"$TAB" -v r="$room" '$2==r{print $1}' $BIND 2>/dev/null | while read -r m; do
		[ -n "$m" ] && plan_allow "$m" "$(( (newexp - $(date +%s)) / 60 ))" "房间$room" >/dev/null
	done
	printf '{"ok":true,"exp":%s}\n' "$newexp"
}

rooms_resetcode() {   # 房间
	room=$1
	[ -n "$(sub_line "$room")" ] || { echo '{"ok":false,"msg":"房间不存在"}'; exit 0; }
	c=$(sub_code "$room")
	wp_lock
	awk -F"$TAB" -v r="$room" -v c="$c" 'BEGIN{OFS="\t"} $1==r{$2=c} {print}' $SUB > $SUB.tmp && mv $SUB.tmp $SUB
	wp_unlock
	printf '{"ok":true,"code":"%s"}\n' "$c"
}

rooms_del() {   # 房间
	room=$1
	[ -n "$(sub_line "$room")" ] || { echo '{"ok":false,"msg":"房间不存在"}'; exit 0; }
	awk -F"$TAB" -v r="$room" '$2==r{print $1}' $BIND 2>/dev/null | while read -r m; do
		[ -n "$m" ] && plan_revoke "$m" >/dev/null
	done
	wp_lock
	awk -F"$TAB" -v r="$room" '$1!=r' $SUB > $SUB.tmp && mv $SUB.tmp $SUB
	awk -F"$TAB" -v r="$room" '$2!=r' $BIND > $BIND.tmp && mv $BIND.tmp $BIND
	wp_unlock
	printf '{"ok":true}\n'
}

rooms_list() {
	now=$(date +%s)
	printf '['
	first=1
	while IFS=$TAB read -r room code seats exp note; do
		[ -n "$room" ] || continue
		used=$(awk -F"$TAB" -v r="$room" '$2==r' $BIND 2>/dev/null | wc -l)
		printf '%s{"room":"%s","code":"%s","seats":%s,"used":%s,"exp":%s,"remain":%s}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$room" "$code" \
			"$(jnum "$seats" 1)" "$used" "$(jnum "$exp" 0)" "$(( $(jnum "$exp" 0) - now ))"
		first=0
	done < $SUB
	printf ']\n'
}

rooms_gc() {
	[ -s $BIND ] || return 0
	while IFS=$TAB read -r mac room ts; do
		[ -n "$mac" ] || continue
		[ -n "$(sub_line "$room")" ] || { clean_bind "$mac" "$room"; continue; }
		awk -F"$TAB" -v m="$mac" '$1==m{f=1} END{exit !f}' $WP_D/allowed 2>/dev/null || clean_bind "$mac" "$room"
	done < $BIND
}

clean_bind() {
	wp_lock
	awk -F"$TAB" -v m="$1" -v r="$2" '!($1==m && $2==r)' $BIND > $BIND.tmp && mv $BIND.tmp $BIND
	wp_unlock
}

rooms_cmd() {
	case "$1" in
		list)        rooms_list ;;
		add)         rooms_add "$2" "$3" ;;
		bind)        rooms_bind "$2" "$3" ;;
		unbind)      rooms_unbind "$2" "$3" ;;
		unbindall)   rooms_unbindall "$2" ;;
		renew)       rooms_renew "$2" "$3" ;;
		resetcode)   rooms_resetcode "$2" ;;
		del)         rooms_del "$2" ;;
		gc)          rooms_gc ;;
	esac
}
