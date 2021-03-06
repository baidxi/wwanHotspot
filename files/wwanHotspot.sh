#!/bin/sh

#  wwanHotspot
#
#  Wireless WAN Hotspot management application for OpenWrt routers.
#  $Revision: 1.24 $
#
#  Copyright (C) 2017-2018 Jordi Pujol <jordipujolp AT gmail DOT com>
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3, or (at your option)
#  any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#************************************************************************

_integer_value() {
	local n="${1}" d="${2}" v 
	v="$(2> /dev/null printf '%d' "$(printf '%s' "${n}" | \
	sed -nre '/^[[:digit:]]+$/p;q')")" && \
		echo ${v} || \
		echo ${d}
}

_datetime() {
	date +'%Y-%m-%d %H:%M:%S'
}

_applog() {
	printf '%s\n' "$(_datetime) $(echo "${@}")" >> "/var/log/${NAME}"
}

_log() {
	logger -t "${NAME}" "${@}"
	_applog "syslog:" "${@}"
}

_sleep() {
	if [ -n "${StatMsgs}" ]; then
		wait || :
		ListStat &
		[ ${Status} -le ${CONNECTING} ] || \
			StatMsgs=""
	fi
	if [ -n "${NoSleep}" ]; then
		NoSleep=""
	else
		local e i
		[ ${Status} -eq ${DISCONNECTED} ] && \
		e="$(set | \
		sed -nre "\|^net[[:digit:]]+_blacklistexp='([[:digit:]]+)'| s||\1|p" | \
		sort -n | head -qn 1)" && \
		[ -n "${e}" ] && \
		[ $((i=${e}+1-$(date --utc +'%s'))) -le ${Interval} ] || \
			i=${Interval}
		if [ ${i} -gt 0 ]; then
			[ -z "${Debug}" ] || \
				_applog "sleeping ${i} seconds"
			sleep ${i} > /dev/null 2>&1 &
			wait $((PidSleep=${!})) || :
			[ -z "${Debug}" ] || \
				_applog "sleeping ended"
			PidSleep=""
		fi
	fi
	wait || :
}

AddStatMsg() {
	StatMsgs="${StatMsgs:+"${StatMsgs}${LF}"}$(_datetime) $(echo "${@}")"
}

_ps_children() {
	local p
	for p in $(pgrep -P "${1}"); do
		echo "${p}"
		_ps_children "${p}"
	done
}

HotspotBlackList() {
	local hotspot="${1}" cause="${2}" expires="${3}"
	eval net${hotspot}_blacklisted=\"${cause} $(_datetime)\" || :
	if [ ${expires} -eq 0 ]; then
		_log "Blacklisting hotspot ${hotspot}:'${WwanSsid}'"
		AddStatMsg "Blacklisting hotspot ${hotspot}:'${WwanSsid}'"
	else
		eval net${hotspot}_blacklistexp=\"$((${expires}+$(date --utc +'%s')))\" || :
		_log "Blacklisting hotspot ${hotspot}:'${WwanSsid}' for ${expires} seconds"
		AddStatMsg "Blacklisting hotspot ${hotspot}:'${WwanSsid}'" \
			"for ${expires} seconds"
	fi
}

BlackListExpired() {
	local i=0 blacklistexp ssid
	while [ $((i++)) -lt ${CfgSsidsCnt} ]; do
		eval blacklistexp=\"\${net${i}_blacklistexp:-}\" || :
		[ -n "${blacklistexp}" ] && \
		[ $(date --utc +'%s') -ge ${blacklistexp} ] || \
			continue
		unset net${i}_blacklisted net${i}_blacklistexp || :
		eval ssid=\"\${net${i}_ssid:-}\"
		_log "Blacklisting has expired for hotspot ${i}:'${ssid}'"
		AddStatMsg "Blacklisting has expired for hotspot ${i}:'${ssid}'"
	done
}

IsWifiActive() {
	local ssid="${1}" iface="${2:-"${WIface}"}" ssid1
	ssid1="$(iwinfo "${iface}" info 2> /dev/null | \
	sed -nre '\|^'"${iface}"'[[:blank:]]+ESSID: (.+)$| s||\1|p')" && \
	[ "${ssid1}" = "${ssid}" ]
}

