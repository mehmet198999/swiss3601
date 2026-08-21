#!/usr/bin/env bash
# =====================================================================
#  gateway-watchdog.sh - Verbindung ueberwachen und wiederherstellen
#
#  Das Problem: Ein iPhone trennt die HFP-Verbindung im Leerlauf, nach
#  einem iOS-Update oder wenn es zwischendurch im Auto war. chan_mobile
#  versucht zwar alle 30 Sekunden neu zu verbinden - aber wenn Asterisk
#  haengt, das Modul entladen wurde oder der Bluetooth-Adapter klemmt,
#  passiert gar nichts mehr. Ohne Ueberwachung faellt das erst auf,
#  wenn ein wichtiger Anruf nicht ankommt.
#
#  Dieses Script laeuft per Timer jede Minute und arbeitet eine
#  Eskalationsleiter ab. Zwei Grundsaetze:
#
#    1. WAEHREND EINES GESPRAECHS WIRD NICHTS ANGEFASST.
#       Ein Watchdog, der ein laufendes Telefonat abschiesst, ist
#       schlimmer als gar keiner.
#
#    2. Erst abwarten, dann sanft, dann hart - und mit Wartezeit
#       zwischen den Stufen. Kein Neustart im Sekundentakt.
#
#  Eskalationsstufen (nur wenn kein Gespraech laeuft):
#
#     nach  3 Minuten   BlueZ bitten, die Verbindung aufzubauen
#     nach  6 Minuten   chan_mobile neu laden
#     nach 10 Minuten   Asterisk neu starten
#     nach 15 Minuten   Bluetooth-Adapter aus- und einschalten
#     danach            nur noch beobachten und einmal melden
#                       (kein Dauer-Neustart)
#
#  Aufruf:
#     gateway-watchdog.sh            eine Pruefung durchfuehren
#     gateway-watchdog.sh --status   aktuellen Zustand anzeigen
#     gateway-watchdog.sh --reset    Zaehler zuruecksetzen
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

set -uo pipefail
gg_load_config

# shellcheck disable=SC2034
GG_CURRENT_STEP="Watchdog"

WATCHDOG_STATE="${GG_STATE_DIR}/watchdog"
WATCHDOG_LOG="${GG_LOG_DIR}/watchdog.log"

# Ab wie vielen aufeinanderfolgenden Fehlversuchen welche Stufe greift.
# Der Timer laeuft im Minutentakt, die Zahlen sind also Minuten.
ESCALATE_CONNECT=3
ESCALATE_RELOAD=6
ESCALATE_RESTART=10
ESCALATE_ADAPTER=15
ESCALATE_GIVEUP=20

# ---------------------------------------------------------------------
#  Zustand
# ---------------------------------------------------------------------
# Gespeichert werden: Fehlerzaehler, zuletzt ausgefuehrte Massnahme,
# Zeitpunkt der letzten Massnahme, letzte Zustandsbeschreibung.
WD_FAILS=0
WD_LAST_ACTION="keine"
WD_LAST_ACTION_TS=0
WD_STATE="unbekannt"

load_state() {
	if [ -r "$WATCHDOG_STATE" ]; then
		# shellcheck source=/dev/null
		. "$WATCHDOG_STATE"
	fi
	case "$WD_FAILS" in
	'' | *[!0-9]*) WD_FAILS=0 ;;
	esac
	case "$WD_LAST_ACTION_TS" in
	'' | *[!0-9]*) WD_LAST_ACTION_TS=0 ;;
	esac
}

save_state() {
	mkdir -p "$GG_STATE_DIR"
	cat >"$WATCHDOG_STATE" <<STATE
WD_FAILS=${WD_FAILS}
WD_LAST_ACTION="${WD_LAST_ACTION}"
WD_LAST_ACTION_TS=${WD_LAST_ACTION_TS}
WD_STATE="${WD_STATE}"
WD_UPDATED="$(gg_timestamp)"
STATE
	chmod 0644 "$WATCHDOG_STATE"
}

