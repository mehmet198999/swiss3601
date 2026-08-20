#!/usr/bin/env bash
# =====================================================================
#  gateway-test.sh - Gesamtstatus des Gateways pruefen
#
#  Aufruf:
#     gateway-test.sh                 Uebersicht anzeigen
#     gateway-test.sh --no-color      ohne Farben (fuer Logdateien)
#     gateway-test.sh --json          Ergebnis als JSON
#     gateway-test.sh --json --output DATEI   JSON in Datei schreiben
#
#  Die JSON-Ausgabe verwendet die Statusseite (gsm-gateway-web.service).
#
#  Exit-Code:
#     0 = keine Pruefung auf FAIL
#     1 = mindestens eine Pruefung auf FAIL
#
#  Ausstehende manuelle Tests (Telefonate) fuehren NICHT zu Exit 1 -
#  die kann nur ein Mensch durchfuehren.
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

set -uo pipefail
gg_load_config

MODE="text"
OUTPUT=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--json) MODE="json" ;;
	--no-color) GG_NO_COLOR=1 ;;
	--output)
		shift
		OUTPUT="${1:-}"
		if [ -z "$OUTPUT" ]; then
			printf 'Fehlender Dateiname nach --output\n' >&2
			exit 2
		fi
		;;
	-h | --help)
		sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'Unbekannte Option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

if [ -n "${GG_NO_COLOR:-}" ] || [ ! -t 1 ]; then
	C_OK=""; C_WARN=""; C_FAIL=""; C_PEND=""; C_RESET=""; C_BOLD=""
else
	C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'
	C_PEND=$'\033[1;34m'; C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
fi

CHECK_IDS=(); CHECK_LABELS=(); CHECK_STATES=(); CHECK_DETAILS=()
MANUAL_IDS=(); MANUAL_LABELS=(); MANUAL_STATES=(); MANUAL_DETAILS=()

# add <id> <label> <state> <detail>
add() {
	CHECK_IDS+=("$1"); CHECK_LABELS+=("$2"); CHECK_STATES+=("$3"); CHECK_DETAILS+=("$4")
}
add_manual() {
	MANUAL_IDS+=("$1"); MANUAL_LABELS+=("$2"); MANUAL_STATES+=("$3"); MANUAL_DETAILS+=("$4")
}

state_of() {
	local id i
	id="$1"
	for i in "${!CHECK_IDS[@]}"; do
		if [ "${CHECK_IDS[$i]}" = "$id" ]; then
			printf '%s' "${CHECK_STATES[$i]}"
			return 0
		fi
	done
	printf 'SKIP'
}

# =====================================================================
#  Die einzelnen Pruefungen
# =====================================================================

# --- Internet / DNS --------------------------------------------------
if gg_have_internet; then
	add internet "Internet" OK "Gateway $(gg_default_gateway), IP $(gg_primary_ip)"
else
	add internet "Internet" FAIL "Keine Verbindung - Ethernet und Router pruefen"
fi

if gg_dns_works; then
	add dns "DNS" OK "$(gg_dns_servers)"
else
	add dns "DNS" FAIL "Namensaufloesung schlaegt fehl"
fi

# --- USB -------------------------------------------------------------
if command -v lsusb >/dev/null 2>&1; then
	USB_COUNT="$(lsusb 2>/dev/null | wc -l)"
	add usb "USB" OK "${USB_COUNT} Geraete am Bus"
else
	add usb "USB" WARN "lsusb ist nicht installiert"
fi

# --- ASUS BT500 ------------------------------------------------------
BT_ADAPTER="$(gg_fact_get bt_adapter '')"
if [ -z "$BT_ADAPTER" ]; then
	BT_ADAPTER="$(gg_bt_select_adapter 2>/dev/null || printf '')"
fi
BT_MAC=""
if [ -n "$BT_ADAPTER" ]; then
	BT_MAC="$(gg_bt_address "$BT_ADAPTER")"
fi

if [ -z "$BT_ADAPTER" ]; then
	add bt500 "ASUS BT500" FAIL "Kein Bluetooth-Adapter gefunden"
elif [ "$(gg_fact_get bt_adapter_is_bt500 no)" = "yes" ]; then
	add bt500 "ASUS BT500" OK "${BT_ADAPTER} / ${BT_MAC} (USB 0b05:190e)"
elif gg_bt_is_usb "$BT_ADAPTER"; then
	add bt500 "ASUS BT500" WARN "USB-Adapter ${BT_ADAPTER} ($(gg_bt_usb_id "$BT_ADAPTER" 2>/dev/null || printf '?')), aber nicht der BT500"
