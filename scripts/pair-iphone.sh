#!/usr/bin/env bash
# =====================================================================
#  pair-iphone.sh - iPhone mit dem Gateway koppeln
#
#  Dieses Script koppelt NIEMALS selbstaendig irgendein Geraet.
#  Es zeigt die gefundenen Geraete an, der Benutzer waehlt aus und
#  muss die Auswahl ausdruecklich bestaetigen.
#
#  Ablauf:
#     1. Bluetooth einschalten
#     2. Geraete suchen
#     3. Geraete anzeigen
#     4. Benutzer waehlt das iPhone
#     5. Pairing (interaktiv, mit Bestaetigung auf beiden Seiten)
#     6. Trust setzen
#     7. Verbindung versuchen
#     8. Bluetooth-Informationen auslesen
#     9. HFP pruefen  -> ohne HFP wird hier abgebrochen
#    10. RFCOMM-Kanal ermitteln und chan_mobile.conf schreiben
#
#  Aufruf:
#     sudo pair-iphone
#     sudo pair-iphone --from-iphone      Kopplung vom iPhone aus starten
#     sudo pair-iphone --device AA:BB:..  bereits bekannte MAC verwenden
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

gg_strict
gg_require_root
gg_ensure_dirs
gg_load_config
gg_log_target "$GG_BLUETOOTH_LOG"

# shellcheck disable=SC2034
GG_CURRENT_STEP="iPhone koppeln"

ASTERISK_ETC="/etc/asterisk"
BACKUP_ROOT="${ASTERISK_ETC}/backup"
HFP_AG_UUID="0000111f"
HSP_AG_UUID="00001112"

MODE="scan"
PHONE_MAC=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--from-iphone) MODE="from-iphone" ;;
	--device)
		shift
		PHONE_MAC="$(printf '%s' "${1:-}" | tr 'a-f' 'A-F')"
		MODE="direct"
		;;
	-h | --help)
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'Unbekannte Option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

# ---------------------------------------------------------------------
#  Hilfsfunktionen
# ---------------------------------------------------------------------

strip_ansi() {
	sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

# Fuehrt eine Folge von bluetoothctl-Befehlen in EINER Sitzung aus.
# "select" wirkt nur innerhalb einer Sitzung - deshalb immer zuerst.
#
# Der Rueckgabewert von bluetoothctl ist bewusst nicht massgeblich:
# das Werkzeug liefert auch bei erfolgreichen Aktionen wechselnde
# Exit-Codes. Jede Aktion wird deshalb im Anschluss ueber "info"
# ueberprueft - dort entscheidet sich Erfolg oder Misserfolg.
bt_run() {
	local timeout_s="$1"
	shift
	local cmd rc=0
	{
		printf 'select %s\n' "$ADAPTER_MAC"
		for cmd in "$@"; do
			printf '%s\n' "$cmd"
		done
		# Kurz warten, damit asynchrone Antworten noch ankommen.
		sleep 2
	} | timeout "${timeout_s}s" bluetoothctl 2>&1 | strip_ansi || rc=$?
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
		printf '(bluetoothctl endete mit Code %s)\n' "$rc" >>"$GG_BLUETOOTH_LOG"
	fi
	return 0
}

# Sucht "$1" Sekunden lang nach Geraeten.
# Der sleep laeuft in der Shell, nicht in bluetoothctl - damit bleibt
# die Eingabe offen und die Suche laeuft weiter. Das funktioniert auch
# mit BlueZ-Versionen, die die Option --timeout nicht kennen.
bt_scan() {
	local seconds="$1" rc=0
	{
		printf 'select %s\n' "$ADAPTER_MAC"
		printf 'scan on\n'
		sleep "$seconds"
		printf 'scan off\n'
		sleep 1
	} | timeout "$((seconds + 25))s" bluetoothctl >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
		gg_warn "Der Suchlauf endete mit Code ${rc} - die Geraeteliste kann unvollstaendig sein."
	fi
	return 0
}

confirm() {
	local answer
	printf '%s [j/N]: ' "$1"
	read -r answer </dev/tty
	case "$answer" in
	j | J | ja | Ja | JA | y | Y | yes) return 0 ;;
	*) return 1 ;;
	esac
}

