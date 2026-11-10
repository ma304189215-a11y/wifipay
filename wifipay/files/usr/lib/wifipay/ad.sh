#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh

ADS=$WP_D/ads
AD_DIR=/www/wifipay/ads
touch $ADS; mkdir -p $AD_DIR

url_host() { printf '%s' "$1" | sed -n 's|^https\?://\([^/:?#]*\).*|\1|p' | tr 'A-Z' 'a-z'; }

plat_domains() {
	case "$1" in
		jd)     echo "jd.com 3.cn" ;;
		douyin) echo "jinritemai.com douyin.com" ;;
		pdd)    echo "yangkeduo.com pinduoduo.com" ;;
		taobao) echo "taobao.com tmall.com" ;;
		*)      return 1 ;;
	esac
}

plat_ok() {
	h=$(url_host "$2"); [ -n "$h" ] || return 1
	for d in $(plat_domains "$1"); do
		case "$h" in "$d"|*."$d") return 0 ;; esac
	done
	return 1
}

img_ok() {
	h=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
	case "$h" in
		89504e47) return 0 ;;
		ffd8ff*)  return 0 ;;
		47494638) return 0 ;;
		52494646) return 0 ;;
		*)        return 1 ;;
	esac
}

ads_publish() {
	mkdir -p /www/wifipay
	if [ "$(cfg ads_enable)" != "1" ]; then
		printf '[]\n' > /www/wifipay/ads.json
		return 0
	fi
	t=/www/wifipay/ads.json.$$
	printf '[' > $t
	first=1
	[ -f $ADS ] && while IFS=$TAB read -r id title img link plat secs en views clicks; do
		[ -n "$id" ] && [ "$en" = "1" ] || continue
		title=$(printf '%s' "$title" | tr -d '"\\' | sed 's/[[:cntrl:]]//g')
		printf '%s{"id":"%s","title":"%s","img":"/wifipay/ads/%s","link":"%s","plat":"%s","secs":%s}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$id" "$title" "$img" "$link" "$plat" "$(jnum "$secs" 8)" >> $t
		first=0
	done < $ADS
	printf ']\n' >> $t
	mv $t /www/wifipay/ads.json; chmod 644 /www/wifipay/ads.json
}

ads_key() { printf '%s' "$1" | tr ':' '_'; }
ads_today() {
	[ -n "$1" ] || { echo 0; return; }
	d=/var/run/wifipay/adsh/$(date +%Y%m%d).$(ads_key "$1")
	[ -f "$d" ] && cat "$d" || echo 0
}

ads_seen() {
	[ -n "$1" ] || return 0
	mkdir -p /var/run/wifipay/adsh
	d=/var/run/wifipay/adsh/$(date +%Y%m%d).$(ads_key "$1")
	wp_lock
	n=$(( $(cat "$d" 2>/dev/null || echo 0) + 1 ))
	echo $n > "$d"
	wp_unlock
	find /var/run/wifipay/adsh -type f ! -name "$(date +%Y%m%d).*" -delete 2>/dev/null
}

ads_allow() {   # mac -> JSON
	if [ -z "$1" ]; then printf '{"allow":true,"shown":0,"max":0}\n'; return; fi
	max=$(jnum "$(cfg ads_freq)" 3)
	if [ "$max" -le 0 ]; then printf '{"allow":true,"shown":0,"max":0}\n'; return; fi
	shown=$(ads_today "$1")
	case "$shown" in ''|*[!0-9]*) shown=0 ;; esac
	if [ "$shown" -ge "$max" ]; then
		printf '{"allow":false,"shown":%s,"max":%s}\n' "$shown" "$max"
	else
		printf '{"allow":true,"shown":%s,"max":%s}\n' "$shown" "$max"
	fi
}

