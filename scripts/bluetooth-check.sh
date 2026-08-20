#!/usr/bin/env bash
# =====================================================================
#  bluetooth-check.sh - Bluetooth-Diagnose
#
#  Prueft alles, was zwischen dem ASUS USB-BT500 und dem iPhone stimmen
#  muss, damit chan_mobile funktioniert - insbesondere HFP.
#
#  Aufruf:
#     bluetooth-check.sh            anzeigen und protokollieren
#     bluetooth-check.sh --quiet    nur protokollieren
#
#  Exit 0 = keine Probleme, 1 = Probleme gefunden
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

set -uo pipefail
gg_load_config

if [ "$(id -u)" -eq 0 ]; then
	gg_ensure_dirs
fi
if [ -w "$GG_LOG_DIR" ]; then
	LOG_WRITABLE="yes"
	gg_log_target "$GG_BLUETOOTH_LOG"
else
	LOG_WRITABLE="no"
fi

QUIET="no"
if [ "${1:-}" = "--quiet" ]; then
	QUIET="yes"
fi

PROBLEMS=0

out() {
	if [ "$QUIET" = "no" ]; then
		printf '%s\n' "$*"
	fi
	if [ "$LOG_WRITABLE" = "yes" ]; then
		printf '%s\n' "$*" >>"$GG_BLUETOOTH_LOG"
	fi
}
field() { out "$(printf '%-24s %s' "$1:" "$2")"; }
problem() {
	PROBLEMS=$((PROBLEMS + 1))
	out "  ! $*"
}

# UUID des Handsfree Audio Gateway. Das ist der Dienst, den das iPhone
# anbieten muss, damit chan_mobile telefonieren kann.
HFP_AG_UUID="0000111f"
HSP_AG_UUID="00001112"

out ""
out "======================================================="
out " Bluetooth-Diagnose - $(gg_timestamp)"
out "======================================================="

# ---------------------------------------------------------------------
out ""
out "--- Dienst und Blockaden ---"
# ---------------------------------------------------------------------
if gg_service_active bluetooth.service; then
	field "bluetooth.service" "laeuft"
else
	field "bluetooth.service" "laeuft NICHT"
	problem "bluetooth.service starten: sudo systemctl start bluetooth"
fi

if command -v rfkill >/dev/null 2>&1; then
	if rfkill list bluetooth 2>/dev/null | grep -qi 'blocked: yes'; then
		field "rfkill" "BLOCKIERT"
		problem "Bluetooth ist blockiert: sudo rfkill unblock bluetooth"
	else
		field "rfkill" "nicht blockiert"
	fi
else
	field "rfkill" "nicht installiert"
fi

if command -v bluetoothctl >/dev/null 2>&1; then
	field "BlueZ-Version" "$(bluetoothctl --version 2>/dev/null | awk '{print $NF}')"
else
	field "BlueZ-Version" "bluetoothctl fehlt"
	problem "Das Paket bluez ist nicht installiert."
fi

# ---------------------------------------------------------------------
out ""
out "--- Adapter ---"
# ---------------------------------------------------------------------
ADAPTERS="$(gg_bt_adapters | tr '\n' ' ')"
if [ -z "${ADAPTERS// /}" ]; then
	problem "Kein Bluetooth-Adapter vorhanden. USB-BT500 eingesteckt?"
else
	for hci in $(gg_bt_adapters); do
		if gg_bt_is_usb "$hci"; then
			field "$hci" "USB  MAC=$(gg_bt_address "$hci")  USB-ID=$(gg_bt_usb_id "$hci" 2>/dev/null || printf '?')"
		else
			field "$hci" "intern  MAC=$(gg_bt_address "$hci")"
		fi
	done
fi

SELECTED="$(gg_fact_get bt_adapter '')"
if [ -z "$SELECTED" ]; then
	SELECTED="$(gg_bt_select_adapter 2>/dev/null || printf '')"
fi
field "Verwendeter Adapter" "${SELECTED:-keiner}"

if [ -n "$SELECTED" ]; then
	if gg_bt_is_usb "$SELECTED"; then
		field "Anschlussart" "USB (empfohlen)"
	else
		field "Anschlussart" "intern"
		problem "Es wird das interne Bluetooth verwendet. Fuer HFP-Sprache ist der USB-BT500 deutlich zuverlaessiger."
	fi

	VOICE="$("${GG_PREFIX}/lib/hci-voice.py" show "$SELECTED" 2>&1)"
	field "HCI Voice Setting" "$VOICE"
	if [ "$VOICE" != "0x0060" ]; then
		problem "chan_mobile verlangt 0x0060. Beheben: sudo gateway-hci-prepare.sh ${SELECTED}"
	fi
fi

if [ "$(gg_fact_get bt_adapter_is_bt500 no)" = "yes" ]; then
	field "ASUS USB-BT500" "erkannt (0b05:190e)"
else
	field "ASUS USB-BT500" "nicht als BT500 erkannt"
fi

# ---------------------------------------------------------------------
out ""
out "--- Sprachkanal (SCO) ---"
# ---------------------------------------------------------------------
if SCO_OUT="$("${GG_PREFIX}/lib/sco-check.py" 2>&1)"; then
	field "SCO-Sockets" "verfuegbar"
else
	field "SCO-Sockets" "$SCO_OUT"
	problem "Ohne SCO gibt es keinen Sprachkanal."