WatchWifi() {
	local c="${1:-10}" iface ApSsid ApDisabled
	if [ -z "${WIfaceAP}" ]; then
		sleep ${c}
		return 0
	fi
	[ "$(uci -q get wireless.@wifi-iface[${WIfaceSTA}].disabled)" = 1 ] && \
		iface="${WIface}" || \
		iface="${WIface}-1"
	ApSsid="$(uci -q get wireless.@wifi-iface[${WIfaceAP}].ssid)" || :
	ApDisabled="$(uci -q get wireless.@wifi-iface[${WIfaceAP}].disabled)" || :
	while [ $((c--)) -gt 0 ]; do
		sleep 1
		[ "${ApDisabled}" != 1 ] || \
			break
		! IsWifiActive "\"${ApSsid}\"" "${iface}" || \
			break
	done
}

ScanRequested() {
	_applog "Scan requested"
	if [ -n "${PidSleep}" ]; then
		WwanErr=0
		ScanRequest=${CfgSsidsCnt}
		kill -TERM "${PidSleep}" || :
	else
		NoSleep="y"
		[ -z "${PidCheckConn}" ] || \
			kill -TERM "${PidCheckConn}" || :
	fi
}

_exit() {
	trap - EXIT HUP USR1 USR2
	_log "Exiting"
	pids="$(_ps_children "${PidDaemon}")"
	[ -z "${pids}" ] || \
		kill -TERM ${pids} > /dev/null 2>&1 &
	echo "${NAME} daemon exit ..." >> "/var/log/${NAME}.stat"
	wait || :
}

ListStat() {
	exec > "/var/log/${NAME}.stat"
	echo "${NAME} status:"
	echo "${StatMsgs}"
	echo
	echo "Debug=\"${Debug}\""
	echo "ScanAuto=\"${ScanAuto}\""
	echo "Sleep=${Sleep}"
	echo "SleepDsc=${SleepDsc}"
	echo "SleepScanAuto=${SleepScanAuto}"
	echo "BlackList=${BlackList}"
	echo "BlackListExpires=${BlackListExpires}"
	echo "BlackListNetwork=${BlackListNetwork}"
	echo "BlackListNetworkExpires=${BlackListNetworkExpires}"
	echo "PingWait=${PingWait}"
	echo "LogRotate=${LogRotate}"
	echo
	local i=0
	while [ $((i++)) -lt ${CfgSsidsCnt} ]; do
		set | grep -se "^net${i}_" | sort -r
		echo
	done
	[ "$(uci -q get wireless.@wifi-iface[${WIfaceSTA}].disabled)" != 1 ] || \
		echo "Hotspot client is not enabled${LF}"
	iwinfo
	IsWanConnected && \
		echo "WAN interface is connected" || \
		echo "WAN interface is disconnected"
	echo
	ip route show
}

ListStatus() {
	AddStatMsg "Updating status report"
	ScanRequested
}

BackupRotate() {
	local f="${1}" r=${LogRotate}
	[ -f "${f}" ] && \
		mv -f "${f}" "${f}_$(date --utc +'%s')" || \
		r=0
	printf '%s\n' "${f}_"* | \
	head -qn -${r} | \
	while IFS= read -r f; do
		rm -f "${f}"
	done
}