wlog() {
	local line
	line="[$(gg_timestamp)] $*"
	if [ -w "$GG_LOG_DIR" ] || [ -w "$WATCHDOG_LOG" ]; then
		printf '%s\n' "$line" >>"$WATCHDOG_LOG"
	fi
	if [ "${VERBOSE:-no}" = "yes" ]; then
		printf '%s\n' "$line"
	fi
}

# ---------------------------------------------------------------------
#  Modus --status / --reset
# ---------------------------------------------------------------------
VERBOSE="no"
case "${1:-}" in
--status)
	load_state
	printf 'Zustand:            %s\n' "$WD_STATE"
	printf 'Fehlversuche:       %s\n' "$WD_FAILS"
	printf 'Letzte Massnahme:   %s\n' "$WD_LAST_ACTION"
	if [ "$WD_LAST_ACTION_TS" -gt 0 ]; then
		printf 'Zeitpunkt:          %s\n' "$(date -d "@${WD_LAST_ACTION_TS}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$WD_LAST_ACTION_TS")"
	fi
	printf 'Protokoll:          %s\n' "$WATCHDOG_LOG"
	exit 0
	;;
--reset)
	gg_require_root
	WD_FAILS=0
	WD_LAST_ACTION="zurueckgesetzt"
	WD_LAST_ACTION_TS="$(date +%s)"
	WD_STATE="zurueckgesetzt"
	save_state
	printf 'Watchdog-Zaehler zurueckgesetzt.\n'
	exit 0
	;;
-v | --verbose) VERBOSE="yes" ;;
'') ;;
-h | --help)
	sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
*)
	printf 'Unbekannte Option: %s\n' "$1" >&2
	exit 2
	;;
esac

gg_require_root
gg_ensure_dirs
load_state

# Solange die Erstinstallation laeuft, haelt sich der Watchdog heraus.
if [ ! -f "$GG_COMPLETE_MARKER" ]; then
	WD_STATE="Installation laeuft noch"
	save_state
	exit 0
fi

# ---------------------------------------------------------------------
#  Massnahmen
# ---------------------------------------------------------------------
NOW="$(date +%s)"

# Eine Massnahme nicht oefter als alle <sekunden> wiederholen.
may_act() {
	local action="$1" min_gap="$2"
	if [ "$WD_LAST_ACTION" != "$action" ]; then
		return 0
	fi
	if [ "$((NOW - WD_LAST_ACTION_TS))" -ge "$min_gap" ]; then
		return 0
	fi
	return 1
}

record_action() {
	WD_LAST_ACTION="$1"
	WD_LAST_ACTION_TS="$NOW"
	wlog "MASSNAHME: $1 (Fehlversuche: ${WD_FAILS})"
}

# Laeuft gerade ein Gespraech? Im Zweifel wird "ja" angenommen -
# lieber eine Runde warten als ein Telefonat abschneiden.
call_in_progress() {
	local out count
	out="$(gg_asterisk_cli 'core show channels count' 2>/dev/null)"
	if [ -z "$out" ]; then
		# Asterisk antwortet nicht - dann laeuft dort auch kein
		# Gespraech, das man stoeren koennte.
		return 1
	fi
	count="$(printf '%s\n' "$out" | awk '$2=="active" && $3 ~ /^call/ {print $1; exit}')"
	case "$count" in
	'' | *[!0-9]*)
		wlog "WARNUNG: Anzahl aktiver Gespraeche nicht erkennbar - es wird vorsichtshalber nichts unternommen."
		return 0
		;;
	0) return 1 ;;
	*) return 0 ;;
	esac
}

action_bluez_connect() {
	local mac adapter_mac
	mac="$(gg_fact_get phone_mac '')"
	adapter_mac="$(gg_fact_get bt_adapter_address '')"
	[ -n "$mac" ] || return 1
	record_action "bluez-connect"
	{
		[ -n "$adapter_mac" ] && printf 'select %s\n' "$adapter_mac"
		printf 'connect %s\n' "$mac"
		sleep 3
	} | timeout 30s bluetoothctl >/dev/null 2>&1
	return 0
}

