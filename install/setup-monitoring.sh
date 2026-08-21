#!/usr/bin/env bash
# =====================================================================
#  setup-monitoring.sh - Watchdog und Anrufliste einrichten
#
#  Zwei Dinge, die im Dauerbetrieb den Unterschied machen:
#
#  1. Watchdog
#     Ein iPhone trennt die HFP-Verbindung im Leerlauf, nach einem
#     iOS-Update oder wenn es zwischendurch im Auto war. Der Watchdog
#     merkt das und stellt die Verbindung gestuft wieder her - ohne
#     jemals ein laufendes Gespraech zu stoeren.
#
#  2. Anrufliste
#     Asterisk zeichnet jedes Gespraech auf. Ohne diese Aufzeichnung
#     sieht man nie, dass ein Anruf gar nicht erst angekommen ist.
#
#  Aufruf:  sudo setup-monitoring.sh
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

gg_strict
gg_require_root
gg_ensure_dirs
gg_load_config
gg_log_target "$GG_INSTALL_LOG"

# shellcheck disable=SC2034
GG_CURRENT_STEP="Ueberwachung einrichten"

ASTERISK_ETC="/etc/asterisk"
BACKUP_ROOT="${ASTERISK_ETC}/backup"

gg_headline "Watchdog und Anrufliste einrichten"

# ---------------------------------------------------------------------
# 1. Anrufaufzeichnung (CDR)
# ---------------------------------------------------------------------
if [ ! -d "$ASTERISK_ETC" ]; then
	gg_die "${ASTERISK_ETC} fehlt - Asterisk ist offenbar nicht installiert."
fi

gg_backup_file "${ASTERISK_ETC}/cdr.conf" "$BACKUP_ROOT"
if ! gg_render_template --mode 0640 \
	"${GG_PREFIX}/asterisk/cdr.conf.template" "${ASTERISK_ETC}/cdr.conf" \
	"CDR_ENABLE=${GG_CDR_ENABLE}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "cdr.conf konnte nicht erzeugt werden."
fi
if getent passwd asterisk >/dev/null; then
	chown asterisk:asterisk "${ASTERISK_ETC}/cdr.conf"
fi

if [ "$GG_CDR_ENABLE" = "yes" ]; then
	mkdir -p /var/log/asterisk/cdr-csv
	if getent passwd asterisk >/dev/null; then
		chown -R asterisk:asterisk /var/log/asterisk/cdr-csv
	fi
	# 0750: die Datei enthaelt Rufnummern und Zeitpunkte.
	chmod 0750 /var/log/asterisk/cdr-csv
	gg_ok "Anrufaufzeichnung aktiv (/var/log/asterisk/cdr-csv/Master.csv)."
else
	gg_info "Anrufaufzeichnung ist per Konfiguration abgeschaltet."
fi

# Logrotation, damit Master.csv nicht unbegrenzt waechst.
if getent passwd asterisk >/dev/null; then
	install -m 0644 "${GG_PREFIX}/etc/logrotate.d/gsm-gateway-cdr" \
		/etc/logrotate.d/gsm-gateway-cdr
	if ! logrotate --debug /etc/logrotate.d/gsm-gateway-cdr >/dev/null 2>&1; then
		rm -f /etc/logrotate.d/gsm-gateway-cdr
		gg_die "Die Logrotation fuer die Anrufliste wurde von logrotate abgelehnt."
	fi
	gg_ok "Logrotation fuer die Anrufliste eingerichtet."
fi

# Asterisk die neue Konfiguration mitteilen.
if gg_asterisk_running; then
	if gg_asterisk_cli 'module reload cdr' >/dev/null 2>&1; then
		gg_info "Asterisk hat die CDR-Konfiguration neu geladen."
	else
		gg_warn "'module reload cdr' schlug fehl - die Aufzeichnung greift spaetestens nach einem Neustart von Asterisk."
	fi
fi

# ---------------------------------------------------------------------
# 2. Watchdog
# ---------------------------------------------------------------------
install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-watchdog.service" \
	/etc/systemd/system/gsm-gateway-watchdog.service
install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-watchdog.timer" \
	/etc/systemd/system/gsm-gateway-watchdog.timer
systemctl daemon-reload

if [ "$GG_WATCHDOG_ENABLE" != "yes" ]; then
	gg_info "Watchdog ist per Konfiguration abgeschaltet (GG_WATCHDOG_ENABLE)."
	if systemctl is-enabled --quiet gsm-gateway-watchdog.timer 2>/dev/null; then
		systemctl disable --now gsm-gateway-watchdog.timer
		gg_info "Zuvor aktivierter Watchdog wurde abgeschaltet."
	fi
	exit 0
fi

systemctl enable gsm-gateway-watchdog.timer
if ! systemctl restart gsm-gateway-watchdog.timer; then
	gg_die "gsm-gateway-watchdog.timer laesst sich nicht starten."
fi

# Einmal sofort laufen lassen, damit ein erster Zustand vorliegt.
if ! systemctl start gsm-gateway-watchdog.service; then
	gg_warn "Der erste Watchdog-Lauf schlug fehl - der Timer versucht es in einer Minute erneut."
fi

if systemctl is-active --quiet gsm-gateway-watchdog.timer; then
	gg_ok "Watchdog aktiv - prueft jede Minute die Verbindung zum iPhone."
	gg_info "Zustand ansehen:  sudo gateway-watchdog --status"
	gg_info "Protokoll:        ${GG_LOG_DIR}/watchdog.log"
else
	gg_die "gsm-gateway-watchdog.timer ist nach dem Start nicht aktiv."
fi
