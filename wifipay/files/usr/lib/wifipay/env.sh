umask 077
#!/bin/sh
# wifipay 公共环境与自动探测

WP_LIB=/usr/lib/wifipay
WP_D=/etc/wifipay
WP_RUN=/var/run/wifipay
TAB=$(printf '\t')
mkdir -p "$WP_D" "$WP_RUN"

cfg() { uci -q get "wifipay.settings.$1"; }
log() { logger -t wifipay "$*" 2>/dev/null; }

jnum() {
	case "${1:-}" in
		''|*[!0-9]*) printf '%s' "${2:-0}" ;;
		*)           printf '%s' "$1" ;;
	esac
}
jstr() { printf '"%s"' "$(printf '%s' "${1:-}" | sed 's/[\\"]/\\&/g')"; }

mac2ip() {
	_ip=$(awk -v m="$1" '$2==m{print $3; exit}' /tmp/dhcp.leases 2>/dev/null)
	[ -n "$_ip" ] || _ip=$(ip neigh 2>/dev/null | awk -v m="$1" '$4=="lladdr" && $5==m {print $1; exit}')
	printf '%s' "$_ip"
}
ip2mac() {
	_m=$(awk -v i="$1" '$3==i{print $2; exit}' /tmp/dhcp.leases 2>/dev/null)
	[ -n "$_m" ] || _m=$(ip neigh 2>/dev/null | awk -v i="$1" '$1==i && $4=="lladdr" {print $5; exit}')
	printf '%s' "$_m"
}

wp_lock()   { exec 9>"$WP_RUN/lock"; flock 9; }
wp_unlock() { exec 9>&-; }

wp_detect() {
	_lan_if=$(uci -q get network.lan.device)
	[ -n "$_lan_if" ] || _lan_if=$(uci -q get network.lan.ifname)
	[ -n "$_lan_if" ] || _lan_if=br-lan
	_lan_ip=$(ip -4 addr show dev "$_lan_if" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
	_lan_net=$(ip -4 route show dev "$_lan_if" scope link 2>/dev/null | awk '{print $1; exit}')
	_gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')
	_wan_if=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')

	[ -n "$(cfg lan_if)" ]    || uci -q set wifipay.settings.lan_if="$_lan_if"
	[ -n "$(cfg lan_ip)" ]    || uci -q set wifipay.settings.lan_ip="$_lan_ip"
	[ -n "$(cfg lan_net)" ]   || uci -q set wifipay.settings.lan_net="$_lan_net"
	[ -n "$(cfg wan_if)" ]    || uci -q set wifipay.settings.wan_if="$_wan_if"
	[ -n "$(cfg guest_net)" ] || uci -q set wifipay.settings.guest_net="$_lan_net"

	case "$(cfg mode)" in
		gateway|bypass) _dm=$(cfg mode) ;;
		*)
			if [ -z "$_gw" ]; then
				_dm=unknown
			elif [ -n "$_lan_net" ] && ip route get "$_gw" 2>/dev/null | grep -q "dev $_lan_if"; then
				_dm=bypass
			else
				_dm=gateway
			fi ;;
	esac
	[ "$_dm" = "$(cfg detected_mode)" ] || uci -q set wifipay.settings.detected_mode="$_dm"
	uci -q commit wifipay
}