require_tty() {
	if [ ! -r /dev/tty ]; then
		gg_die "Dieses Script braucht ein Terminal. Bitte direkt per SSH oder an der Konsole starten."
	fi
}

# ---------------------------------------------------------------------
#  Vorbereitung
# ---------------------------------------------------------------------
require_tty

if ! command -v bluetoothctl >/dev/null 2>&1; then
	gg_die "bluetoothctl fehlt. Bitte zuerst die Installation abschliessen."
fi
if ! gg_service_active bluetooth.service; then
	gg_info "bluetooth.service wird gestartet ..."
	if ! systemctl start bluetooth.service; then
		gg_die "bluetooth.service laesst sich nicht starten."
	fi
fi

ADAPTER="$(gg_fact_get bt_adapter '')"
if [ -z "$ADAPTER" ] || [ ! -e "/sys/class/bluetooth/${ADAPTER}" ]; then
	if ! ADAPTER="$(gg_bt_select_adapter)"; then
		gg_die "Kein Bluetooth-Adapter gefunden. Ist der ASUS USB-BT500 eingesteckt?"
	fi
fi
ADAPTER_MAC="$(gg_bt_address "$ADAPTER")"
if [ -z "$ADAPTER_MAC" ]; then
	gg_die "Adapter ${ADAPTER} liefert keine MAC-Adresse."
fi

# Voice Setting sicherstellen - sonst nimmt chan_mobile den Adapter nicht.
if ! "${GG_PREFIX}/scripts/gateway-hci-prepare.sh" "$ADAPTER" >/dev/null; then
	gg_warn "Der Adapter konnte nicht vollstaendig vorbereitet werden - Pairing wird trotzdem versucht."
fi

gg_headline "iPhone mit dem GSM-Gateway koppeln"
printf 'Adapter:  %s (%s)\n' "$ADAPTER" "$ADAPTER_MAC"
printf 'Gateway:  %s\n\n' "$GG_BT_NAME"

cat <<'INTRO'
Bitte jetzt am iPhone:

  1. Einstellungen  ->  Bluetooth
  2. Bluetooth einschalten
  3. Diesen Bildschirm GEOEFFNET LASSEN

Das ist wichtig: Ein iPhone ist nur sichtbar, solange der
Bluetooth-Bildschirm offen ist. Sobald man ihn verlaesst,
verschwindet es wieder aus der Suche.

INTRO

if ! confirm "Ist der Bluetooth-Bildschirm am iPhone geoeffnet?"; then
	gg_info "Abgebrochen. Einfach erneut starten, wenn das iPhone bereit ist."
	exit 0
fi

bt_run 20 "power on" "agent KeyboardDisplay" "default-agent" "pairable on" >/dev/null

