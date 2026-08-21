#!/usr/bin/env bash
# =====================================================================
#  lib/common.sh - gemeinsame Funktionen aller Gateway-Scripts
#
#  Diese Datei wird per "source" eingebunden und startet selbst nichts.
#
#  Installiert nach: /opt/gsm-gateway/lib/common.sh
# =====================================================================
# Viele Variablen hier werden erst von den einbindenden Scripts benutzt.
# shellcheck disable=SC2034

# Mehrfaches Einbinden verhindern.
if [ -n "${GG_COMMON_LOADED:-}" ]; then
	return 0
fi
GG_COMMON_LOADED=1

# ---------------------------------------------------------------------
# Feste Pfade - siehe docs/PATHS.md
# ---------------------------------------------------------------------
GG_PREFIX="${GG_PREFIX:-/opt/gsm-gateway}"
GG_ETC_DIR="${GG_ETC_DIR:-/etc/gsm-gateway}"
GG_CONFIG_FILE="${GG_CONFIG_FILE:-${GG_ETC_DIR}/gateway.conf}"
GG_SECRET_DIR="${GG_SECRET_DIR:-${GG_ETC_DIR}/secrets}"
GG_LOG_DIR="${GG_LOG_DIR:-/var/log/gsm-gateway}"
GG_STATE_DIR="${GG_STATE_DIR:-/var/lib/gsm-gateway}"
GG_STEP_DIR="${GG_STEP_DIR:-${GG_STATE_DIR}/steps}"
GG_FACT_DIR="${GG_FACT_DIR:-${GG_STATE_DIR}/facts}"
GG_RUN_DIR="${GG_RUN_DIR:-/run/gsm-gateway}"
GG_BACKUP_DIR="${GG_BACKUP_DIR:-/var/backups/gsm-gateway}"

GG_COMPLETE_MARKER="${GG_STATE_DIR}/setup-complete"
GG_ABANDONED_MARKER="${GG_STATE_DIR}/setup-abandoned"
GG_ATTEMPT_FILE="${GG_STATE_DIR}/install-attempts"
GG_STATUS_FILE="${GG_STATE_DIR}/install-status"

GG_INSTALL_LOG="${GG_LOG_DIR}/install.log"
GG_ERROR_LOG="${GG_LOG_DIR}/error.log"
GG_HARDWARE_LOG="${GG_LOG_DIR}/hardware.log"
GG_BLUETOOTH_LOG="${GG_LOG_DIR}/bluetooth.log"
GG_ASTERISK_LOG="${GG_LOG_DIR}/asterisk.log"
GG_STATUS_LOG="${GG_LOG_DIR}/status.log"

# Aktuelles Logziel. Jedes Script setzt das per gg_log_target.
GG_LOG_FILE="${GG_LOG_FILE:-${GG_INSTALL_LOG}}"

# Name des aktuellen Installationsschritts - fuer die Fehlermeldung.
GG_CURRENT_STEP="${GG_CURRENT_STEP:-(kein Schritt)}"

# ---------------------------------------------------------------------
# Farben - nur wenn wirklich ein Terminal dranhaengt
# ---------------------------------------------------------------------
if [ -t 1 ] && [ -z "${GG_NO_COLOR:-}" ]; then
	GG_C_RESET=$'\033[0m'
	GG_C_RED=$'\033[1;31m'
	GG_C_GREEN=$'\033[1;32m'
	GG_C_YELLOW=$'\033[1;33m'
	GG_C_BLUE=$'\033[1;34m'
	GG_C_BOLD=$'\033[1m'
else
	GG_C_RESET=""
	GG_C_RED=""
	GG_C_GREEN=""
	GG_C_YELLOW=""
	GG_C_BLUE=""
	GG_C_BOLD=""
fi

# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------

# gg_log_target <logdatei>
# Legt fest, in welche Datei gg_info/gg_warn/... zusaetzlich schreiben.
gg_log_target() {
	GG_LOG_FILE="$1"
	gg_ensure_dirs
	: >>"$GG_LOG_FILE"
}

