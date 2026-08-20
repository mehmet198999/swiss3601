#!/usr/bin/env bash
# =====================================================================
#  setup-sip.sh - lokales SIP einrichten und Asterisk starten
#
#  Grundsatz (Anforderung 17): Es entsteht KEIN offener SIP-Server.
#    * PJSIP lauscht nur auf der LAN-Adresse, nicht auf 0.0.0.0
#    * eine ACL laesst nur die konfigurierten LAN-Netze zu
#    * es gibt keinen anonymen Endpunkt
#    * das Passwort wird zufaellig erzeugt und steht nirgends im Code
#    * Mehrwertnummern sind im Dialplan gesperrt
#
#  Erzeugt:  pjsip.conf, rtp.conf, extensions.conf
#  Sichert vorher nach /etc/asterisk/backup/JJJJ-MM-TT-HH-MM-SS/
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

gg_strict
gg_require_root
gg_ensure_dirs
gg_load_config
gg_log_target "$GG_ASTERISK_LOG"

# shellcheck disable=SC2034
GG_CURRENT_STEP="SIP einrichten"

ASTERISK_ETC="/etc/asterisk"
BACKUP_ROOT="${ASTERISK_ETC}/backup"
SECRET_FILE="${GG_SECRET_DIR}/sip-${GG_SIP_EXTENSION}.conf"

gg_headline "SIP einrichten (nur LAN)"

# ---------------------------------------------------------------------
# 1. LAN-Adresse bestimmen
# ---------------------------------------------------------------------
LAN_IP="$(gg_primary_ip)"
if [ -z "$LAN_IP" ]; then
	gg_die "Keine LAN-IP-Adresse gefunden. Ohne feste Adresse kann PJSIP nicht LAN-gebunden lauschen."
fi
gg_info "PJSIP wird an ${LAN_IP}:${GG_SIP_PORT} gebunden (NICHT an 0.0.0.0)."
gg_fact_set sip_bind_ip "$LAN_IP"

# ---------------------------------------------------------------------
# 2. Passwort erzeugen bzw. vorhandenes weiterverwenden
# ---------------------------------------------------------------------
load_or_create_password() {
	if [ -r "$SECRET_FILE" ]; then
		# shellcheck source=/dev/null
		. "$SECRET_FILE"
		if [ -n "${SIP_PASSWORD:-}" ]; then
			gg_info "Vorhandenes SIP-Passwort aus ${SECRET_FILE} wird weiterverwendet."
			return 0
		fi
	fi

	SIP_PASSWORD="$(gg_generate_password "$GG_SIP_PASSWORD_LENGTH")"
	if [ "${#SIP_PASSWORD}" -lt 12 ]; then
		gg_die "Passwortgenerierung fehlgeschlagen (Ergebnis zu kurz)."
	fi

	umask 077
	cat >"$SECRET_FILE" <<SECRET
# SIP-Zugangsdaten des GSM-Gateways
# Erzeugt am $(gg_timestamp) - NICHT in ein Repository einchecken.
# Anzeigen mit:  sudo gateway-credentials
SIP_USERNAME="${GG_SIP_EXTENSION}"
SIP_PASSWORD="${SIP_PASSWORD}"
SIP_SERVER="${LAN_IP}"
SIP_PORT="${GG_SIP_PORT}"
SECRET
	chmod 0600 "$SECRET_FILE"
	chown root:root "$SECRET_FILE"
	gg_ok "Neues SIP-Passwort erzeugt (${#SIP_PASSWORD} Zeichen) und in ${SECRET_FILE} gespeichert."
}
load_or_create_password