# ---------------------------------------------------------------------
#  1. Geraet auswaehlen
# ---------------------------------------------------------------------
select_device_by_scan() {
	gg_info "Suche ${GG_BT_SCAN_SECONDS} Sekunden nach Bluetooth-Geraeten ..."
	bt_scan "$GG_BT_SCAN_SECONDS"

	local devices
	# sed statt grep: kein Treffer ist hier kein Fehler, sondern nur
	# eine leere Liste - und die wird gleich darunter behandelt.
	devices="$(bt_run 15 "devices" | sed -n -E '/^Device [0-9A-Fa-f:]{17}/p')"
	if [ -z "$devices" ]; then
		gg_error "Es wurde kein einziges Bluetooth-Geraet gefunden."
		gg_error "Bitte pruefen:"
		gg_error "  * Ist Bluetooth am iPhone eingeschaltet?"
		gg_error "  * Ist der Bluetooth-Bildschirm noch geoeffnet?"
		gg_error "  * Steht das iPhone nahe genug beim Raspberry Pi?"
		gg_die "Keine Geraete gefunden."
	fi

	printf '\nGefundene Geraete:\n\n'
	local -a macs=() names=()
	local i=0 line mac name
	while IFS= read -r line; do
		mac="$(printf '%s' "$line" | awk '{print $2}')"
		name="$(printf '%s' "$line" | cut -d' ' -f3-)"
		# Geraetenamen kommen von fremden Geraeten in Funkreichweite und
		# koennen alles enthalten - auch Zeilenumbrueche, die eine
		# zusaetzliche "Device ..."-Zeile vortaeuschen. Nur echte
		# MAC-Adressen kommen in die Auswahl.
		if ! gg_is_mac "$mac"; then
			continue
		fi
		i=$((i + 1))
		macs+=("$mac")
		names+=("$name")
		printf '  %2d) %s   %s\n' "$i" "$mac" "$name"
	done <<<"$devices"

	if [ "$i" -eq 0 ]; then
		gg_die "Es wurde kein Geraet mit einer gueltigen MAC-Adresse gefunden."
	fi

	printf '\n   0) Abbrechen\n\n'

	local choice
	while true; do
		printf 'Welches Geraet ist das iPhone? Nummer eingeben: '
		read -r choice </dev/tty
		case "$choice" in
		0)
			gg_info "Abgebrochen - es wurde nichts gekoppelt."
			exit 0
			;;
		'' | *[!0-9]*)
			printf 'Bitte eine Zahl eingeben.\n'
			;;
		*)
			if [ "$choice" -ge 1 ] && [ "$choice" -le "${#macs[@]}" ]; then
				PHONE_MAC="${macs[$((choice - 1))]}"
				PHONE_NAME="${names[$((choice - 1))]}"
				break
			fi
			printf 'Bitte eine Zahl zwischen 1 und %d eingeben.\n' "${#macs[@]}"
			;;
		esac
	done

	printf '\nAusgewaehlt:\n'
	printf '  Name: %s\n' "$PHONE_NAME"
	printf '  MAC:  %s\n\n' "$PHONE_MAC"
	if ! confirm "Ist das wirklich das richtige iPhone?"; then
		gg_info "Abgebrochen - es wurde nichts gekoppelt."
		exit 0
	fi
}

wait_for_iphone_initiated() {
	gg_info "Der Raspberry Pi ist jetzt als '${GG_BT_NAME}' sichtbar."
	bt_run 15 "discoverable-timeout 0" "discoverable on" "pairable on" >/dev/null
	cat <<INTRO2

Bitte jetzt am iPhone:

  Einstellungen -> Bluetooth -> in der Liste "${GG_BT_NAME}" antippen

Erscheint eine Zahl auf dem iPhone, wird sie gleich auch hier
angezeigt - dann in beiden Faellen bestaetigen.

INTRO2
	local waited=0 found=""
	while [ "$waited" -lt 180 ]; do
		found="$(bt_run 15 "paired-devices" | sed -n -E '/^Device [0-9A-Fa-f:]{17}/p' | head -n1)"
		if [ -n "$found" ]; then
			PHONE_MAC="$(printf '%s' "$found" | awk '{print $2}')"
			PHONE_NAME="$(printf '%s' "$found" | cut -d' ' -f3-)"
			if ! gg_is_mac "$PHONE_MAC"; then
				gg_warn "Ignoriere Eintrag ohne gueltige MAC-Adresse."
				PHONE_MAC=""
				PHONE_NAME=""
			else
				gg_ok "Gekoppeltes Geraet erkannt: ${PHONE_NAME} (${PHONE_MAC})"
				return 0
			fi
		fi
		sleep 5
		waited=$((waited + 5))
	done
	bt_run 15 "discoverable off" >/dev/null
	gg_die "Innerhalb von 180 Sekunden hat sich kein Geraet gekoppelt."
}

