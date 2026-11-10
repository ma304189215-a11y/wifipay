#!/bin/sh
. /usr/lib/wifipay/env.sh
. /usr/lib/wifipay/sec.sh

BIZ=$WP_D/biz
AUD=$WP_D/audit.log

biz_field() {
	[ -f "$BIZ" ] || { echo ""; return; }
	awk -F"$TAB" -v k="$1" '$1==k{print $2; exit}' "$BIZ" 2>/dev/null
}

biz_ready() {
	[ "$(cfg biz_enable)" = "1" ] || { echo false; return; }
	[ -n "$(biz_field name)" ] || { echo false; return; }
	if [ "$(biz_field type)" = "company" ]; then
		case "$(biz_field code)" in
			??????????????????) echo true ;;
			*) echo false ;;
		esac
	else
		echo true
	fi
}

biz_get() {
	printf '{"type":"%s","name":"%s","code":"%s","addr":"%s","until":"%s","photo":"%s","ready":%s}\n' \
		"$(biz_field type)" "$(jstr "$(biz_field name)")" "$(biz_field code)" \
		"$(jstr "$(biz_field addr)")" "$(biz_field until)" "$(biz_field photo)" "$(biz_ready)"
}

biz_set() {   # 键 值
	k=$1; v=$2
	case "$k" in type|name|code|addr|until|photo) ;; *) echo '{"ok":false,"msg":"非法字段"}'; exit 0 ;; esac

	case "$k" in
		type)
			case "$v" in company|personal) ;; *) echo '{"ok":false,"msg":"type 只能是 company 或 personal"}'; exit 0 ;; esac ;;
		code)
			if [ -n "$v" ]; then
				printf '%s' "$v" | grep -qE '^[0-9A-HJ-NPQRTUWXY]{18}$' || {
					echo '{"ok":false,"msg":"统一社会信用代码应为 18 位"}'; exit 0; }
			fi ;;
		until)
			if [ -n "$v" ]; then
				printf '%s' "$v" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || {
					echo '{"ok":false,"msg":"日期格式应为 YYYY-MM-DD"}'; exit 0; }
			fi ;;
		photo)
			if [ -n "$v" ]; then
				printf '%s' "$v" | grep -qE '^/ext_overlay/wifipay/biz/[A-Za-z0-9._-]+$' || {
					echo '{"ok":false,"msg":"照片路径非法"}'; exit 0; }
			fi ;;
		*)
			v=$(printf '%s' "$v" | tr -d '"\\' | sed 's/[[:cntrl:]]//g' | cut -c1-120) ;;
	esac

	old=$(biz_field "$k")
	wp_lock
	{ [ -f "$BIZ" ] && awk -F"$TAB" -v k="$k" '$1!=k' "$BIZ"; printf '%s\t%s\n' "$k" "$v"; } > $BIZ.tmp
	mv $BIZ.tmp $BIZ
	chmod 600 $BIZ
	wp_unlock

	case "$k" in
		code) printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$k" "$(sec_mask "$old")" "$(sec_mask "$v")" >> $AUD ;;
		*)    printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$k" "$old" "$v" >> $AUD ;;
	esac
	tail -n 500 $AUD > $AUD.tmp 2>/dev/null && mv $AUD.tmp $AUD
	chmod 600 $AUD

	log "biz set $k"
	biz_get
}

biz_audit() {
	printf '['
	first=1
	[ -f "$AUD" ] && while IFS=$TAB read -r ts k o n; do
		[ -n "$ts" ] || continue
		printf '%s{"ts":"%s","field":"%s","old":"%s","new":"%s"}' \
			"$([ $first -eq 1 ] && echo '' || echo ',')" "$ts" "$k" "$o" "$n"
		first=0
	done < $AUD
	printf ']\n'
}

biz_cmd() {
	case "$1" in
		get)   biz_get ;;
		set)   biz_set "$2" "$3" ;;
		audit) biz_audit ;;
	esac
}
