#!/bin/sh
. /usr/lib/wifipay/env.sh

CFG_RO="detected_mode lan_if lan_ip lan_net wan_if"

CFG_RW="title portal_port guest_net mode enabled dns_hijack ipv6_block \
trial_enable trial_minutes trial_rate trial_seg_max warn_minutes \
rate_down rate_up share_enable share_max_conn share_action \
day_quota fuse_enable fuse_conns ads_enable ads_freq \
pay_mode pay_qr wx_appid wx_mchid wx_serial \
grace_days grace_rate biz_enable seat_policy default_minutes logo contact"

NUM_KEYS="enabled trial_enable ads_enable fuse_enable share_enable biz_enable \
dns_hijack ipv6_block portal_port trial_minutes trial_rate trial_seg_max \
warn_minutes rate_down rate_up day_quota fuse_conns share_max_conn \
ads_freq grace_days grace_rate default_minutes"

default_of() {
	case "$1" in
		portal_port)     echo 8088 ;;
		trial_minutes)   echo 30 ;;
		trial_rate)      echo 3072 ;;
		trial_seg_max)   echo 0 ;;
		warn_minutes)    echo 5 ;;
		rate_down|rate_up) echo 10240 ;;
		day_quota)       echo 500 ;;
		fuse_conns)      echo 150 ;;
		share_max_conn)  echo 150 ;;
		ads_freq)        echo 3 ;;
		grace_days)      echo 0 ;;
		grace_rate)      echo 1024 ;;
		default_minutes) echo 60 ;;
		enabled|biz_enable) echo 0 ;;
		dns_hijack|ipv6_block|trial_enable|ads_enable|fuse_enable|share_enable) echo 1 ;;
		*)               echo 0 ;;
	esac
}

settings_all() {
	printf '{'; first=1
	for k in $CFG_RO $CFG_RW; do
		v=$(cfg "$k")
		case " $NUM_KEYS " in
			*" $k "*)
				case "$v" in ''|*[!0-9]*) v=$(default_of "$k") ;; esac
				printf '%s"%s":%s' "$([ $first -eq 1 ] && echo '' || echo ',')" "$k" "${v:-0}" ;;
			*)
				printf '%s"%s":"%s"' "$([ $first -eq 1 ] && echo '' || echo ',')" "$k" \
					"$(printf '%s' "$v" | sed 's/[\\"]/\\&/g')" ;;
		esac
		first=0
	done
	printf '}\n'
}

cfg_set() {   # 键 值
	k=$1; v=$2

	case " $CFG_RW " in *" $k "*) ;; *) echo '{"ok":false,"msg":"不允许的键"}'; exit 0 ;; esac

	case " $NUM_KEYS " in
		*" $k "*)
			case "$v" in ''|*[!0-9]*) echo '{"ok":false,"msg":"必须是数字"}'; exit 0 ;; esac
			case "$k" in
				enabled|trial_enable|ads_enable|fuse_enable|share_enable|biz_enable|dns_hijack|ipv6_block)
					case "$v" in 0|1) ;; *) echo '{"ok":false,"msg":"只能是 0 或 1"}'; exit 0 ;; esac ;;
			esac ;;
		mode)
			case "$v" in auto|gateway|bypass) ;; *) echo '{"ok":false,"msg":"mode 只能是 auto/gateway/bypass"}'; exit 0 ;; esac ;;
		pay_mode)
			case "$v" in off|manual|wxpay) ;; *) echo '{"ok":false,"msg":"pay_mode 非法"}'; exit 0 ;; esac ;;
		share_action)
			case "$v" in log|throttle|block) ;; *) echo '{"ok":false,"msg":"share_action 非法"}'; exit 0 ;; esac ;;
		seat_policy)
			case "$v" in reject|replace_oldest) ;; *) echo '{"ok":false,"msg":"seat_policy 非法"}'; exit 0 ;; esac ;;
		*)
			v=$(printf '%s' "$v" | tr -d '"\\' | sed 's/[[:cntrl:]]//g' | cut -c1-120) ;;
	esac

	uci -q set "wifipay.settings.$k=$v"
	uci -q commit wifipay
	log "set $k=$v"
	site_publish 2>/dev/null
	echo '{"ok":true}'
}

site_publish() {
	mkdir -p /www/wifipay
	bname=''; bcode=''
	if [ "$(cfg biz_enable)" = "1" ] && [ -f $WP_D/biz ]; then
		bname=$(awk -F"$TAB" '$1=="name"{print $2; exit}' $WP_D/biz 2>/dev/null)
		bcode=$(awk -F"$TAB" '$1=="code"{print $2; exit}' $WP_D/biz 2>/dev/null)
	fi
	t=/www/wifipay/site.json.$$
	printf '{"title":"%s","logo":"%s","contact":"%s","trial":%s,"trial_minutes":%s,"warn_minutes":%s,"biz_name":"%s","biz_code":"%s"}\n' \
		"$(printf '%s' "$(cfg title)" | sed 's/[\\"]/\\&/g')" \
		"$(cfg logo)" \
		"$(printf '%s' "$(cfg contact)" | sed 's/[\\"]/\\&/g')" \
		"$([ "$(cfg trial_enable)" = "1" ] && echo true || echo false)" \
		"$(jnum "$(cfg trial_minutes)" 30)" \
		"$(jnum "$(cfg warn_minutes)" 5)" \
		"$(printf '%s' "$bname" | sed 's/[\\"]/\\&/g')" \
		"$bcode" > $t
	mv $t /www/wifipay/site.json
	chmod 644 /www/wifipay/site.json
}