PHONE_NAME=""
case "$MODE" in
scan) select_device_by_scan ;;
from-iphone) wait_for_iphone_initiated ;;
direct)
	if ! gg_is_mac "$PHONE_MAC"; then
		gg_die "'${PHONE_MAC}' ist keine gueltige MAC-Adresse (Format AA:BB:CC:DD:EE:FF)."
	fi
	PHONE_NAME="(per --device vorgegeben)"
	gg_info "Verwende vorgegebene MAC ${PHONE_MAC}."
	;;
esac

# Ab hier steht die MAC fest - vor jedem weiteren Schritt noch einmal
# pruefen, damit keine der drei Auswahlwege etwas Unerwartetes liefert.
if ! gg_is_mac "$PHONE_MAC"; then
	gg_die "Interner Fehler: '${PHONE_MAC}' ist keine gueltige MAC-Adresse."
fi

# ---------------------------------------------------------------------
#  2. Pairing
# ---------------------------------------------------------------------
is_paired() {
	bt_run 15 "info ${PHONE_MAC}" | awk '$1=="Paired:" {print $2; exit}' | grep -q '^yes$'
}

if is_paired; then
	gg_ok "${PHONE_MAC} ist bereits gekoppelt - das Pairing wird uebersprungen."
else
	cat <<PAIRHELP

-------------------------------------------------------------
Jetzt startet das Pairing. Es oeffnet sich eine interaktive
bluetoothctl-Sitzung.

  * Erscheint hier eine Frage wie
        Confirm passkey 123456 (yes/no):
    dann  yes  eingeben und Enter druecken.
  * Am iPhone erscheint "Koppeln" - dort ebenfalls bestaetigen.
  * Sobald "Pairing successful" erscheint:  quit  eingeben.

Falls nichts passiert: mit  quit  beenden und erneut versuchen.
-------------------------------------------------------------

PAIRHELP
	pair_rc=0
	{
		printf 'select %s\n' "$ADAPTER_MAC"
		printf 'power on\n'
		printf 'agent KeyboardDisplay\n'
		printf 'default-agent\n'
		printf 'pairable on\n'
		printf 'pair %s\n' "$PHONE_MAC"
		cat </dev/tty
	} | timeout 300s bluetoothctl || pair_rc=$?

	if [ "$pair_rc" -eq 124 ]; then
		gg_warn "Die Pairing-Sitzung lief in die Zeitbegrenzung (5 Minuten)."
	fi

	if ! is_paired; then
		gg_error "Haeufige Ursachen:"
		gg_error "  * Am iPhone wurde 'Koppeln' nicht bestaetigt"
		gg_error "  * Der Bluetooth-Bildschirm am iPhone war geschlossen"
		gg_error "  * Ein alter Eintrag stoert - am iPhone unter Bluetooth beim"
		gg_error "    Eintrag '${GG_BT_NAME}' auf 'Dieses Geraet ignorieren' tippen"
		gg_error "    und hier vorher ausfuehren: bluetoothctl remove ${PHONE_MAC}"
		gg_die "Das Pairing mit ${PHONE_MAC} war nicht erfolgreich."
	fi
fi
gg_ok "Pairing steht."

# ---------------------------------------------------------------------
#  3. Trust setzen
# ---------------------------------------------------------------------
bt_run 15 "trust ${PHONE_MAC}" >/dev/null
if bt_run 15 "info ${PHONE_MAC}" | awk '$1=="Trusted:" {print $2; exit}' | grep -q '^yes$'; then
	gg_ok "Trust gesetzt - der Pi akzeptiert Verbindungen des iPhones ohne Rueckfrage."
else
	gg_die "Trust konnte fuer ${PHONE_MAC} nicht gesetzt werden."
fi

# Sichtbarkeit wieder abschalten - ein dauerhaft sichtbares Gateway
# ist unnoetig angreifbar.
bt_run 15 "discoverable off" >/dev/null

# ---------------------------------------------------------------------
#  4. Verbindung versuchen
# ---------------------------------------------------------------------
gg_info "Versuche eine Verbindung aufzubauen ..."
CONNECT_OUT="$(bt_run 30 "connect ${PHONE_MAC}")"
if printf '%s' "$CONNECT_OUT" | grep -qi 'Connection successful'; then
	gg_ok "BlueZ hat eine Verbindung aufgebaut."