gg_timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

# Interne Schreibfunktion: Zeile auf stdout und ins Logfile.
# _gg_emit <level> <farbe> <text...>
_gg_emit() {
	local level="$1" color="$2"
	shift 2
	local line
	line="[$(gg_timestamp)] [${level}] $*"
	printf '%s%s%s\n' "$color" "$line" "$GG_C_RESET"
	if [ -n "${GG_LOG_FILE:-}" ] && [ -w "$(dirname "$GG_LOG_FILE")" ]; then
		printf '%s\n' "$line" >>"$GG_LOG_FILE"
	fi
}

gg_info() { _gg_emit "INFO " "" "$@"; }
gg_ok()   { _gg_emit "OK   " "$GG_C_GREEN" "$@"; }
gg_warn() { _gg_emit "WARN " "$GG_C_YELLOW" "$@"; }

# Fehler landen zusaetzlich immer in error.log.
gg_error() {
	_gg_emit "ERROR" "$GG_C_RED" "$@" >&2
	if [ -w "$(dirname "$GG_ERROR_LOG")" ] 2>/dev/null; then
		printf '[%s] [ERROR] [%s] %s\n' "$(gg_timestamp)" "$GG_CURRENT_STEP" "$*" >>"$GG_ERROR_LOG"
	fi
}

# Ueberschrift fuer einen Abschnitt.
gg_headline() {
	printf '\n%s=======================================================%s\n' "$GG_C_BLUE" "$GG_C_RESET"
	printf '%s %s%s\n' "$GG_C_BOLD" "$*" "$GG_C_RESET"
	printf '%s=======================================================%s\n' "$GG_C_BLUE" "$GG_C_RESET"
	if [ -n "${GG_LOG_FILE:-}" ] && [ -w "$(dirname "$GG_LOG_FILE")" ]; then
		{
			printf '\n=======================================================\n'
			printf ' %s\n' "$*"
			printf '=======================================================\n'
		} >>"$GG_LOG_FILE"
	fi
}

# ---------------------------------------------------------------------
# Fehlerbehandlung
#
# Grundsatz (Anforderung 24): Fehler werden NICHT verschluckt.
# Kein "command || true" fuer Dinge, die funktionieren muessen.
# ---------------------------------------------------------------------

# gg_fail_banner <schritt> <fehlermeldung>
gg_fail_banner() {
	local step="$1" msg="$2"
	printf '\n%s=======================================================%s\n' "$GG_C_RED" "$GG_C_RESET"
	printf '%sINSTALLATION FAILED%s\n' "$GG_C_RED" "$GG_C_RESET"
	printf '%s=======================================================%s\n' "$GG_C_RED" "$GG_C_RESET"
	printf '\nSchritt:\n%s\n' "$step"
	printf '\nFehler:\n%s\n' "$msg"
	printf '\nLog:\n%s\n' "$GG_ERROR_LOG"
	printf '\n%s=======================================================%s\n\n' "$GG_C_RED" "$GG_C_RESET"
}

# gg_die <text...> - Fehler melden und kontrolliert abbrechen.
gg_die() {
	gg_error "$@"
	gg_set_status "FAILED" "$GG_CURRENT_STEP: $*"
	gg_fail_banner "$GG_CURRENT_STEP" "$*"
	exit 1
}

# ERR-Trap: greift bei jedem unbehandelten Fehlschlag unter "set -e".
_gg_on_err() {
	local rc="$1" line="$2" cmd="$3"
	gg_error "Befehl fehlgeschlagen (Exit ${rc}) in Zeile ${line}: ${cmd}"
	gg_set_status "FAILED" "$GG_CURRENT_STEP: Exit ${rc} bei '${cmd}'"
	gg_fail_banner "$GG_CURRENT_STEP" "Befehl '${cmd}' endete mit Exit-Code ${rc} (Zeile ${line})"
	exit "$rc"
}

