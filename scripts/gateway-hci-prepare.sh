#!/usr/bin/env bash
# =====================================================================
#  gateway-hci-prepare.sh - Bluetooth-Adapter fuer chan_mobile fertig
#  machen.
#
#  Zwei Dinge muessen stimmen, sonst nimmt chan_mobile den Adapter nicht:
#    1. Der Adapter muss eingeschaltet (powered) sein.
#    2. Das HCI Voice Setting muss 0x0060 sein.
#       chan_mobile bricht sonst mit
#       "Skipping adapter ... Voice setting must be 0x0060" ab.
#
#  Aufruf:
#     gateway-hci-prepare.sh [hciX]        vorbereiten
#     gateway-hci-prepare.sh --show [hciX] nur anzeigen
#
#  Wird ausserdem automatisch von gsm-gateway-hci@.service aufgerufen,
#  sobald ein Adapter eingesteckt wird.
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

gg_strict
gg_load_config

# shellcheck disable=SC2034
GG_CURRENT_STEP="Bluetooth-Adapter vorbereiten"

SHOW_ONLY="no"
if [ "${1:-}" = "--show" ]; then
	SHOW_ONLY="yes"
	shift
fi

HCI="${1:-}"
if [ -z "$HCI" ]; then
	if ! HCI="$(gg_bt_select_adapter)"; then
		gg_error "Kein passender Bluetooth-Adapter gefunden (GG_BT_ADAPTER=${GG_BT_ADAPTER})."
		exit 1
	fi
fi

# Der Name kommt unter anderem von udev (%k). Erst pruefen, dann in
# Pfaden und Aufrufen verwenden.
if ! gg_is_hci_name "$HCI"; then
	gg_error "'${HCI}' ist kein gueltiger Adaptername (erwartet: hci0, hci1, ...)."
	exit 1
fi
if [ ! -e "/sys/class/bluetooth/${HCI}" ]; then
	gg_error "Bluetooth-Adapter ${HCI} existiert nicht."
	exit 1
fi

DEV_INDEX="${HCI#hci}"

show_state() {
	local voice="nicht lesbar" powered="unbekannt"
	if voice_out="$("${GG_PREFIX}/lib/hci-voice.py" show "$HCI" 2>/dev/null)"; then
		voice="$voice_out"
	elif [ -n "${voice_out:-}" ]; then
		voice="${voice_out} (abweichend)"
	fi
	if command -v btmgmt >/dev/null 2>&1; then
		if btmgmt --index "$DEV_INDEX" info 2>/dev/null | grep -q 'current settings.*powered'; then
			powered="ja"
		else
			powered="nein"
		fi
	fi
	printf 'Adapter:        %s\n' "$HCI"
	printf 'MAC:            %s\n' "$(gg_bt_address "$HCI")"
	printf 'Eingeschaltet:  %s\n' "$powered"
	printf 'Voice Setting:  %s (benoetigt: 0x0060)\n' "$voice"
}

if [ "$SHOW_ONLY" = "yes" ]; then
	show_state
	exit 0
fi

gg_require_root
gg_ensure_dirs
gg_log_target "$GG_BLUETOOTH_LOG"

gg_info "Bereite Adapter ${HCI} (MAC $(gg_bt_address "$HCI")) fuer chan_mobile vor."

# --- 1. Adapter einschalten ------------------------------------------
power_on() {
	if command -v btmgmt >/dev/null 2>&1; then
		if btmgmt --index "$DEV_INDEX" power on >/dev/null 2>&1; then
			return 0
		fi
	fi
	if command -v hciconfig >/dev/null 2>&1; then
		if hciconfig "$HCI" up >/dev/null 2>&1; then
			return 0
		fi
	fi
	# BlueZ schaltet Adapter bei AutoEnable=true selbst ein.
	if bluetoothctl power on >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

if power_on; then
	gg_info "Adapter ${HCI} ist eingeschaltet."
else
	gg_warn "Adapter ${HCI} konnte nicht aktiv eingeschaltet werden."
	gg_warn "Falls BlueZ ihn selbst einschaltet (AutoEnable=true), ist das unkritisch."
fi

# --- 2. Voice Setting auf 0x0060 -------------------------------------
set_voice_setting() {
	# Bevorzugt hciconfig, weil es der dokumentierte Weg ist.
	if command -v hciconfig >/dev/null 2>&1; then
		if hciconfig "$HCI" voice 0x0060 >/dev/null 2>&1; then
			gg_info "Voice Setting per hciconfig auf 0x0060 gesetzt."
			return 0
		fi
		gg_warn "hciconfig konnte das Voice Setting nicht setzen - versuche es direkt ueber den HCI-Socket."
	fi
	# Fallback ohne hciconfig (fehlt auf neueren BlueZ-Versionen).
	local out
	if out="$("${GG_PREFIX}/lib/hci-voice.py" set "$HCI" 0x0060 2>&1)"; then
		gg_info "Voice Setting: ${out}"
		return 0
	fi
	gg_error "Voice Setting konnte nicht gesetzt werden: ${out}"
	return 1
}

verify_voice_setting() {
	local out
	if out="$("${GG_PREFIX}/lib/hci-voice.py" show "$HCI" 2>&1)"; then
		gg_ok "Voice Setting von ${HCI} ist ${out} - chan_mobile akzeptiert den Adapter."
		gg_fact_set bt_voice_setting "$out"
		return 0
	fi
	gg_fact_set bt_voice_setting "${out:-unbekannt}"
	return 1
}

if ! set_voice_setting; then
	gg_error "Ohne Voice Setting 0x0060 lehnt chan_mobile den Adapter ${HCI} ab."
	exit 1
fi

if ! verify_voice_setting; then
	gg_warn "Das Voice Setting von ${HCI} konnte nicht bestaetigt werden."
	gg_warn "Sollte chan_mobile den Adapter ablehnen, ist das die Ursache."
	gg_warn "Pruefen mit: sudo gateway-hci-prepare.sh --show ${HCI}"
fi

gg_ok "Adapter ${HCI} vorbereitet."