else
	add bt500 "ASUS BT500" WARN "Nur internes Bluetooth (${BT_ADAPTER}) - USB-BT500 empfohlen"
fi

# --- Bluetooth-Dienst ------------------------------------------------
if ! gg_service_active bluetooth.service; then
	add bluetooth "Bluetooth" FAIL "bluetooth.service laeuft nicht"
elif command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth 2>/dev/null | grep -qi 'blocked: yes'; then
	add bluetooth "Bluetooth" FAIL "Per rfkill blockiert"
else
	VOICE="unbekannt"
	if [ -n "$BT_ADAPTER" ]; then
		VOICE="$("${GG_PREFIX}/lib/hci-voice.py" show "$BT_ADAPTER" 2>&1)"
	fi
	if [ "$VOICE" = "0x0060" ]; then
		add bluetooth "Bluetooth" OK "Adapter aktiv, Voice Setting ${VOICE}"
	else
		add bluetooth "Bluetooth" WARN "Voice Setting ${VOICE} statt 0x0060 - chan_mobile lehnt den Adapter ab"
	fi
fi

# --- BlueZ -----------------------------------------------------------
if command -v bluetoothctl >/dev/null 2>&1; then
	BLUEZ_VER="$(bluetoothctl --version 2>/dev/null | awk '{print $NF}')"
	add bluez "BlueZ" OK "Version ${BLUEZ_VER:-unbekannt}"
else
	add bluez "BlueZ" FAIL "bluetoothctl fehlt - Paket bluez nicht installiert"
fi

# --- iPhone: gekoppelt / vertraut / verbunden ------------------------
PHONE_MAC="$(gg_fact_get phone_mac '')"
PHONE_INFO=""
if [ -n "$PHONE_MAC" ]; then
	PHONE_INFO="$(bluetoothctl info "$PHONE_MAC" 2>/dev/null)"
fi

bt_attr() {
	printf '%s\n' "$PHONE_INFO" | awk -v a="$1:" '$1==a {print $2; exit}'
}

if [ -z "$PHONE_MAC" ]; then
	add phone_paired  "iPhone gekoppelt"  PENDING "Noch kein Telefon eingerichtet - 'sudo pair-iphone' ausfuehren"
	add phone_trusted "iPhone vertraut"   PENDING "Noch kein Telefon eingerichtet"
	add phone_conn    "iPhone verbunden"  PENDING "Noch kein Telefon eingerichtet"
	add hfp           "HFP erkannt"       PENDING "Noch kein Telefon eingerichtet"
elif [ -z "$PHONE_INFO" ]; then
	add phone_paired  "iPhone gekoppelt"  FAIL "BlueZ kennt ${PHONE_MAC} nicht mehr - erneut koppeln"
	add phone_trusted "iPhone vertraut"   FAIL "Unbekanntes Geraet"
	add phone_conn    "iPhone verbunden"  FAIL "Unbekanntes Geraet"
	add hfp           "HFP erkannt"       FAIL "Unbekanntes Geraet"
else
	PHONE_NAME="$(printf '%s\n' "$PHONE_INFO" | awk '$1=="Name:" {$1=""; sub(/^ /,""); print; exit}')"

	if [ "$(bt_attr Paired)" = "yes" ]; then
		add phone_paired "iPhone gekoppelt" OK "${PHONE_NAME:-iPhone} (${PHONE_MAC})"
	else
		add phone_paired "iPhone gekoppelt" FAIL "Nicht gekoppelt - 'sudo pair-iphone'"
	fi

	if [ "$(bt_attr Trusted)" = "yes" ]; then
		add phone_trusted "iPhone vertraut" OK "Trust gesetzt"
	else
		add phone_trusted "iPhone vertraut" FAIL "Trust fehlt - 'sudo pair-iphone'"
	fi

	if [ "$(bt_attr Connected)" = "yes" ]; then
		add phone_conn "iPhone verbunden" OK "BlueZ meldet eine bestehende Verbindung"
	else
		add phone_conn "iPhone verbunden" WARN "Gerade nicht verbunden. chan_mobile baut die Verbindung selbst auf - massgeblich ist die Zeile 'chan_mobile Geraet'."
	fi

	if printf '%s\n' "$PHONE_INFO" | grep -qi '0000111f'; then
		add hfp "HFP erkannt" OK "Handsfree Audio Gateway (0000111f) wird angeboten"
	elif printf '%s\n' "$PHONE_INFO" | grep -qi '00001112'; then
		add hfp "HFP erkannt" FAIL "Nur HSP (Headset), kein HFP - Telefonie nicht moeglich"
	else
		add hfp "HFP erkannt" FAIL "Das iPhone ist per Bluetooth verbunden, aber der benötigte HFP-Telefoniedienst wurde nicht erkannt."
	fi