# gg_strict - strikten Modus samt ERR-Trap aktivieren.
gg_strict() {
	set -Eeuo pipefail
	trap '_gg_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

# ---------------------------------------------------------------------
# Umgebung
# ---------------------------------------------------------------------

gg_require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		gg_error "Dieses Script muss als root laufen. Bitte mit 'sudo' erneut starten."
		exit 1
	fi
}

gg_ensure_dirs() {
	mkdir -p "$GG_LOG_DIR" "$GG_STATE_DIR" "$GG_STEP_DIR" "$GG_FACT_DIR" "$GG_ETC_DIR"
	chmod 0755 "$GG_LOG_DIR" "$GG_STATE_DIR"
	if [ ! -d "$GG_SECRET_DIR" ]; then
		mkdir -p "$GG_SECRET_DIR"
	fi
	chmod 0700 "$GG_SECRET_DIR"
}

# Konfiguration einlesen. Fehlt sie, gelten die Vorgaben aus dieser Datei.
gg_load_config() {
	# Vorgaben - werden von /etc/gsm-gateway/gateway.conf ueberschrieben.
	GG_ASTERISK_BRANCH="${GG_ASTERISK_BRANCH:-22}"
	GG_ASTERISK_VERSION="${GG_ASTERISK_VERSION:-current}"
	GG_ASTERISK_MIRROR="${GG_ASTERISK_MIRROR:-https://downloads.asterisk.org/pub/telephony/asterisk}"
	GG_ASTERISK_GPG_FPR="${GG_ASTERISK_GPG_FPR:-F2FC93DB7587BD1FB49E045A5D984BE337191CE7}"
	GG_ASTERISK_KEYSERVER="${GG_ASTERISK_KEYSERVER:-hkps://keys.openpgp.org}"
	GG_ASTERISK_FORCE_SOURCE="${GG_ASTERISK_FORCE_SOURCE:-no}"
	GG_BUILD_JOBS="${GG_BUILD_JOBS:-auto}"
	GG_BUILD_SWAP_MB="${GG_BUILD_SWAP_MB:-2048}"
	GG_BUILD_MIN_DISK_MB="${GG_BUILD_MIN_DISK_MB:-3500}"
	GG_BT_ADAPTER="${GG_BT_ADAPTER:-usb}"
	GG_BT_NAME="${GG_BT_NAME:-gsm-gateway}"
	GG_BT_CLASS="${GG_BT_CLASS:-0x200404}"
	GG_BT_SCAN_SECONDS="${GG_BT_SCAN_SECONDS:-20}"
	GG_MOBILE_ID="${GG_MOBILE_ID:-iphone}"
	GG_MOBILE_CONTEXT="${GG_MOBILE_CONTEXT:-from-mobile}"
	GG_SIP_EXTENSION="${GG_SIP_EXTENSION:-1001}"
	GG_SIP_PORT="${GG_SIP_PORT:-5060}"
	GG_RTP_START="${GG_RTP_START:-10000}"
	GG_RTP_END="${GG_RTP_END:-10100}"
	GG_LAN_NETWORKS="${GG_LAN_NETWORKS:-192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 169.254.0.0/16}"
	GG_SIP_PASSWORD_LENGTH="${GG_SIP_PASSWORD_LENGTH:-24}"
	GG_BLOCKED_PREFIXES="${GG_BLOCKED_PREFIXES:-0900 0901 0906 00881 00882 00883 00870 00871 00872 00873}"
	GG_MAX_OUTGOING_CALLS="${GG_MAX_OUTGOING_CALLS:-1}"
	GG_WATCHDOG_ENABLE="${GG_WATCHDOG_ENABLE:-yes}"
	GG_CDR_ENABLE="${GG_CDR_ENABLE:-yes}"
	GG_CDR_FILE="${GG_CDR_FILE:-/var/log/asterisk/cdr-csv/Master.csv}"
	GG_WEB_SHOW_CALLS="${GG_WEB_SHOW_CALLS:-yes}"
	GG_WEB_CALLS_MASK="${GG_WEB_CALLS_MASK:-0}"
	GG_WEB_CALLS_LIMIT="${GG_WEB_CALLS_LIMIT:-10}"
	GG_WEB_ENABLE="${GG_WEB_ENABLE:-yes}"
	GG_WEB_PORT="${GG_WEB_PORT:-80}"
	GG_TIMEZONE="${GG_TIMEZONE:-Europe/Zurich}"
	GG_LOCALE="${GG_LOCALE:-de_CH.UTF-8}"
	GG_HOSTNAME="${GG_HOSTNAME:-gsm-gateway}"
	GG_FULL_UPGRADE="${GG_FULL_UPGRADE:-yes}"
	GG_MAX_INSTALL_ATTEMPTS="${GG_MAX_INSTALL_ATTEMPTS:-5}"

	if [ -r "$GG_CONFIG_FILE" ]; then
		# shellcheck source=/dev/null
		. "$GG_CONFIG_FILE"
	fi
}