LoadConfig() {
	_log "Loading configuration"

	# config variables, default values
	Debug="y"
	ScanAuto="y"
	Sleep=20
	SleepDsc="$((${Sleep}*3))"
	SleepScanAuto="$((${Sleep}*15))"
	BlackList=3
	BlackListExpires=0
	BlackListNetwork=3
	BlackListNetworkExpires=$((10*60))
	PingWait=7
	LogRotate=3
	unset $(set | awk -F '=' \
		'$1 ~ "^net[[:digit:]]+_" {print $1}') 2> /dev/null || :

	[ ! -s "/etc/config/${NAME}" ] || \
		. "/etc/config/${NAME}"

	Debug="${Debug:-}"
	ScanAuto="${ScanAuto:-}"
	Sleep="$(_integer_value "${Sleep}" 20)"
	SleepDsc="$(_integer_value "${SleepDsc}" $((${Sleep}*3)) )"
	SleepScanAuto="$(_integer_value "${SleepScanAuto}" $((${Sleep}*15)) )"
	BlackList="$(_integer_value "${BlackList}" 3)"
	BlackListExpires="$(_integer_value "${BlackListExpires}" 0)"
	BlackListNetwork="$(_integer_value "${BlackListNetwork}" 3)"
	BlackListNetworkExpires="$(_integer_value "${BlackListNetworkExpires}" $((10*60)))"
	PingWait="$(_integer_value "${PingWait}" 7)"
	LogRotate="$(_integer_value "${LogRotate}" 3)"

	BackupRotate "/var/log/${NAME}"
	BackupRotate "/var/log/${NAME}.xtrace"

	if [ "${Debug}" = "xtrace" ]; then
		exec >> "/var/log/${NAME}.xtrace" 2>&1
		set -o xtrace
	else
		set +o xtrace
		exec >> "/var/log/${NAME}" 2>&1
	fi

	IfaceWan="$(uci -q get network.wan.ifname)" || :
	local i=-1 j m d
	WIfaceAP=""
	WIfaceSTA=""
	while [ -z "${WIfaceAP}" ]; do
		while [ $((i++)) ]; do
			if ! m="$(uci -q get wireless.@wifi-iface[${i}].mode)"; then
				[ -z "${WIfaceSTA}" ] || \
					break 2
				_log "Invalid AP+STA configuration. Exiting"
				exit 1
			fi
			if [ "${m}" = "sta" ]; then
				WIfaceSTA=${i}
				d="$(uci -q get wireless.@wifi-iface[${i}].device)"
				WIface="wlan$(iwinfo "${d}" info | \
					sed -nre '/.*PHY name: phy([[:digit:]]+)$/ s//\1/p')"
				break
			fi
		done
		j=-1
		while [ $((j++)) ] && \
		m="$(uci -q get wireless.@wifi-iface[${j}].mode)"; do
			if [ "${m}" = "ap" ] && \
			[ "$(uci -q get wireless.@wifi-iface[${j}].device)" = "${d}" ]; then
				WIfaceAP=${j}
				break
			fi
		done
	done
	_applog "STA network interface is ${WIface}"
	_applog "Detected STA config in wifi-iface ${WIfaceSTA}"
	[ -n "${WIfaceAP}" ] && \
		_applog "Detected AP config in wifi-iface ${WIfaceAP}" || \
		_applog "Non standard AP+STA configuration"

	CfgSsids=""
	CfgSsidsCnt=0
	local n=0 ssid
	while [ $((n++)) ]; do
		eval ssid=\"\${net${n}_ssid:-}\" && \
		[ -n "${ssid}" ] || \
			break
		CfgSsids="${CfgSsids:+"${CfgSsids}${LF}"}${ssid}"
		CfgSsidsCnt=${n}
	done
	if [ ${CfgSsidsCnt} -eq 0 ]; then
		WwanSsid="$(uci -q get wireless.@wifi-iface[${WIfaceSTA}].ssid)" || :
		if [ -z "${WwanSsid}" ]; then
			_log "Invalid configuration. No Hotspots specified. Exiting"
			exit 1
		fi
		CfgSsids="${WwanSsid}"
		net1_ssid="${WwanSsid}"
		CfgSsidsCnt=1
	fi
	if [ -n "$(echo "${CfgSsids}" | sort | uniq -d)" ]; then
		_log "Invalid configuration. Duplicate Hotspot's SSIDs. Exiting"
		exit 1
	fi

	NetworkRestarted=0
	WwanErr=0
	ScanRequest=${CfgSsidsCnt}
	ConnectingTo=0
	ConnAttempts=1
	Status=0
	AddStatMsg "Configuration reloaded"
	ScanRequested
}

IsWanConnected() {
	local status
	status="$(cat "/sys/class/net/${IfaceWan}/operstate" 2> /dev/null)" && \
	[ -n "${status}" -a "${status}" != "down" ]
}

IsWwanConnected() {
	local ssid="${1:-"\"${WwanSsid}\""}"
	[ "${WwanDisabled}" != 1 ] && \
	IsWifiActive "${ssid}" && \
	sleep 5 && \
	IsWifiActive "${ssid}"
}

MustScan() {
	[ ${ScanRequest} -le 0 -a "${ScanAuto}" != "allways" ] || \
		return 0
	[ -n "${ScanAuto}" ] && ! IsWanConnected
}

Scanning() {
	local err i=5
	while [ $((i--)) -gt 0 ]; do
		sleep 1
		! err="$(iw "${WIface}" scan 3>&2 2>&1 1>&3 3>&-)" 2>&1 || \
			return 0
		[ -z "${Debug}" ] || \
			_applog "${err}"
		[ ${i} -le 2 ] && \
		echo "${err}" | grep -qse 'command failed: Network is down' || \
			continue
		_log "Error: Can't scan wifi, restarting the network"
		/etc/init.d/network restart
		sleep 20
		WatchWifi 20
	done
	_log "Serious error: Can't scan wifi for access points"
	return 1
}