fi

# --- Audio -----------------------------------------------------------
AUDIO_DETAIL="chan_mobile nutzt SCO direkt - kein zusaetzliches Audiosystem noetig"
AUDIO_STATE="OK"
if ! "${GG_PREFIX}/lib/sco-check.py" >/dev/null 2>&1; then
	AUDIO_STATE="FAIL"
	AUDIO_DETAIL="Der Kernel stellt keine SCO-Sockets bereit"
else
	for unit in bluealsa.service pulseaudio.service pipewire.service wireplumber.service; do
		if systemctl is-active --quiet "$unit" 2>/dev/null; then
			AUDIO_STATE="WARN"
			AUDIO_DETAIL="${unit} laeuft und konkurriert um HFP - setup-audio.sh ausfuehren"
			break
		fi
	done
fi
add audio "Audio-System" "$AUDIO_STATE" "$AUDIO_DETAIL"

# --- Asterisk --------------------------------------------------------
AST_VERSION="$(gg_asterisk_version)"
if [ -z "$AST_VERSION" ]; then
	add asterisk "Asterisk" FAIL "Nicht installiert"
elif gg_asterisk_running; then
	add asterisk "Asterisk" OK "Version ${AST_VERSION} laeuft ($(gg_fact_get asterisk_install_method 'unbekannt'))"
else
	add asterisk "Asterisk" FAIL "Version ${AST_VERSION} installiert, laeuft aber nicht"
fi

# --- chan_mobile -----------------------------------------------------
if ! CHAN_MOBILE_SO="$(gg_chan_mobile_file)"; then
	add chan_mobile "chan_mobile" FAIL "chan_mobile.so fehlt"
elif ! gg_asterisk_running; then
	add chan_mobile "chan_mobile" WARN "Modul vorhanden (${CHAN_MOBILE_SO}), Asterisk laeuft aber nicht"
elif gg_asterisk_cli 'module show like chan_mobile' 2>/dev/null | grep -q 'chan_mobile.so'; then
	add chan_mobile "chan_mobile" OK "Modul geladen"
else
	add chan_mobile "chan_mobile" FAIL "Modul vorhanden, aber nicht geladen (Voice Setting? Adapter-MAC?)"
fi

# --- Mobile Device (chan_mobile-Sicht) -------------------------------
if gg_asterisk_running && [ "$(state_of chan_mobile)" = "OK" ]; then
	MOBILE_OUT="$(gg_asterisk_cli 'mobile show devices' 2>/dev/null)"
	MOBILE_LINE="$(printf '%s\n' "$MOBILE_OUT" | awk -v id="$GG_MOBILE_ID" 'NR>1 && $1==id {print; exit}')"
	if [ -z "$MOBILE_LINE" ]; then
		add mobile_device "chan_mobile Geraet" PENDING "Kein Geraet '${GG_MOBILE_ID}' konfiguriert - 'sudo pair-iphone'"
	else
		MOBILE_CONNECTED="$(printf '%s' "$MOBILE_LINE" | awk '{print $5}')"
		MOBILE_STATE="$(printf '%s' "$MOBILE_LINE" | awk '{print $6}')"
		if [ "$MOBILE_CONNECTED" = "Yes" ] && [ "$MOBILE_STATE" = "Free" ]; then
			add mobile_device "chan_mobile Geraet" OK "${GG_MOBILE_ID}: verbunden, Netz verfuegbar"
		elif [ "$MOBILE_CONNECTED" = "Yes" ]; then
			add mobile_device "chan_mobile Geraet" WARN "${GG_MOBILE_ID}: verbunden, Zustand '${MOBILE_STATE}'"
		else
			add mobile_device "chan_mobile Geraet" WARN "${GG_MOBILE_ID}: nicht verbunden - iPhone in Reichweite und Bluetooth an?"
		fi
	fi
else
	add mobile_device "chan_mobile Geraet" PENDING "chan_mobile ist noch nicht einsatzbereit"
fi

# --- SIP -------------------------------------------------------------
SIP_BIND="$(gg_fact_get sip_bind_ip '')"
CURRENT_IP="$(gg_primary_ip)"
if ! gg_asterisk_running; then
	add sip "SIP" FAIL "Asterisk laeuft nicht"