ads_list() {
	printf '['; first=1
	[ -f $ADS ] && while IFS=$TAB read -r id title img link plat secs en views clicks; do
		[ -n "$id" ] || continue
		printf '%s{"id":"%s","title":"%s","img":"%s","link":"%s","plat":"%s","secs":%s,"enabled":%s,"views":%s,"clicks":%s}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$id" "$title" "$img" "$link" "$plat" \
			"$(jnum "$secs" 8)" "$([ "$en" = "1" ] && echo true || echo false)" \
			"$(jnum "$views" 0)" "$(jnum "$clicks" 0)"
		first=0
	done < $ADS
	printf ']\n'
}

ads_img() {   # 文件名 base64临时文件
	name=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]//g')
	[ -n "$name" ] || { echo '{"ok":false,"msg":"文件名非法"}'; exit 0; }
	src=$2; [ -f "$src" ] || { echo '{"ok":false,"msg":"没有收到文件"}'; exit 0; }
	[ "$(wc -c < "$src")" -le 700000 ] || { echo '{"ok":false,"msg":"图片超过 500KB"}'; exit 0; }
	t=$AD_DIR/.tmp.$$
	base64 -d "$src" > $t 2>/dev/null || { rm -f $t; echo '{"ok":false,"msg":"解码失败"}'; exit 0; }
	img_ok $t || { rm -f $t; echo '{"ok":false,"msg":"不是有效图片"}'; exit 0; }
	mv $t "$AD_DIR/$name"; chmod 644 "$AD_DIR/$name"
	echo '{"ok":true,"name":"'$name'"}'
}

ads_add() {   # 标题 平台 链接 图片文件名 秒数
	title=$(printf '%s' "$1" | tr -d '"\\' | sed 's/[[:cntrl:]]//g')
	title=$(printf '%s' "$title" | cut -c1-200)
	[ -n "$title" ] || title=广告

	plat_ok "$2" "$3" || { echo '{"ok":false,"msg":"这条链接不属于所选平台"}'; exit 0; }
	[ -f "$AD_DIR/$4" ] && img_ok "$AD_DIR/$4" || { echo '{"ok":false,"msg":"图片无效"}'; exit 0; }
	id=a$(date +%s)$(tr -dc 'a-z0-9' < /dev/urandom | head -c 3)
	wp_lock
	printf '%s\t%s\t%s\t%s\t%s\t%s\t1\t0\t0\n' "$id" "$title" "$4" "$3" "$2" "$(jnum "$5" 8)" >> $ADS
	wp_unlock
	ads_publish
	echo '{"ok":true,"id":"'$id'"}'
}

ads_del() {
	wp_lock
	awk -F"$TAB" -v i="$1" '$1!=i' $ADS > $ADS.tmp && mv $ADS.tmp $ADS
	wp_unlock
	ads_publish; echo '{"ok":true}'
}

ads_toggle() {
	wp_lock
	awk -F"$TAB" -v i="$1" 'BEGIN{OFS="\t"} $1==i{$7=($7=="1"?0:1)} {print}' $ADS > $ADS.tmp && mv $ADS.tmp $ADS
	wp_unlock
	ads_publish; echo '{"ok":true}'
}

ads_hit() {   # id view|click [mac]
	[ -n "$1" ] || exit 1
	wp_lock
	awk -F"$TAB" -v i="$1" -v t="$2" 'BEGIN{OFS="\t"} $1==i{ if(t=="click") $9=$9+1; else $8=$8+1 } {print}' \
		$ADS > $ADS.tmp && mv $ADS.tmp $ADS
	wp_unlock
	[ "$2" = "view" ] && [ -n "${3:-}" ] && ads_seen "$3"
	ads_publish 2>/dev/null
	echo '{"ok":true}'
}

ads_cmd() {
	case "$1" in
		list)    ads_list ;;
		add)     ads_add "$2" "$3" "$4" "$5" "$6" ;;
		del)     ads_del "$2" ;;
		toggle)  ads_toggle "$2" ;;
		hit)     ads_hit "$2" "$3" "$4" ;;
		img)     ads_img "$2" "$3" ;;
		quota)   ads_allow "$2" ;;
		publish) ads_publish ;;
	esac
}