action_reload_module() {
	record_action "chan_mobile-reload"
	gg_asterisk_cli 'module reload chan_mobile.so' >/dev/null 2>&1
	return 0
}

action_restart_asterisk() {
	record_action "asterisk-restart"
	if systemctl restart asterisk.service >/dev/null 2>>"$WATCHDOG_LOG"; then
		wlog "asterisk.service neu gestartet."
	else
		wlog "FEHLER: asterisk.service liess sich nicht neu starten."
	fi
	return 0
}

action_reset_adapter() {
	local adapter index
	adapter="$(gg_fact_get bt_adapter '')"
	if [ -z "$adapter" ] || ! gg_is_hci_name "$adapter"; then
		return 1
	fi
	record_action "adapter-reset"
	index="${adapter#hci}"
	if command -v btmgmt >/dev/null 2>&1; then
		btmgmt --index "$index" power off >/dev/null 2>&1
		sleep 2
		btmgmt --index "$index" power on >/dev/null 2>&1
	else
		systemctl restart bluetooth.service >/dev/null 2>>"$WATCHDOG_LOG"
	fi
	sleep 3
	# Nach dem Einschalten muss das Voice Setting wieder stimmen.
	"${GG_PREFIX}/scripts/gateway-hci-prepare.sh" "$adapter" >/dev/null 2>&1
	# Asterisk muss den Adapter neu greifen.
	systemctl restart asterisk.service >/dev/null 2>&1
	return 0
}

# ---------------------------------------------------------------------
#  Pruefungen
# ---------------------------------------------------------------------

# 1. Laeuft Asterisk ueberhaupt?
if ! gg_service_active asterisk.service; then
	WD_STATE="Asterisk laeuft nicht"
	WD_FAILS=$((WD_FAILS + 1))
	wlog "asterisk.service ist nicht aktiv."
	if may_act "asterisk-start" 120; then
		record_action "asterisk-start"
		if systemctl start asterisk.service >/dev/null 2>>"$WATCHDOG_LOG"; then
			wlog "asterisk.service gestartet."
		else
			wlog "FEHLER: asterisk.service laesst sich nicht starten."
		fi
	fi
	save_state
	exit 0
fi

# 2. Antwortet Asterisk auf der CLI? Ein Prozess, der laeuft, aber nicht
#    mehr antwortet, ist der unangenehmste Fall - systemd merkt davon
#    nichts.
if ! gg_asterisk_running; then
	WD_STATE="Asterisk antwortet nicht"
	WD_FAILS=$((WD_FAILS + 1))
	wlog "Asterisk laeuft, antwortet aber nicht auf der CLI (Fehlversuch ${WD_FAILS})."
	if [ "$WD_FAILS" -ge 2 ] && may_act "asterisk-restart" 300; then
		action_restart_asterisk
	fi
	save_state
	exit 0
fi

# 3. Ist chan_mobile geladen?
if ! gg_asterisk_cli 'module show like chan_mobile' 2>/dev/null | grep -q 'chan_mobile.so'; then
	WD_STATE="chan_mobile nicht geladen"
	WD_FAILS=$((WD_FAILS + 1))
	wlog "chan_mobile ist nicht geladen (Fehlversuch ${WD_FAILS})."
	if call_in_progress; then
		wlog "Es laeuft ein Gespraech - keine Massnahme."
	elif may_act "chan_mobile-load" 300; then
		record_action "chan_mobile-load"
		if ! gg_asterisk_cli 'module load chan_mobile.so' >/dev/null 2>&1; then
			wlog "'module load chan_mobile.so' fehlgeschlagen."
			if [ "$WD_FAILS" -ge "$ESCALATE_RESTART" ] && may_act "asterisk-restart" 600; then
				action_restart_asterisk
			fi
		fi
	fi
	save_state
	exit 0
fi