elif gg_asterisk_cli 'pjsip show endpoints' 2>/dev/null | grep -q "$GG_SIP_EXTENSION"; then
	if [ -n "$SIP_BIND" ] && [ -n "$CURRENT_IP" ] && [ "$SIP_BIND" != "$CURRENT_IP" ]; then
		add sip "SIP" WARN "Gebunden an ${SIP_BIND}, aktuelle IP ist ${CURRENT_IP} - 'sudo /opt/gsm-gateway/install/setup-sip.sh' erneut ausfuehren"
	else
		add sip "SIP" OK "Nebenstelle ${GG_SIP_EXTENSION} auf ${SIP_BIND:-$CURRENT_IP}:${GG_SIP_PORT} (nur LAN)"
	fi
else
	add sip "SIP" FAIL "Nebenstelle ${GG_SIP_EXTENSION} nicht gefunden"
fi

# Kontrollpruefung: kein offener SIP-Port nach aussen.
if command -v ss >/dev/null 2>&1 && gg_asterisk_running; then
	if ss -lun 2>/dev/null | grep -qE "(0\.0\.0\.0|\*):${GG_SIP_PORT}\b"; then
		add sip_exposure "SIP-Bindung" FAIL "SIP lauscht auf allen Adressen - das ist nicht gewollt"
	else
		add sip_exposure "SIP-Bindung" OK "Lauscht nicht auf 0.0.0.0:${GG_SIP_PORT}"
	fi
fi

# --- Firewall --------------------------------------------------------
if ! command -v nft >/dev/null 2>&1; then
	add firewall "Firewall" FAIL "nftables ist nicht installiert"
elif nft list table inet gsm_gateway >/dev/null 2>&1; then
	F2B="ohne fail2ban"
	if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status asterisk >/dev/null 2>&1; then
		F2B="fail2ban aktiv"
	fi
	add firewall "Firewall" OK "Tabelle inet gsm_gateway geladen, ${F2B}"
else
	add firewall "Firewall" FAIL "Tabelle inet gsm_gateway fehlt - setup-firewall.sh ausfuehren"
fi

# --- Manuelle Tests --------------------------------------------------
add_manual gsm_in "GSM Incoming" PENDING "Test A: eine andere Nummer ruft die Schweizer SIM an"
add_manual gsm_out "GSM Outgoing" PENDING "Test B: von SIP ${GG_SIP_EXTENSION} eine Nummer anrufen"
add_manual audio_quality "Audio Quality" PENDING "Test C: Echo, Laufzeit, Lautstaerke, Stabilitaet beurteilen"
add_manual sms "SMS" PENDING "Ueber HFP bietet ein iPhone keine SMS-Funktion an - siehe docs/LIMITATIONS.md"

# =====================================================================
#  Ausgabe
# =====================================================================

FAILED=0
WARNED=0
PASSED=0
for st in "${CHECK_STATES[@]}"; do
	case "$st" in
	FAIL) FAILED=$((FAILED + 1)) ;;
	WARN) WARNED=$((WARNED + 1)) ;;
	OK) PASSED=$((PASSED + 1)) ;;
	esac
done

json_escape() {
	printf '%s' "$1" | python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

emit_json() {
	local i first
	printf '{\n'
	printf '  "generated": %s,\n' "$(json_escape "$(gg_timestamp)")"
	printf '  "hostname": %s,\n' "$(json_escape "$(hostname)")"
	printf '  "summary": {"ok": %d, "warn": %d, "fail": %d},\n' "$PASSED" "$WARNED" "$FAILED"
	printf '  "checks": [\n'
	first=1
	for i in "${!CHECK_IDS[@]}"; do
		[ "$first" -eq 1 ] || printf ',\n'
		first=0
		printf '    {"id": %s, "label": %s, "state": %s, "detail": %s}' \
			"$(json_escape "${CHECK_IDS[$i]}")" \
			"$(json_escape "${CHECK_LABELS[$i]}")" \
			"$(json_escape "${CHECK_STATES[$i]}")" \
			"$(json_escape "${CHECK_DETAILS[$i]}")"
	done
	printf '\n  ],\n'
	printf '  "manual": [\n'
	first=1
	for i in "${!MANUAL_IDS[@]}"; do
		[ "$first" -eq 1 ] || printf ',\n'
		first=0
		printf '    {"id": %s, "label": %s, "state": %s, "detail": %s}' \
			"$(json_escape "${MANUAL_IDS[$i]}")" \
			"$(json_escape "${MANUAL_LABELS[$i]}")" \
			"$(json_escape "${MANUAL_STATES[$i]}")" \
			"$(json_escape "${MANUAL_DETAILS[$i]}")"
	done
	printf '\n  ]\n'
	printf '}\n'
}

colorize() {
	case "$1" in
	OK) printf '%s%s%s' "$C_OK" "$1" "$C_RESET" ;;
	WARN) printf '%s%s%s' "$C_WARN" "$1" "$C_RESET" ;;
	FAIL) printf '%s%s%s' "$C_FAIL" "$1" "$C_RESET" ;;
	PENDING) printf '%s%s%s' "$C_PEND" "TEST AUSSTEHEND" "$C_RESET" ;;
	*) printf '%s' "$1" ;;
	esac
}