# ---------------------------------------------------------------------
# Schritt-Status (Wiederaufnahme nach Fehlschlag)
# ---------------------------------------------------------------------

gg_step_is_done() {
	[ -f "${GG_STEP_DIR}/$1.done" ]
}

gg_step_mark_done() {
	mkdir -p "$GG_STEP_DIR"
	printf '%s\n' "$(gg_timestamp)" >"${GG_STEP_DIR}/$1.done"
}

gg_step_reset() {
	rm -f "${GG_STEP_DIR}/$1.done"
}

# gg_set_status <RUNNING|OK|FAILED> <text>
gg_set_status() {
	mkdir -p "$GG_STATE_DIR"
	printf '%s\n%s\n%s\n' "$1" "$(gg_timestamp)" "${2:-}" >"$GG_STATUS_FILE"
}

gg_get_status() {
	if [ -r "$GG_STATUS_FILE" ]; then
		head -n1 "$GG_STATUS_FILE"
	else
		printf 'UNKNOWN\n'
	fi
}

# ---------------------------------------------------------------------
# "Facts" - ermittelte Werte, die spaetere Scripts wiederverwenden
# (z.B. die tatsaechliche MAC des Bluetooth-Adapters).
# ---------------------------------------------------------------------

gg_fact_set() {
	mkdir -p "$GG_FACT_DIR"
	printf '%s' "$2" >"${GG_FACT_DIR}/$1"
}

gg_fact_get() {
	if [ -r "${GG_FACT_DIR}/$1" ]; then
		cat "${GG_FACT_DIR}/$1"
	else
		printf '%s' "${2:-}"
	fi
}

gg_fact_exists() {
	[ -s "${GG_FACT_DIR}/$1" ]
}

# ---------------------------------------------------------------------
# APT-Hilfen
# ---------------------------------------------------------------------

# Wartet, bis kein anderer apt/dpkg-Prozess mehr laeuft
# (unattended-upgrades startet auf Raspberry Pi OS beim Boot mit).
# gg_apt_wait [maximale-wartezeit-sekunden]
# shellcheck disable=SC2120
gg_apt_wait() {
	local waited=0 max="${1:-600}"
	while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
		fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ||
		fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
		if [ "$waited" -ge "$max" ]; then
			gg_error "APT ist seit ${max}s durch einen anderen Prozess gesperrt."
			return 1
		fi
		if [ "$((waited % 30))" -eq 0 ]; then
			gg_info "Warte auf Freigabe der APT-Sperre ... (${waited}s)"
		fi
		sleep 5
		waited=$((waited + 5))
	done
	return 0
}

gg_apt_update() {
	gg_apt_wait || return 1
	gg_info "apt-get update"
	DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3
}

# gg_apt_install <paket> [paket ...]
gg_apt_install() {
	[ "$#" -gt 0 ] || return 0
	gg_apt_wait || return 1
	gg_info "Installiere Pakete: $*"
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		-o Acquire::Retries=3 \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		"$@"
}