ActiveSsidNbr() {
	echo "${CfgSsids}" | \
	awk -v ssid="${WwanSsid}" \
		'$0 == ssid {n = NR; exit}
		END{print n+0; exit (n+0 == 0)}'
}

CheckConn() {
	local s w
	[ "${Debug}" = "xtrace" ] || \
		exec > /dev/null 2>&1
	if [ -n "${CheckSrvr}" ]; then
		if w="$(which wget)" && \
		s="$(ifconfig "${WIface}" | \
		awk '$1 == "inet" {print $2; rc=-1; exit}
		END{exit rc+1}')"; then
			"${w}" --spider -T ${PingWait} --no-check-certificate \
				--bind-address "${s##"addr:"}" "${CheckAddr}"
		else
			echo "GET ${CheckAddr} HTTP/1.0"$'\n\n' | \
				nc "${CheckSrvr}" 80
		fi
	else
		ping -4 -W ${PingWait} -c 3 -I "${WIface}" "${CheckAddr}"
	fi
}

CheckConnectivity() {
	local delay=20 check rc s
	Interval=${SleepScanAuto}
	eval check=\"\${net${ConnectingTo}_check:-}\" && \
	[ -n "${check}" ] || \
		return 0
	while [ $((delay--)) -gt 0 ]; do
		sleep 1
		if [ -z "${Gateway}" ]; then
			Gateway="$(ip -4 route show default dev "${WIface}" | \
			awk '$1 == "default" {print $3; rc=-1; exit}
			END{exit rc+1}')" || \
				continue
		fi
		Interval=${Sleep}
		[ -n "${CheckAddr}" ] || \
			if CheckSrvr="$(echo "${check}" | \
			sed -nre '\|^http[s]?://([^/]+).*| s||\1|p')" && \
			[ -n "${CheckSrvr}" ]; then
				CheckAddr="${check}"
			else
				CheckAddr="$(echo "${check}" | \
				sed -nre '\|^([[:digit:]]+[.]){3}[[:digit:]]+$|p')" && \
				[ -n "${CheckAddr}" ] || \
				CheckAddr="${Gateway}"
			fi
		rc=0
		CheckConn &
		wait $((PidCheckConn=${!})) || \
			rc="${?}"
		PidCheckConn=""
		[ ${rc} -le 127 ] || \
			return 0
		[ ${rc} -eq 0 ] || \
			break
		if [ ${Status} -eq ${CONNECTED} -a ${NetworkAttempts} -eq 1 ]; then
			[ -z "${Debug}" ] || \
				_applog "Connectivity of ${ConnectingTo}:'${WwanSsid}'" \
				"to ${CheckAddr} has been verified"
		else
			NetworkAttempts=1
			_log "Connectivity of ${ConnectingTo}:'${WwanSsid}'" \
				"to ${CheckAddr} has been verified"
			[ -z "${StatMsgs}" ] || \
				AddStatMsg "Connectivity of ${ConnectingTo}:'${WwanSsid}'" \
					"to ${CheckAddr} has been verified"
		fi
		return 0
	done
	[ -n "${Gateway}" ] || \
		_log "Serious Error: There is no default route" \
			"for interface ${WIface}"
	_log "Warning: ${NetworkAttempts} connectivity failures" \
		"on ${ConnectingTo}:'${WwanSsid}'"
	if [ ${BlackListNetwork} -gt 0 ] && \
	[ ${NetworkAttempts} -ge ${BlackListNetwork} ]; then
		WwanDisable
		HotspotBlackList ${ConnectingTo} "network" "${BlackListNetworkExpires}"
		_log "Reason: ${NetworkAttempts} connectivity failures" \
			"on ${ConnectingTo}:'${WwanSsid}'"
		Status=${DISABLING}
		ScanRequest=1
		ConnectingTo=0
		return 1
	fi
	[ $((NetworkAttempts++)) ]
}