# Kurzform fuer den Uebersichtsblock.
summary_state() {
	local st
	st="$(state_of "$1")"
	case "$st" in
	PENDING) printf 'TEST AUSSTEHEND' ;;
	*) printf '%s' "$st" ;;
	esac
}

emit_text() {
	local i
	printf '\n'
	printf '=======================================\n'
	printf ' %sGSM -> SIP GATEWAY%s\n' "$C_BOLD" "$C_RESET"
	printf '=======================================\n\n'

	# Uebersicht in der vorgegebenen Form
	printf '%-20s %s\n' "System:" "$(colorize "$( [ "$FAILED" -eq 0 ] && printf 'OK' || printf 'FAIL' )")"
	printf '%-20s %s\n' "Internet:" "$(colorize "$(state_of internet)")"
	printf '%-20s %s\n' "USB BT500:" "$(colorize "$(state_of bt500)")"
	printf '%-20s %s\n' "Bluetooth:" "$(colorize "$(state_of bluetooth)")"
	printf '%-20s %s\n' "iPhone:" "$(colorize "$(state_of phone_paired)")"
	printf '%-20s %s\n' "HFP:" "$(colorize "$(state_of hfp)")"
	printf '%-20s %s\n' "Audio:" "$(colorize "$(state_of audio)")"
	printf '%-20s %s\n' "Asterisk:" "$(colorize "$(state_of asterisk)")"
	printf '%-20s %s\n' "chan_mobile:" "$(colorize "$(state_of chan_mobile)")"
	printf '%-20s %s\n' "SIP:" "$(colorize "$(state_of sip)")"
	printf '\n'
	for i in "${!MANUAL_IDS[@]}"; do
		printf '%-20s %s\n' "${MANUAL_LABELS[$i]}:" "$(colorize "${MANUAL_STATES[$i]}")"
	done
	printf '\n=======================================\n\n'

	# Ausfuehrliche Liste
	printf '%sEinzelne Pruefungen%s\n' "$C_BOLD" "$C_RESET"
	printf -- '---------------------------------------\n'
	for i in "${!CHECK_IDS[@]}"; do
		printf '[%s] %-22s %s\n' \
			"$( [ "${CHECK_STATES[$i]}" = "OK" ] && printf 'x' || printf ' ' )" \
			"${CHECK_LABELS[$i]}" \
			"$(colorize "${CHECK_STATES[$i]}")"
		if [ -n "${CHECK_DETAILS[$i]}" ]; then
			printf '      %s\n' "${CHECK_DETAILS[$i]}"
		fi
	done
	printf '\n'
	printf 'Zusammenfassung: %d OK, %d Warnung(en), %d Fehler\n' "$PASSED" "$WARNED" "$FAILED"

	if [ "$FAILED" -gt 0 ]; then
		printf '\n%sNaechster Schritt:%s Zeilen mit FAIL abarbeiten.\n' "$C_BOLD" "$C_RESET"
		printf 'Hilfen: sudo gateway-check    sudo bluetooth-check\n'
		printf 'Logs:   %s\n' "$GG_LOG_DIR"
	elif [ "$(state_of hfp)" = "PENDING" ]; then
		printf '\n%sNaechster Schritt:%s iPhone koppeln mit  sudo pair-iphone\n' "$C_BOLD" "$C_RESET"
	else
		printf '\nAlle automatischen Pruefungen bestanden.\n'
		printf 'Jetzt die manuellen Telefonietests durchfuehren - siehe README.md, Abschnitt "Telefonie-Test".\n'
	fi
	printf '\n'
}

if [ "$MODE" = "json" ]; then
	if [ -n "$OUTPUT" ]; then
		TMP="${OUTPUT}.tmp.$$"
		if ! emit_json >"$TMP"; then
			rm -f "$TMP"
			printf 'JSON konnte nicht erzeugt werden.\n' >&2
			exit 1
		fi
		mv "$TMP" "$OUTPUT"
		chmod 0644 "$OUTPUT"
	else
		emit_json
	fi
else
	emit_text
fi

[ "$FAILED" -eq 0 ]