# Ist ein Paket ueberhaupt installierbar (Kandidat vorhanden)?
gg_apt_has_candidate() {
	local pkg="$1" cand
	cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
	[ -n "$cand" ] && [ "$cand" != "(none)" ]
}

gg_pkg_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# ---------------------------------------------------------------------
# System- und Netzwerk-Erkennung
# ---------------------------------------------------------------------

gg_pi_model() {
	if [ -r /proc/device-tree/model ]; then
		tr -d '\0' </proc/device-tree/model
	elif [ -r /sys/firmware/devicetree/base/model ]; then
		tr -d '\0' </sys/firmware/devicetree/base/model
	else
		printf 'unbekannt'
	fi
}

gg_os_id() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		( . /etc/os-release && printf '%s' "${ID:-unknown}" )
	else
		printf 'unknown'
	fi
}

gg_os_codename() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		( . /etc/os-release && printf '%s' "${VERSION_CODENAME:-unknown}" )
	else
		printf 'unknown'
	fi
}

gg_os_pretty() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		( . /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}" )
	else
		printf 'unknown'
	fi
}

# Standard-Netzwerkschnittstelle (die mit der Default-Route).
gg_default_iface() {
	ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Primaere IPv4-Adresse des Systems.
gg_primary_ip() {
	local iface
	iface="$(gg_default_iface)"
	if [ -n "$iface" ]; then
		ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
			awk '{split($4,a,"/"); print a[1]; exit}'
	fi
}

gg_default_gateway() {
	ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

# DNS-Server aus resolv.conf bzw. resolvectl.
gg_dns_servers() {
	if command -v resolvectl >/dev/null 2>&1; then
		resolvectl dns 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+$' | sort -u | tr '\n' ' '
	elif [ -r /etc/resolv.conf ]; then
		awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf
	fi
}

# Erreicht das System das Internet? (kein DNS noetig)
gg_have_internet() {
	local host
	for host in 1.1.1.1 9.9.9.9 8.8.8.8; do
		if ping -c1 -W3 "$host" >/dev/null 2>&1; then
			return 0
		fi
	done
	# Manche Netze blocken ICMP - dann per TCP gegen die Paketquelle testen.
	if command -v getent >/dev/null 2>&1 && getent hosts deb.debian.org >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

gg_dns_works() {
	local name
	for name in deb.debian.org downloads.asterisk.org raspbian.raspberrypi.com; do
		if getent hosts "$name" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

# ---------------------------------------------------------------------
# Bluetooth-Hilfen
# ---------------------------------------------------------------------

# Ist das eine gueltige MAC-Adresse (AA:BB:CC:DD:EE:FF)?
# Wichtig, weil Geraetenamen aus der Bluetooth-Umgebung stammen und
# damit von fremden Geraeten beeinflusst werden koennen. Was in eine
# Konfigurationsdatei geschrieben wird, muss geprueft sein.
gg_is_mac() {
	case "$(printf '%s' "${1:-}" | tr 'a-f' 'A-F')" in
	[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F]:[0-9A-F][0-9A-F])
		return 0
		;;
	*) return 1 ;;
	esac
}

# Ist das ein gueltiger HCI-Geraetename (hci0, hci1, ...)?
gg_is_hci_name() {
	case "${1:-}" in
	hci) return 1 ;;
	hci*[!0-9]*) return 1 ;;
	hci*) return 0 ;;
	*) return 1 ;;
	esac
}

# Alle vorhandenen HCI-Adapter (hci0 hci1 ...).
gg_bt_adapters() {
	local dev
	for dev in /sys/class/bluetooth/hci*; do
		[ -e "$dev" ] || continue
		basename "$dev"
	done
}

# Ist der Adapter per USB angeschlossen?
gg_bt_is_usb() {
	local hci="$1" link
	link="$(readlink -f "/sys/class/bluetooth/${hci}/device" 2>/dev/null)" || return 1
	case "$link" in
	*/usb*) return 0 ;;
	*) return 1 ;;
	esac
}