# 4. Ist ueberhaupt ein Telefon eingerichtet?
PHONE_MAC="$(gg_fact_get phone_mac '')"
if [ -z "$PHONE_MAC" ]; then
	WD_STATE="kein iPhone eingerichtet"
	WD_FAILS=0
	save_state
	exit 0
fi

# 5. Ist das Telefon verbunden?
MOBILE_LINE="$(gg_asterisk_cli 'mobile show devices' 2>/dev/null |
	awk -v id="$GG_MOBILE_ID" 'NR>1 && $1==id {print; exit}')"

if [ -z "$MOBILE_LINE" ]; then
	WD_STATE="Geraet ${GG_MOBILE_ID} nicht in chan_mobile"
	WD_FAILS=$((WD_FAILS + 1))
	wlog "chan_mobile kennt kein Geraet '${GG_MOBILE_ID}' (Fehlversuch ${WD_FAILS})."
	if ! call_in_progress && [ "$WD_FAILS" -ge "$ESCALATE_RELOAD" ] && may_act "chan_mobile-reload" 300; then
		action_reload_module
	fi
	save_state
	exit 0
fi

CONNECTED="$(printf '%s' "$MOBILE_LINE" | awk '{print $5}')"
DEVSTATE="$(printf '%s' "$MOBILE_LINE" | awk '{print $6}')"

if [ "$CONNECTED" = "Yes" ]; then
	# Alles in Ordnung. Zaehler zuruecksetzen - aber nur einmal melden,
	# damit das Protokoll nicht jede Minute eine Zeile bekommt.
	if [ "$WD_FAILS" -gt 0 ]; then
		wlog "Verbindung wieder da (nach ${WD_FAILS} Fehlversuchen, letzte Massnahme: ${WD_LAST_ACTION})."
	fi
	WD_FAILS=0
	if [ "$DEVSTATE" = "No" ] || [ "$DEVSTATE" = "Service" ]; then
		WD_STATE="verbunden, aber kein Mobilfunknetz"
	else
		WD_STATE="verbunden (${DEVSTATE})"
	fi
	save_state
	exit 0
fi

# --- Ab hier: Telefon nicht verbunden --------------------------------
WD_FAILS=$((WD_FAILS + 1))
WD_STATE="iPhone nicht verbunden (seit ${WD_FAILS} Minuten)"

if call_in_progress; then
	wlog "Nicht verbunden, aber es laeuft ein Gespraech - keine Massnahme."
	save_state
	exit 0
fi

if [ "$WD_FAILS" -eq 1 ]; then
	wlog "iPhone nicht verbunden. chan_mobile versucht es selbst alle 30 Sekunden - erst einmal abwarten."
fi

if [ "$WD_FAILS" -ge "$ESCALATE_GIVEUP" ]; then
	if [ "$WD_LAST_ACTION" != "aufgegeben" ]; then
		record_action "aufgegeben"
		wlog "Nach ${WD_FAILS} Minuten ohne Erfolg werden keine weiteren Massnahmen ergriffen."
		wlog "Bitte pruefen: iPhone in Reichweite? Bluetooth an? Mit dem Auto verbunden?"
		wlog "Hilfe: sudo bluetooth-check"
	fi
	WD_STATE="iPhone nicht verbunden - Watchdog hat aufgegeben"
	save_state
	exit 0
fi

if [ "$WD_FAILS" -ge "$ESCALATE_ADAPTER" ] && may_act "adapter-reset" 900; then
	action_reset_adapter
elif [ "$WD_FAILS" -ge "$ESCALATE_RESTART" ] && may_act "asterisk-restart" 600; then
	action_restart_asterisk
elif [ "$WD_FAILS" -ge "$ESCALATE_RELOAD" ] && may_act "chan_mobile-reload" 300; then
	action_reload_module
elif [ "$WD_FAILS" -ge "$ESCALATE_CONNECT" ] && may_act "bluez-connect" 180; then
	action_bluez_connect
fi

save_state
exit 0