DoScan() {
	local ssid blacklisted hidden scanned found_hidden n i blacklistexp

	if ! MustScan; then
		[ -z "${Debug}" ] || \
			_applog "Must not scan"
		return 1
	fi

	[ -z "${Debug}" ] || \
		_applog "DoScan - Scanning"

	scanned="$(Scanning | \
	sed -nre '\|^[[:blank:]]+(SSID: .*)$| s||\1|p')" && \
	[ -n "${scanned}" ] || \
		return 1
	found_hidden="$(echo "${scanned}" | grep -sx -m 1 -e 'SSID: ')" || :

	n="$(ActiveSsidNbr)" || :
	[ $((n++)) -lt ${CfgSsidsCnt} ] || \
		n=1

	i=${n}
	while :; do
		eval ssid=\"\${net${i}_ssid:-}\" && \
		[ -n "${ssid}" ] || \
			break

		eval hidden=\"\${net${i}_hidden:-}\" || :
		if [ "${hidden}" = "y" -a -n "${found_hidden}" ] || \
		( [ -n "${hidden}" -a "${hidden}" != "y" ] && \
			echo "${scanned}" | grep -qsxF "SSID: ${hidden}" ) || \
		echo "${scanned}" | grep -qsxF "SSID: ${ssid}"; then
			eval blacklisted=\"\${net${i}_blacklisted:-}\" || :
			if [ -z "${blacklisted}" ]; then
				echo "${i}"
				return 0
			fi
			_applog "Not selecting blacklisted hotspot ${i}:'${ssid}'"
		fi
		[ $((i++)) -lt ${CfgSsidsCnt} ] || \
			i=1
		[ ${i} -ne ${n} ] || \
			break
	done
	[ -z "${Debug}" ] || \
		_applog "DoScan: No Hotspots available"
	return 1
}

WwanDisable() {
	_log "Disabling wireless device for hotspot ${ConnectingTo}:'${WwanSsid}'"
	uci set wireless.@wifi-iface[${WIfaceSTA}].disabled=1
	WwanDisabled=1
	uci commit wireless
	wifi down
	wifi up
	WatchWifi &
	NoSleep="y"
}