# MAC-Adresse eines HCI-Adapters (aus sysfs - kein hciconfig noetig).
gg_bt_address() {
	local hci="$1"
	if [ -r "/sys/class/bluetooth/${hci}/address" ]; then
		tr 'a-f' 'A-F' <"/sys/class/bluetooth/${hci}/address"
	fi
}

# USB-Vendor:Product des Adapters, z.B. "0b05:190e".
gg_bt_usb_id() {
	local hci="$1" dir
	dir="$(readlink -f "/sys/class/bluetooth/${hci}/device" 2>/dev/null)" || return 1
	# Vom Interface aus nach oben laufen, bis idVendor auftaucht.
	while [ -n "$dir" ] && [ "$dir" != "/" ]; do
		if [ -r "${dir}/idVendor" ] && [ -r "${dir}/idProduct" ]; then
			printf '%s:%s' "$(cat "${dir}/idVendor")" "$(cat "${dir}/idProduct")"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

# Waehlt den Adapter gemaess GG_BT_ADAPTER aus und gibt "hciX" zurueck.
gg_bt_select_adapter() {
	local want="${GG_BT_ADAPTER:-usb}" hci
	case "$want" in
	hci[0-9]*)
		if [ -e "/sys/class/bluetooth/${want}" ]; then
			printf '%s' "$want"
			return 0
		fi
		return 1
		;;
	[0-9A-Fa-f][0-9A-Fa-f]:*)
		for hci in $(gg_bt_adapters); do
			if [ "$(gg_bt_address "$hci")" = "$(printf '%s' "$want" | tr 'a-f' 'A-F')" ]; then
				printf '%s' "$hci"
				return 0
			fi
		done
		return 1
		;;
	usb | auto)
		for hci in $(gg_bt_adapters); do
			if gg_bt_is_usb "$hci"; then
				printf '%s' "$hci"
				return 0
			fi
		done
		if [ "$want" = "auto" ]; then
			for hci in $(gg_bt_adapters); do
				printf '%s' "$hci"
				return 0
			done
		fi
		return 1
		;;
	*)
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------
# Asterisk-Hilfen
# ---------------------------------------------------------------------

gg_asterisk_binary() {
	command -v asterisk 2>/dev/null || printf ''
}

gg_asterisk_version() {
	local bin
	bin="$(gg_asterisk_binary)"
	if [ -n "$bin" ]; then
		"$bin" -V 2>/dev/null | awk '{print $2}'
	fi
}

gg_asterisk_running() {
	local bin
	bin="$(gg_asterisk_binary)"
	[ -n "$bin" ] || return 1
	"$bin" -rx 'core show uptime' >/dev/null 2>&1
}

# gg_asterisk_cli <kommando> - gibt die Ausgabe zurueck, Exit 1 wenn
# Asterisk nicht laeuft.
gg_asterisk_cli() {
	local bin
	bin="$(gg_asterisk_binary)"
	[ -n "$bin" ] || return 1
	"$bin" -rx "$1" 2>/dev/null
}

gg_asterisk_module_dir() {
	local d
	for d in /usr/lib/asterisk/modules /usr/local/lib/asterisk/modules /usr/lib64/asterisk/modules; do
		if [ -d "$d" ]; then
			printf '%s' "$d"
			return 0
		fi
	done
	return 1
}

gg_chan_mobile_file() {
	local d
	d="$(gg_asterisk_module_dir)" || return 1
	if [ -f "${d}/chan_mobile.so" ]; then
		printf '%s' "${d}/chan_mobile.so"
		return 0
	fi
	return 1
}

# Welchen Konfigurationsdateinamen erwartet das installierte chan_mobile?
# Neuere Versionen bevorzugen chan_mobile.conf und lesen mobile.conf nur
# als Rueckfallebene.
gg_chan_mobile_conf_name() {
	local so
	if so="$(gg_chan_mobile_file)"; then
		if strings "$so" 2>/dev/null | grep -qx 'chan_mobile.conf'; then
			printf 'chan_mobile.conf'
			return 0
		fi
		if strings "$so" 2>/dev/null | grep -qx 'mobile.conf'; then
			printf 'mobile.conf'
			return 0
		fi
	fi
	printf 'chan_mobile.conf'
}