else
	gg_warn "BlueZ konnte keine Profilverbindung aufbauen."
	gg_warn "Das ist hier NORMAL und kein Fehler: auf dem Gateway laeuft"
	gg_warn "bewusst kein Bluetooth-Audiodienst, der ein Profil annehmen"
	gg_warn "wuerde. Die eigentliche Sprachverbindung baut chan_mobile"
	gg_warn "spaeter selbst auf. Entscheidend ist der HFP-Test gleich."
fi

# ---------------------------------------------------------------------
#  5. Informationen auslesen und HFP pruefen
# ---------------------------------------------------------------------
INFO="$(bt_run 15 "info ${PHONE_MAC}")"
{
	printf '\n===== Pairing %s =====\n' "$(gg_timestamp)"
	printf '%s\n' "$INFO"
} >>"$GG_BLUETOOTH_LOG"

printf '\n'
gg_headline "Bluetooth-Informationen"
printf '%s\n' "$INFO" | grep -E '^\s*(Name|Alias|Class|Icon|Paired|Bonded|Trusted|Blocked|Connected|UUID):' | sed 's/^/  /'

if [ -z "$PHONE_NAME" ] || [ "$PHONE_NAME" = "(per --device vorgegeben)" ]; then
	PHONE_NAME="$(printf '%s\n' "$INFO" | awk '$1=="Name:" {$1=""; sub(/^ /,""); print; exit}')"
fi

printf '\n'
if printf '%s' "$INFO" | grep -qi "$HFP_AG_UUID"; then
	gg_ok "HFP erkannt: das iPhone bietet 'Handsfree Audio Gateway' an."
else
	printf '\n'
	printf '=======================================================\n'
	printf ' HFP NICHT VERFUEGBAR\n'
	printf '=======================================================\n\n'
	printf 'Das iPhone ist per Bluetooth verbunden, aber der benötigte\n'
	printf 'HFP-Telefoniedienst wurde nicht erkannt.\n\n'
	if printf '%s' "$INFO" | grep -qi "$HSP_AG_UUID"; then
		printf 'Gefunden wurde nur HSP (Headset Profile). Damit lassen sich\n'
		printf 'keine Anrufe steuern - chan_mobile braucht HFP.\n\n'
	fi
	printf 'Moegliche Ursachen und Abhilfe:\n\n'
	printf '  1. Der Pi gibt sich nicht als Freisprecheinrichtung aus.\n'
	printf '     Pruefen:  grep Class /etc/bluetooth/main.conf\n'
	printf '     Erwartet: Class = %s\n' "$GG_BT_CLASS"
	printf '     Beheben:  sudo %s/install/install-bluetooth.sh configure\n\n' "$GG_PREFIX"
	printf '  2. Das iPhone hat die Dienste noch nicht veroeffentlicht.\n'
	printf '     Am iPhone unter Bluetooth beim Eintrag "%s" auf das\n' "$GG_BT_NAME"
	printf '     (i) tippen -> "Dieses Geraet ignorieren", dann hier:\n'
	printf '        sudo bluetoothctl remove %s\n' "$PHONE_MAC"
	printf '     und anschliessend  sudo pair-iphone  erneut ausfuehren.\n\n'
	printf '  3. Manche iOS-Versionen bieten HFP erst nach einem Neustart\n'
	printf '     des iPhones wieder an.\n\n'
	printf 'Es wird ausdruecklich KEINE Asterisk-Konfiguration geschrieben,\n'
	printf 'die Telefonie nur vortaeuschen wuerde.\n\n'
	printf '=======================================================\n\n'
	gg_fact_set phone_hfp "no"
	gg_die "HFP-Telefoniedienst am iPhone nicht erkannt - Abbruch."
fi
gg_fact_set phone_hfp "yes"