fi
if [ -r /sys/module/bluetooth/parameters/disable_esco ]; then
	field "disable_esco" "$(cat /sys/module/bluetooth/parameters/disable_esco)"
fi
if [ -r /sys/module/btusb/parameters/enable_autosuspend ]; then
	field "btusb autosuspend" "$(cat /sys/module/btusb/parameters/enable_autosuspend)"
fi

# Konkurrierende Audio-Dienste
COMPETING=""
for unit in bluealsa.service pulseaudio.service pipewire.service wireplumber.service; do
	if systemctl is-active --quiet "$unit" 2>/dev/null; then
		COMPETING="${COMPETING} ${unit}"
	fi
done
if [ -n "$COMPETING" ]; then
	field "Konkurrierendes Audio" "$COMPETING"
	problem "Diese Dienste streiten sich mit chan_mobile um HFP. Abschalten: sudo /opt/gsm-gateway/install/setup-audio.sh"
else
	field "Konkurrierendes Audio" "keines (richtig so)"
fi

# ---------------------------------------------------------------------
out ""
out "--- Gekoppelte Geraete ---"
# ---------------------------------------------------------------------
PHONE_MAC="$(gg_fact_get phone_mac '')"
DEVICES="$(bluetoothctl devices 2>/dev/null)"
if [ -z "$DEVICES" ]; then
	field "Gekoppelte Geraete" "keine"
	out "  Hinweis: iPhone koppeln mit  sudo pair-iphone"
else
	printf '%s\n' "$DEVICES" | while IFS= read -r line; do
		out "  ${line}"
	done
fi

if [ -n "$PHONE_MAC" ]; then
	out ""
	field "Konfiguriertes iPhone" "$PHONE_MAC"
	INFO="$(bluetoothctl info "$PHONE_MAC" 2>/dev/null)"
	if [ -z "$INFO" ]; then
		problem "BlueZ kennt ${PHONE_MAC} nicht mehr. Erneut koppeln: sudo pair-iphone"
	else
		for attr in Paired Trusted Connected; do
			value="$(printf '%s\n' "$INFO" | awk -v a="${attr}:" '$1==a {print $2; exit}')"
			field "  $attr" "${value:-unbekannt}"
			if [ "$attr" != "Connected" ] && [ "${value:-no}" != "yes" ]; then
				problem "${attr} ist nicht 'yes'. Erneut koppeln: sudo pair-iphone"
			fi
		done

		if printf '%s\n' "$INFO" | grep -qi "$HFP_AG_UUID"; then
			field "  HFP (Handsfree AG)" "angeboten"
		elif printf '%s\n' "$INFO" | grep -qi "$HSP_AG_UUID"; then
			field "  HFP (Handsfree AG)" "nur HSP (Headset), kein HFP"
			problem "Das iPhone ist verbunden, aber der benoetigte HFP-Telefoniedienst wurde nicht erkannt."
		else
			field "  HFP (Handsfree AG)" "NICHT angeboten"
			problem "Das iPhone ist per Bluetooth verbunden, aber der benötigte HFP-Telefoniedienst wurde nicht erkannt."
		fi

		field "  RFCOMM-Port" "$(gg_fact_get rfcomm_port 'unbekannt')"
	fi
else
	out ""
	out "  Es ist noch kein iPhone fuer chan_mobile eingetragen."
	out "  Naechster Schritt:  sudo pair-iphone"
fi

# ---------------------------------------------------------------------
out ""
out "--- chan_mobile ---"
# ---------------------------------------------------------------------
if gg_asterisk_running; then
	MOBILE_DEVICES="$(gg_asterisk_cli 'mobile show devices' 2>/dev/null)"
	if [ -n "$MOBILE_DEVICES" ]; then
		printf '%s\n' "$MOBILE_DEVICES" | while IFS= read -r line; do
			out "  ${line}"
		done
		if printf '%s\n' "$MOBILE_DEVICES" | awk 'NR>1 && $5=="Yes" {found=1} END {exit !found}'; then
			field "Telefon verbunden" "ja"
		else
			field "Telefon verbunden" "nein"
			out "  Hinweis: chan_mobile versucht alle 30 Sekunden erneut zu verbinden."
			out "  Das iPhone muss dafuer in Reichweite und Bluetooth eingeschaltet sein."
		fi
	else
		field "mobile show devices" "keine Ausgabe (Modul geladen?)"
	fi
else
	field "Asterisk" "laeuft nicht - chan_mobile kann nicht geprueft werden"
fi

# ---------------------------------------------------------------------
if [ "$LOG_WRITABLE" = "yes" ]; then
	{
		printf '\n--- bluetoothctl show ---\n'
		bluetoothctl show 2>&1
		printf '\n--- dmesg (Bluetooth) ---\n'
		dmesg 2>/dev/null | grep -iE 'bluetooth|btusb|rtl_bt' | tail -n 30
	} >>"$GG_BLUETOOTH_LOG" 2>&1
fi

out ""
out "======================================================="
if [ "$PROBLEMS" -eq 0 ]; then
	out " Ergebnis: keine Bluetooth-Probleme gefunden"
else
	out " Ergebnis: ${PROBLEMS} Problem(e) - siehe Zeilen mit '!'"
fi
if [ "$LOG_WRITABLE" = "yes" ]; then
	out " Protokoll: ${GG_BLUETOOTH_LOG}"
fi
out "======================================================="
out ""

[ "$PROBLEMS" -eq 0 ]