# ---------------------------------------------------------------------
# Sonstiges
# ---------------------------------------------------------------------

# Sichert eine Datei zeitgestempelt weg, bevor sie ueberschrieben wird.
# gg_backup_file <datei> <zielverzeichnis>
gg_backup_file() {
	local src="$1" dst_dir="$2" stamp
	[ -f "$src" ] || return 0
	stamp="$(date '+%Y-%m-%d-%H-%M-%S')"
	mkdir -p "$dst_dir"
	cp -a "$src" "${dst_dir}/$(basename "$src").${stamp}"
	gg_info "Backup: ${dst_dir}/$(basename "$src").${stamp}"
}

# Ersetzt @PLATZHALTER@ in einer Vorlage.
# Die eigentliche Arbeit macht lib/render-template.py - damit sind auch
# mehrzeilige Werte und Sonderzeichen (Passwoerter!) unproblematisch.
#
# gg_render_template [--mode 0640] [--env SCHLUESSEL] <vorlage> <ziel> NAME=WERT ...
#
# --env SCHLUESSEL nimmt den Wert aus GG_TPL_<SCHLUESSEL> statt von der
# Kommandozeile. Fuer Geheimnisse zwingend: /proc/<pid>/cmdline kann
# jeder lokale Benutzer lesen.
gg_render_template() {
	local opts=()
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mode | --env)
			opts+=("$1" "$2")
			shift 2
			;;
		*) break ;;
		esac
	done

	local tpl="$1" out="$2"
	shift 2
	if [ ! -r "$tpl" ]; then
		gg_error "Vorlage fehlt: $tpl"
		return 1
	fi
	if ! "${GG_PREFIX}/lib/render-template.py" ${opts[@]+"${opts[@]}"} "$tpl" "$out" "$@"; then
		gg_error "Vorlage ${tpl} konnte nicht nach ${out} gerendert werden."
		return 1
	fi
	return 0
}

# Zufaelliges starkes Passwort erzeugen.
# Enthaelt garantiert Gross-, Kleinbuchstaben, Ziffer und Sonderzeichen.
# Sonderzeichen bewusst eingeschraenkt: Asterisk-Konfigurationsdateien
# vertragen ; (Kommentar) und einige Shell-Zeichen schlecht.
gg_generate_password() {
	local len="${1:-24}" pw
	if [ "$len" -lt 12 ]; then
		len=12
	fi
	local upper='ABCDEFGHJKLMNPQRSTUVWXYZ'
	local lower='abcdefghijkmnpqrstuvwxyz'
	local digit='23456789'
	local special='!#%()*+,-.:=?@[]^_{}~'
	local all="${upper}${lower}${digit}${special}"
	local i
	pw=""
	pw+="$(_gg_pick "$upper")"
	pw+="$(_gg_pick "$lower")"
	pw+="$(_gg_pick "$digit")"
	pw+="$(_gg_pick "$special")"
	for ((i = 4; i < len; i++)); do
		pw+="$(_gg_pick "$all")"
	done
	# Reihenfolge mischen, damit die ersten vier Zeichen kein Muster sind.
	printf '%s' "$pw" | fold -w1 | shuf | tr -d '\n'
}

_gg_pick() {
	local set="$1" n idx
	n="${#set}"
	idx="$(od -An -N2 -tu2 </dev/urandom | tr -d ' ')"
	printf '%s' "${set:$((idx % n)):1}"
}

# Ist ein systemd-Dienst aktiv?
# stderr wird unterdrueckt, damit die Diagnosescripts auch dann sauber
# aussehen, wenn systemd gar nicht laeuft (z.B. im Container).
gg_service_active() {
	systemctl is-active --quiet "$1" 2>/dev/null
}

gg_service_enabled() {
	systemctl is-enabled --quiet "$1" 2>/dev/null
}