# ---------------------------------------------------------------------
#  6. RFCOMM-Kanal ermitteln
# ---------------------------------------------------------------------
# chan_mobile braucht zwingend "port=<Kanal>". Der Wert wird ermittelt,
# niemals geraten.
find_rfcomm_port() {
	local port=""

	# a) eigener SDP-Client (funktioniert ohne die veralteten BlueZ-Tools)
	if port="$("${GG_PREFIX}/lib/sdp-rfcomm.py" "$PHONE_MAC" 111f 2>/dev/null)"; then
		if [ -n "$port" ]; then
			gg_info "RFCOMM-Kanal per SDP ermittelt: ${port}"
			printf '%s' "$port"
			return 0
		fi
	fi

	# b) sdptool, falls vorhanden
	if command -v sdptool >/dev/null 2>&1; then
		port="$(sdptool search --bdaddr "$PHONE_MAC" HFAG 2>/dev/null |
			awk '/Channel:/ {print $2; exit}')"
		if [ -n "$port" ]; then
			gg_info "RFCOMM-Kanal per sdptool ermittelt: ${port}"
			printf '%s' "$port"
			return 0
		fi
	fi

	# c) Asterisk selbst fragen (setzt voraus, dass das iPhone gerade
	#    sichtbar ist, weil "mobile search" einen Inquiry durchfuehrt)
	if gg_asterisk_running; then
		port="$(gg_asterisk_cli 'mobile search' |
			awk -v mac="$PHONE_MAC" 'toupper($1)==mac {print $NF; exit}')"
		if [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null; then
			gg_info "RFCOMM-Kanal ueber 'mobile search' ermittelt: ${port}"
			printf '%s' "$port"
			return 0
		fi
	fi

	return 1
}

gg_info "Ermittle den RFCOMM-Kanal des Handsfree-Dienstes ..."
if ! RFCOMM_PORT="$(find_rfcomm_port)"; then
	gg_error "Der RFCOMM-Kanal liess sich nicht ermitteln."
	gg_error "Bitte pruefen:"
	gg_error "  * iPhone in Reichweite und Bluetooth-Bildschirm geoeffnet?"
	gg_error "  * Manuell versuchen: sudo ${GG_PREFIX}/lib/sdp-rfcomm.py ${PHONE_MAC}"
	gg_die "Ohne RFCOMM-Kanal kann chan_mobile nicht konfiguriert werden."
fi
case "$RFCOMM_PORT" in
'' | *[!0-9]*) gg_die "Ermittelter RFCOMM-Kanal '${RFCOMM_PORT}' ist keine Zahl." ;;
esac
gg_ok "RFCOMM-Kanal: ${RFCOMM_PORT}"

# ---------------------------------------------------------------------
#  7. chan_mobile.conf ergaenzen
# ---------------------------------------------------------------------
CONF_NAME="$(gg_chan_mobile_conf_name)"
CONF_PATH="${ASTERISK_ETC}/${CONF_NAME}"
if [ ! -f "$CONF_PATH" ]; then
	gg_die "${CONF_PATH} fehlt. Bitte zuerst ausfuehren: sudo ${GG_PREFIX}/install/setup-chan-mobile.sh"
fi

ADAPTER_ID="$(gg_fact_get adapter_id 'bt500')"

gg_backup_file "$CONF_PATH" "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"