WifiStatus() {
	# constants
	readonly LF=$'\n' DISABLING=1 CONNECTING=2 CONNECTED=3 DISCONNECTED=4
	# internal variables, daemon scope
	local CfgSsids CfgSsidsCnt n IfaceWan WwanSsid WwanDisabled
	local ScanRequest WwanErr Status=0 StatMsgs="" Interval NoSleep
	local ConnectingTo=0 ConnAttempts=1 NetworkAttempts
	local PidDaemon="${$}"
	local PidSleep="" PidCheckConn="" Gateway CheckAddr CheckSrvr
	local NetworkRestarted=0
	local WIface WIfaceAP WIfaceSTA

	trap '_exit' EXIT

	LoadConfig || exit 1
	NoSleep="y"
	Interval=${Sleep}

	trap 'LoadConfig' HUP
	trap 'ScanRequested' USR1
	trap 'ListStatus' USR2

	while _sleep; do
		BlackListExpired
		WwanDisabled="$(uci -q get wireless.@wifi-iface[${WIfaceSTA}].disabled)" || :
		WwanSsid="$(uci -q get wireless.@wifi-iface[${WIfaceSTA}].ssid)" || :
		if IsWwanConnected; then
			NetworkRestarted=0
			WwanErr=0
			if [ ${ConnectingTo} -eq 0 ]; then
				ConnectingTo="$(ActiveSsidNbr)" || \
					_log "Warning: STA is connected to a non-configured" \
						"hotspot '${WwanSsid}'"
			fi
			if [ ${Status} -ne ${CONNECTED} ]; then
				_log "Hotspot is connected to ${ConnectingTo}:'${WwanSsid}'"
				AddStatMsg "Hotspot is connected to ${ConnectingTo}:'${WwanSsid}'"
				NetworkAttempts=1
				Gateway=""
				CheckAddr=""
				if CheckConnectivity; then
					Status=${CONNECTED}
					ScanRequest=0
				fi
			else
				[ -z "${Debug}" ] || \
					_applog "Hotspot is already connected to" \
						"${ConnectingTo}:'${WwanSsid}'"
				[ -z "${StatMsgs}" ] || \
					AddStatMsg "Hotspot is already connected to" \
						"${ConnectingTo}:'${WwanSsid}'"
				CheckConnectivity || :
			fi
			continue
		fi
		if [ ${NetworkRestarted} -gt 0 ]; then
			[ $((NetworkRestarted--)) ]
			continue
		fi
		if IsWwanConnected "unknown"; then
			WwanDisable
			if [ ${Status} -eq ${CONNECTED} ]; then
				_log "Reason: Lost connection ${ConnectingTo}:'${WwanSsid}'"
				AddStatMsg "Lost connection ${ConnectingTo}:'${WwanSsid}'"
				ConnectingTo=0
			else
				if [ ${Status} -eq ${DISABLING} ]; then
					[ -z "${Debug}" ] || \
						_applog "Disabling wireless device for Hotspot, Again ?"
					[ -z "${StatMsgs}" ] || \
						AddStatMsg "Disabling wireless device for Hotspot, Again ?"
				fi
				_log "Reason: ${ConnAttempts} unsuccessful connection" \
					"to ${ConnectingTo}:'${WwanSsid}'"
				AddStatMsg "${ConnAttempts} unsuccessful connection" \
					"to ${ConnectingTo}:'${WwanSsid}'"
				if [ ${ConnectingTo} -gt 0 ] && \
				[ ${BlackList} -gt 0 ] && \
				[ ${ConnAttempts} -ge ${BlackList} ]; then
					HotspotBlackList ${ConnectingTo} "connect" "${BlackListExpires}"
				fi
				[ $((ConnAttempts++)) ]
			fi
			Status=${DISABLING}
			ScanRequest=1
			Interval=${Sleep}
			continue
		fi
		if n="$(DoScan)"; then
			local ssid
			eval ssid=\"\${net${n}_ssid:-}\" || :
			[ -z "${Debug}" ] || \
				_applog "DoScan selected ${n}:'${ssid}'"
			if [ ${ConnectingTo} -ne ${n} ]; then
				ConnectingTo=${n}
				ConnAttempts=1
			fi
			if [ "${ssid}" != "${WwanSsid}" ]; then
				local encrypt key
				eval encrypt=\"\${net${n}_encrypt:-}\" || :
				eval key=\"\${net${n}_key:-}\" || :
				WwanErr=0
				_log "Hotspot '${ssid}' found. Applying settings..."
				uci set wireless.@wifi-iface[${WIfaceSTA}].ssid="${ssid}"
				uci set wireless.@wifi-iface[${WIfaceSTA}].encryption="${encrypt}"
				uci set wireless.@wifi-iface[${WIfaceSTA}].key="${key}"
				WwanSsid="${ssid}"
				[ "${WwanDisabled}" != 1 ] || \
					uci set wireless.@wifi-iface[${WIfaceSTA}].disabled=0
				uci commit wireless
				sleep 1
				/etc/init.d/network restart
				NetworkRestarted=2
				_log "Connecting to ${ConnectingTo}:'${WwanSsid}'..."
				AddStatMsg "Connecting to ${ConnectingTo}:'${WwanSsid}'..."
				WatchWifi 20 &
			elif [ "${WwanDisabled}" = 1 ]; then
				uci set wireless.@wifi-iface[${WIfaceSTA}].disabled=0
				uci commit wireless
				wifi down
				wifi up
				_log "Enabling Hotspot client interface to" \
					"${ConnectingTo}:'${WwanSsid}'..."
				AddStatMsg "Enabling Hotspot client interface to" \
					"${ConnectingTo}:'${WwanSsid}'..."
				WatchWifi &
			else
				_applog "Hotspot client interface to" \
					"${ConnectingTo}:'${WwanSsid}' is already enabled"
				[ -z "${StatMsgs}" ] || \
					AddStatMsg "Hotspot client interface to" \
					"${ConnectingTo}:'${WwanSsid}' is already enabled"
			fi
			Status=${CONNECTING}
			if [ $((WwanErr++)) -gt ${CfgSsidsCnt} ]; then
				Interval=${SleepScanAuto}
				ScanRequest=0
				_log "Error: can't connect to Hotspots," \
					"probably configuration is not correct"
				AddStatMsg "Error: can't connect to Hotspots," \
					"probably configuration is not correct"
			else
				Interval=${Sleep}
			fi
			[ ${ScanRequest} -le 0 ] || \
				[ $((ScanRequest--)) ]
			continue
		fi
		WwanErr=0
		if [ ${Status} -ne ${DISCONNECTED} ]; then
			_log "A Hotspot is not available"
			AddStatMsg "A Hotspot is not available"
			Status=${DISCONNECTED}
		else
			[ -z "${StatMsgs}" ] || \
				AddStatMsg "A Hotspot is not available"
		fi
		if [ "${WwanDisabled}" != 1 ]; then
			Interval=${Sleep}
		elif [ -n "${ScanAuto}" ] && \
		! IsWanConnected; then
			Interval=${SleepDsc}
		else
			Interval=${SleepScanAuto}
		fi
		[ ${ScanRequest} -le 0 ] || \
			[ $((ScanRequest--)) ]
	done
}

set -o errexit -o nounset -o pipefail
NAME="$(basename "${0}")"
case "${1:-}" in
start)
	WifiStatus
	;;
*)
	echo "Wrong arguments" >&2
	exit 1
	;;
esac
