#!/usr/bin/env bash
# =====================================================================
#  gateway-check.sh - Hardware- und Systemdiagnose
#
#  Sammelt alle Angaben, die man zur Fehlersuche braucht, zeigt sie an
#  und schreibt sie nach /var/log/gsm-gateway/hardware.log.
#
#  Aufruf:
#     gateway-check.sh            anzeigen und protokollieren
#     gateway-check.sh --quiet    nur protokollieren
#
#  Exit-Code 0 = alles Wesentliche in Ordnung
#            1 = mindestens ein Problem gefunden
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

# Absichtlich kein "set -e": diese Datei sammelt Informationen. Ein
# einzelnes fehlendes Werkzeug darf die Diagnose nicht abbrechen -
# stattdessen wird jedes erkannte Problem gezaehlt und am Ende gemeldet.
set -uo pipefail
gg_load_config

# Ohne root laesst sich nicht ueberall hinschreiben - dann wird nur
# angezeigt und nicht protokolliert.
if [ "$(id -u)" -eq 0 ]; then
	gg_ensure_dirs
fi
if [ -w "$GG_LOG_DIR" ]; then
	LOG_WRITABLE="yes"
	gg_log_target "$GG_HARDWARE_LOG"
else
	LOG_WRITABLE="no"
fi

QUIET="no"
if [ "${1:-}" = "--quiet" ]; then
	QUIET="yes"
fi
if [ "$QUIET" = "yes" ] && [ "$LOG_WRITABLE" = "no" ]; then
	printf 'gateway-check.sh --quiet braucht Schreibrechte auf %s (mit sudo starten).\n' "$GG_LOG_DIR" >&2
	exit 1
fi

PROBLEMS=0

out() {
	if [ "$QUIET" = "no" ]; then
		printf '%s\n' "$*"
	fi
	if [ "$LOG_WRITABLE" = "yes" ]; then
		printf '%s\n' "$*" >>"$GG_HARDWARE_LOG"
	fi
}

section() {
	out ""
	out "--- $* ---"
}

field() {
	# field <Beschriftung> <Wert>
	out "$(printf '%-22s %s' "$1:" "$2")"
}

problem() {
	PROBLEMS=$((PROBLEMS + 1))
	out "  ! $*"
}

# Ein Kommando protokollieren, ohne dass ein Fehlschlag das Script
# beendet - diese Datei sammelt Informationen, sie prueft nicht.
run() {
	local label="$1"
	shift
	section "$label"
	if ! command -v "$1" >/dev/null 2>&1; then
		out "($1 ist nicht installiert)"
		return 0
	fi
	if [ "$LOG_WRITABLE" = "yes" ]; then
		if ! "$@" >>"$GG_HARDWARE_LOG" 2>&1; then
			out "($* endete mit einem Fehler - Details im Log)"
		fi
	fi
	if [ "$QUIET" = "no" ]; then
		"$@" 2>&1 | sed 's/^/  /'
	fi
}

out ""
out "======================================================="
out " GSM -> SIP Gateway - Systemdiagnose"
out " $(gg_timestamp)"
out "======================================================="

# ---------------------------------------------------------------------
section "System"
# ---------------------------------------------------------------------
field "Raspberry-Pi-Modell" "$(gg_pi_model)"
field "Architektur" "$(uname -m)"
field "APT-Architektur" "$(dpkg --print-architecture 2>/dev/null || printf 'unbekannt')"
field "Kernel" "$(uname -r)"
field "Betriebssystem" "$(gg_os_pretty)"
field "OS-Codename" "$(gg_os_codename)"
field "Hostname" "$(hostname)"
field "Betriebszeit" "$(uptime -p 2>/dev/null || uptime)"
field "Zeitzone" "$(timedatectl show -p Timezone --value 2>/dev/null || printf 'unbekannt')"
field "Systemzeit" "$(date)"

CPU_MODEL="$(awk -F': ' '/^model name|^Model/ {print $2; exit}' /proc/cpuinfo)"
field "CPU" "${CPU_MODEL:-unbekannt} ($(nproc) Kerne)"
field "Arbeitsspeicher" "$(free -h | awk '/^Mem:/ {print $2" gesamt, "$7" verfuegbar"}')"
field "Swap" "$(free -h | awk '/^Swap:/ {print $2" gesamt, "$3" belegt"}')"
field "Wurzeldateisystem" "$(df -h / | awk 'NR==2 {print $2" gesamt, "$4" frei ("$5" belegt)"}')"

FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
if [ "${FREE_MB:-0}" -lt 500 ]; then
	problem "Nur noch ${FREE_MB} MB frei auf der SD-Karte."
fi

TEMP=""
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
	TEMP="$(awk '{printf "%.1f C", $1/1000}' /sys/class/thermal/thermal_zone0/temp)"
	field "CPU-Temperatur" "$TEMP"
fi
if command -v vcgencmd >/dev/null 2>&1; then
	THROTTLE="$(vcgencmd get_throttled 2>/dev/null || printf '')"
	if [ -n "$THROTTLE" ]; then
		field "Drosselung" "$THROTTLE"
		if [ "$THROTTLE" != "throttled=0x0" ]; then
			problem "Der Pi meldet Unterspannung oder Drosselung (${THROTTLE}). Original-Netzteil verwenden!"
		fi
	fi
fi

# ---------------------------------------------------------------------
section "Netzwerk"
# ---------------------------------------------------------------------
IFACE="$(gg_default_iface)"
IPADDR="$(gg_primary_ip)"
GWADDR="$(gg_default_gateway)"
field "Schnittstelle" "${IFACE:-keine}"
field "IP-Adresse" "${IPADDR:-keine}"
field "Standard-Gateway" "${GWADDR:-keines}"
field "DNS-Server" "$(gg_dns_servers)"