# Einen vorhandenen Block mit derselben ID entfernen, damit keine
# doppelten Abschnitte entstehen.
TMP_CONF="$(mktemp)"
awk -v id="[${GG_MOBILE_ID}]" '
	/^\[/ { in_block = ($0 == id) }
	!in_block { print }
' "$CONF_PATH" >"$TMP_CONF"

DEVICE_BLOCK="$(mktemp)"
if ! gg_render_template "${GG_PREFIX}/asterisk/mobile-device.conf.template" "$DEVICE_BLOCK" \
	"MOBILE_ID=${GG_MOBILE_ID}" \
	"PHONE_MAC=${PHONE_MAC}" \
	"RFCOMM_PORT=${RFCOMM_PORT}" \
	"MOBILE_CONTEXT=${GG_MOBILE_CONTEXT}" \
	"ADAPTER_ID=${ADAPTER_ID}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	rm -f "$TMP_CONF" "$DEVICE_BLOCK"
	gg_die "Der Geraeteblock fuer chan_mobile.conf konnte nicht erzeugt werden."
fi

{
	cat "$TMP_CONF"
	printf '\n'
	cat "$DEVICE_BLOCK"
} >"$CONF_PATH"
rm -f "$TMP_CONF" "$DEVICE_BLOCK"

if getent passwd asterisk >/dev/null; then
	chown asterisk:asterisk "$CONF_PATH"
fi
chmod 0640 "$CONF_PATH"

gg_ok "${CONF_PATH} ergaenzt:"
printf '\n'
sed -n "/^\[${GG_MOBILE_ID}\]/,/^$/p" "$CONF_PATH" | sed 's/^/    /'
printf '\n'

gg_fact_set phone_mac "$PHONE_MAC"
gg_fact_set phone_name "$PHONE_NAME"
gg_fact_set rfcomm_port "$RFCOMM_PORT"

# ---------------------------------------------------------------------
#  8. Asterisk neu laden und pruefen
# ---------------------------------------------------------------------
if gg_asterisk_running; then
	gg_info "Lade chan_mobile in Asterisk neu ..."
	if ! gg_asterisk_cli 'module reload chan_mobile.so' >/dev/null; then
		gg_warn "'module reload chan_mobile.so' meldete einen Fehler - versuche einen Neustart von Asterisk."
		if ! systemctl restart asterisk.service; then
			gg_die "asterisk.service liess sich nicht neu starten."
		fi
	fi

	gg_info "Warte, bis chan_mobile das iPhone verbindet (bis zu 60 Sekunden) ..."
	waited=0
	while [ "$waited" -lt 60 ]; do
		if gg_asterisk_cli 'mobile show devices' |
			awk -v id="$GG_MOBILE_ID" 'NR>1 && $1==id && $5=="Yes" {found=1} END {exit !found}'; then
			break
		fi
		sleep 5
		waited=$((waited + 5))
	done

	printf '\n'
	gg_asterisk_cli 'mobile show devices' | sed 's/^/    /'
	printf '\n'

	if gg_asterisk_cli 'mobile show devices' |
		awk -v id="$GG_MOBILE_ID" 'NR>1 && $1==id && $5=="Yes" {found=1} END {exit !found}'; then
		gg_ok "chan_mobile hat das iPhone verbunden."
	else
		gg_warn "chan_mobile hat das iPhone noch nicht verbunden."
		gg_warn "chan_mobile versucht es alle 30 Sekunden erneut (interval=30)."
		gg_warn "Bitte pruefen:"
		gg_warn "  * iPhone in Reichweite, Bluetooth an"
		gg_warn "  * am iPhone unter Bluetooth steht '${GG_BT_NAME}' als verbunden"
		gg_warn "  * sudo bluetooth-check"
	fi
else
	gg_warn "Asterisk laeuft nicht - die Konfiguration wurde geschrieben,"
	gg_warn "wird aber erst beim naechsten Start wirksam."
fi

# ---------------------------------------------------------------------
#  Abschluss
# ---------------------------------------------------------------------
cat <<SUMMARY

=======================================================
 iPhone eingerichtet
=======================================================

  Name:           ${PHONE_NAME}
  MAC:            ${PHONE_MAC}
  RFCOMM-Kanal:   ${RFCOMM_PORT}
  Adapter:        ${ADAPTER} (${ADAPTER_MAC})
  chan_mobile-ID: ${GG_MOBILE_ID}

Naechste Schritte:

  1. Gesamtstatus pruefen:      sudo gateway-test
  2. Testanruf auf die Schweizer SIM (Test A)
  3. Testanruf von SIP ${GG_SIP_EXTENSION} nach draussen (Test B)

Zugangsdaten fuer das Softphone:  sudo gateway-credentials

=======================================================

SUMMARY

gg_ok "Kopplung abgeschlossen."