# ---------------------------------------------------------------------
# 3. ACL- und Netzangaben aus GG_LAN_NETWORKS aufbauen
# ---------------------------------------------------------------------
ACL_PERMIT_LINES=""
LOCAL_NET_LINES=""
for net in $GG_LAN_NETWORKS; do
	case "$net" in
	*/*) ;;
	*)
		gg_die "GG_LAN_NETWORKS enthaelt '${net}' ohne Praefixlaenge. Erwartet wird z.B. 192.168.1.0/24."
		;;
	esac
	ACL_PERMIT_LINES="${ACL_PERMIT_LINES}permit=${net}"$'\n'
	LOCAL_NET_LINES="${LOCAL_NET_LINES}local_net=${net}"$'\n'
done
ACL_PERMIT_LINES="${ACL_PERMIT_LINES%$'\n'}"
LOCAL_NET_LINES="${LOCAL_NET_LINES%$'\n'}"
gg_info "Zugelassene Netze: ${GG_LAN_NETWORKS}"

# ---------------------------------------------------------------------
# 4. Gesperrte Rufnummern-Praefixe in Dialplan-Eintraege uebersetzen
# ---------------------------------------------------------------------
# Fuer jedes Praefix entstehen bis zu drei Muster, damit die Sperre
# auch bei internationaler Schreibweise greift:
#   0900...   ->  _0900.   _+41900.   _0041900.
#   00881...  ->  _00881.  _+881.
build_blocked_extensions() {
	local prefix rest out=""
	for prefix in $GG_BLOCKED_PREFIXES; do
		case "$prefix" in
		*[!0-9]*)
			gg_die "GG_BLOCKED_PREFIXES enthaelt '${prefix}' - erlaubt sind nur Ziffern."
			;;
		esac
		if [ "${#prefix}" -lt 3 ]; then
			gg_die "Praefix '${prefix}' ist zu kurz und wuerde viel zu viele Nummern sperren."
		fi

		out="${out}; --- gesperrt: ${prefix} ---"$'\n'
		out="${out}exten => _${prefix}.,1,NoOp(Gesperrtes Ziel \${EXTEN})"$'\n'
		out="${out} same => n,Hangup(21)"$'\n'

		case "$prefix" in
		00*)
			rest="${prefix#00}"
			out="${out}exten => _+${rest}.,1,NoOp(Gesperrtes Ziel \${EXTEN})"$'\n'
			out="${out} same => n,Hangup(21)"$'\n'
			;;
		0*)
			rest="${prefix#0}"
			out="${out}exten => _+41${rest}.,1,NoOp(Gesperrtes Ziel \${EXTEN})"$'\n'
			out="${out} same => n,Hangup(21)"$'\n'
			out="${out}exten => _0041${rest}.,1,NoOp(Gesperrtes Ziel \${EXTEN})"$'\n'
			out="${out} same => n,Hangup(21)"$'\n'
			;;
		esac
	done
	printf '%s' "${out%$'\n'}"
}
BLOCKED_EXTENSIONS="$(build_blocked_extensions)"

# ---------------------------------------------------------------------
# 5. Konfigurationsdateien schreiben
# ---------------------------------------------------------------------
backup_conf() {
	local f stamp dir
	stamp="$(date '+%Y-%m-%d-%H-%M-%S')"
	dir="${BACKUP_ROOT}/${stamp}-sip"
	for f in pjsip.conf rtp.conf extensions.conf; do
		if [ -f "${ASTERISK_ETC}/${f}" ]; then
			mkdir -p "$dir"
			cp -a "${ASTERISK_ETC}/${f}" "$dir/"
		fi
	done
	if [ -d "$dir" ]; then
		chmod 0700 "$BACKUP_ROOT"
		gg_ok "SIP-Konfiguration gesichert nach ${dir}"
	fi
}
backup_conf

if ! gg_render_template "${GG_PREFIX}/asterisk/pjsip.conf.template" "${ASTERISK_ETC}/pjsip.conf" \
	"LAN_IP=${LAN_IP}" \
	"SIP_PORT=${GG_SIP_PORT}" \
	"SIP_EXTENSION=${GG_SIP_EXTENSION}" \
	"SIP_PASSWORD=${SIP_PASSWORD}" \
	"LOCAL_NET_LINES=${LOCAL_NET_LINES}" \
	"ACL_PERMIT_LINES=${ACL_PERMIT_LINES}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "pjsip.conf konnte nicht erzeugt werden."
fi
chmod 0640 "${ASTERISK_ETC}/pjsip.conf"
gg_ok "pjsip.conf geschrieben (Bind ${LAN_IP}:${GG_SIP_PORT}, ACL aktiv)."

if ! gg_render_template "${GG_PREFIX}/asterisk/rtp.conf.template" "${ASTERISK_ETC}/rtp.conf" \
	"RTP_START=${GG_RTP_START}" \
	"RTP_END=${GG_RTP_END}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "rtp.conf konnte nicht erzeugt werden."
fi
gg_ok "rtp.conf geschrieben (RTP ${GG_RTP_START}-${GG_RTP_END})."

if ! gg_render_template "${GG_PREFIX}/asterisk/extensions.conf.template" "${ASTERISK_ETC}/extensions.conf" \
	"MOBILE_ID=${GG_MOBILE_ID}" \
	"MOBILE_CONTEXT=${GG_MOBILE_CONTEXT}" \
	"SIP_EXTENSION=${GG_SIP_EXTENSION}" \
	"MAX_OUTGOING=${GG_MAX_OUTGOING_CALLS}" \
	"BLOCKED_EXTENSIONS=${BLOCKED_EXTENSIONS}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "extensions.conf konnte nicht erzeugt werden."
fi
gg_ok "extensions.conf geschrieben (Dialplan inkl. Sperrliste)."

if getent passwd asterisk >/dev/null; then
	chown asterisk:asterisk "${ASTERISK_ETC}"/pjsip.conf "${ASTERISK_ETC}"/rtp.conf "${ASTERISK_ETC}"/extensions.conf
fi

# ---------------------------------------------------------------------
# 6. WireGuard-Struktur vorbereiten (NICHT aktivieren)
# ---------------------------------------------------------------------
# Anforderung 18: nur vorbereiten. Es wird nichts gestartet, kein
# Schluessel erzeugt und keine Verbindung aufgebaut, solange die lokale
# Telefonie nicht funktioniert.
WG_DIR="${GG_ETC_DIR}/wireguard"
mkdir -p "$WG_DIR"
chmod 0700 "$WG_DIR"
if [ ! -f "${WG_DIR}/README.txt" ]; then
	install -m 0600 "${GG_PREFIX}/config/wireguard-README.txt" "${WG_DIR}/README.txt"
fi
gg_info "WireGuard-Struktur vorbereitet unter ${WG_DIR} (bewusst NICHT aktiviert)."

# ---------------------------------------------------------------------
# 7. Asterisk starten und pruefen
# ---------------------------------------------------------------------
gg_info "Aktiviere und starte asterisk.service ..."
systemctl enable asterisk.service
if ! systemctl restart asterisk.service; then
	gg_error "Letzte Zeilen aus dem Journal:"
	journalctl -u asterisk.service -n 30 --no-pager 2>&1 | sed 's/^/    /'
	gg_die "asterisk.service startet nicht."
fi

waited=0
while [ "$waited" -lt 90 ]; do
	if gg_asterisk_running; then
		break
	fi
	sleep 3
	waited=$((waited + 3))
done
if ! gg_asterisk_running; then
	gg_error "Letzte Zeilen aus dem Journal:"
	journalctl -u asterisk.service -n 30 --no-pager 2>&1 | sed 's/^/    /'
	gg_die "Asterisk antwortet nach ${waited}s nicht auf der CLI."
fi
gg_ok "Asterisk laeuft: $(gg_asterisk_cli 'core show version' | head -n1)"

# --- chan_mobile geladen? ---
if gg_asterisk_cli 'module show like chan_mobile' | grep -q 'chan_mobile.so'; then
	gg_ok "Modul chan_mobile ist geladen."
	gg_fact_set chan_mobile_loaded "yes"
else
	gg_fact_set chan_mobile_loaded "no"
	gg_warn "chan_mobile ist NICHT geladen. Haeufigste Ursachen:"
	gg_warn "  * Voice Setting des Adapters ist nicht 0x0060"
	gg_warn "    pruefen: sudo gateway-hci-prepare.sh --show $(gg_fact_get bt_adapter hci0)"
	gg_warn "  * Adapter-MAC in ${ASTERISK_ETC}/$(gg_chan_mobile_conf_name) passt nicht"
	gg_warn "Details: sudo grep -i mobile /var/log/asterisk/messages"
fi

# --- PJSIP-Endpunkt vorhanden? ---
if gg_asterisk_cli 'pjsip show endpoints' | grep -q "${GG_SIP_EXTENSION}"; then
	gg_ok "SIP-Nebenstelle ${GG_SIP_EXTENSION} ist eingerichtet."
else
	gg_error "$(gg_asterisk_cli 'pjsip show endpoints')"
	gg_die "Die SIP-Nebenstelle ${GG_SIP_EXTENSION} taucht in Asterisk nicht auf."
fi

# --- Kontrolle: lauscht wirklich niemand auf 0.0.0.0:5060? ---
if command -v ss >/dev/null 2>&1; then
	if ss -lun 2>/dev/null | grep -qE "0\.0\.0\.0:${GG_SIP_PORT}\b|\*:${GG_SIP_PORT}\b"; then
		gg_error "$(ss -lun | grep "${GG_SIP_PORT}")"
		gg_die "SIP lauscht auf allen Adressen. Das ist ausdruecklich nicht gewollt."
	fi
	gg_ok "Kontrolle bestanden: SIP lauscht nicht auf 0.0.0.0:${GG_SIP_PORT}."
fi

gg_ok "SIP ist eingerichtet. Zugangsdaten anzeigen: sudo gateway-credentials"