if [ -z "$IPADDR" ]; then
	problem "Keine IP-Adresse - Ethernet-Kabel und DHCP pruefen."
fi
if gg_have_internet; then
	field "Internetzugriff" "OK"
else
	field "Internetzugriff" "FEHLT"
	problem "Keine Internetverbindung."
fi
if gg_dns_works; then
	field "Namensaufloesung" "OK"
else
	field "Namensaufloesung" "FEHLT"
	problem "DNS funktioniert nicht."
fi

run "ip addr" ip addr
run "ip route" ip route

# ---------------------------------------------------------------------
section "USB-Geraete"
# ---------------------------------------------------------------------
run "lsusb" lsusb

# ---------------------------------------------------------------------
section "Bluetooth"
# ---------------------------------------------------------------------
ADAPTERS="$(gg_bt_adapters | tr '\n' ' ')"
field "Gefundene Adapter" "${ADAPTERS:-keine}"
if [ -z "${ADAPTERS// /}" ]; then
	problem "Kein Bluetooth-Adapter gefunden."
else
	for hci in $(gg_bt_adapters); do
		if gg_bt_is_usb "$hci"; then
			field "  ${hci}" "USB  MAC=$(gg_bt_address "$hci")  ID=$(gg_bt_usb_id "$hci" 2>/dev/null || printf 'unbekannt')"
		else
			field "  ${hci}" "intern  MAC=$(gg_bt_address "$hci")"
		fi
	done
fi
field "Ausgewaehlter Adapter" "$(gg_fact_get bt_adapter 'noch keiner')"
field "Adapter-MAC" "$(gg_fact_get bt_adapter_address 'unbekannt')"
field "Voice Setting" "$(gg_fact_get bt_voice_setting 'unbekannt')"

if gg_service_active bluetooth.service; then
	field "bluetooth.service" "laeuft"
else
	field "bluetooth.service" "laeuft NICHT"
	problem "bluetooth.service laeuft nicht."
fi

if command -v bluetoothctl >/dev/null 2>&1; then
	BLUEZ_VERSION="$(bluetoothctl --version 2>/dev/null | awk '{print $NF}')"
	field "BlueZ-Version" "${BLUEZ_VERSION:-unbekannt}"
fi

run "systemctl status bluetooth" systemctl status bluetooth.service --no-pager --lines=5
run "bluetoothctl show" bluetoothctl show
run "bluetoothctl list" bluetoothctl list
run "rfkill list" rfkill list

# ---------------------------------------------------------------------
section "Asterisk"
# ---------------------------------------------------------------------
AST_VERSION="$(gg_asterisk_version)"
field "Asterisk-Version" "${AST_VERSION:-nicht installiert}"
field "Installationsart" "$(gg_fact_get asterisk_install_method 'unbekannt')"
field "Modulverzeichnis" "$(gg_asterisk_module_dir 2>/dev/null || printf 'nicht gefunden')"

if [ -z "$AST_VERSION" ]; then
	problem "Asterisk ist nicht installiert."
else
	if CHAN_MOBILE="$(gg_chan_mobile_file)"; then
		field "chan_mobile" "$CHAN_MOBILE"
	else
		field "chan_mobile" "FEHLT"
		problem "chan_mobile.so ist nicht vorhanden."
	fi

	if gg_asterisk_running; then
		field "Asterisk laeuft" "ja"
		if gg_asterisk_cli 'module show like chan_mobile' | grep -q 'chan_mobile.so'; then
			field "chan_mobile geladen" "ja"
		else
			field "chan_mobile geladen" "nein"
			problem "chan_mobile ist nicht geladen (Voice Setting? Adapter-MAC?)."
		fi
	else
		field "Asterisk laeuft" "nein"
		problem "Asterisk laeuft nicht."
	fi
fi

if gg_asterisk_running; then
	run "mobile show devices" asterisk -rx "mobile show devices"
	run "pjsip show endpoints" asterisk -rx "pjsip show endpoints"
fi

# ---------------------------------------------------------------------
section "Dienste"
# ---------------------------------------------------------------------
for svc in bluetooth.service asterisk.service nftables.service fail2ban.service \
	avahi-daemon.service gsm-gateway-web.service gsm-gateway-status.timer \
	gsm-gateway-firstboot.service; do
	if systemctl cat "$svc" >/dev/null 2>&1; then
		field "  $svc" "$(systemctl is-active "$svc" 2>/dev/null)/$(systemctl is-enabled "$svc" 2>/dev/null || printf 'n/a')"
	else
		field "  $svc" "nicht installiert"
	fi
done

# ---------------------------------------------------------------------
section "Installationsstatus"
# ---------------------------------------------------------------------
field "Setup abgeschlossen" "$([ -f "$GG_COMPLETE_MARKER" ] && printf 'ja' || printf 'nein')"
field "Status" "$(gg_get_status)"
field "Versuche" "$(cat "$GG_ATTEMPT_FILE" 2>/dev/null || printf '0')"
if [ -d "$GG_STEP_DIR" ]; then
	field "Erledigte Schritte" "$(find "$GG_STEP_DIR" -name '*.done' 2>/dev/null | wc -l)"
fi

out ""
out "======================================================="
if [ "$PROBLEMS" -eq 0 ]; then
	out " Ergebnis: keine Probleme gefunden"
else
	out " Ergebnis: ${PROBLEMS} Problem(e) gefunden - siehe Zeilen mit '!'"
fi
out " Vollstaendiges Protokoll: ${GG_HARDWARE_LOG}"
out "======================================================="
out ""

[ "$PROBLEMS" -eq 0 ]
