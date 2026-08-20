#!/usr/bin/env bash
# =====================================================================
#  setup-web.sh - lokale Statusseite einrichten
#
#      http://gsm-gateway.local
#
#  Aufbau:
#    gsm-gateway-status.timer  -> ruft alle 60 s gateway-test.sh --json
#                                 auf und legt /run/gsm-gateway/status.json ab
#    gsm-gateway-web.service   -> zeigt genau diese Datei an,
#                                 laeuft als unprivilegierter Benutzer
#
#  Der Webdienst hat damit keinerlei Rechte am System. Er liest eine
#  Datei und gibt sie formatiert aus - mehr nicht.
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
GG_CURRENT_STEP="Web-Statusseite einrichten"

WEB_USER="gsm-web"

gg_headline "Web-Statusseite einrichten"

if [ "$GG_WEB_ENABLE" != "yes" ]; then
	gg_info "GG_WEB_ENABLE=${GG_WEB_ENABLE} - die Statusseite wird nicht eingerichtet."
	if systemctl cat gsm-gateway-web.service >/dev/null 2>&1; then
		systemctl disable --now gsm-gateway-web.service
		gg_info "Eine zuvor eingerichtete Statusseite wurde abgeschaltet."
	fi
	exit 0
fi

# --- Statusdatenerzeugung (laeuft als root, schreibt nur eine Datei) ---
install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-status.service" \
	/etc/systemd/system/gsm-gateway-status.service
install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-status.timer" \
	/etc/systemd/system/gsm-gateway-status.timer

# --- unprivilegierter Benutzer fuer den Webdienst ---
if ! getent passwd "$WEB_USER" >/dev/null; then
	useradd --system --no-create-home --shell /usr/sbin/nologin "$WEB_USER"
	gg_info "Systembenutzer ${WEB_USER} angelegt."
fi

install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-web.service" \
	/etc/systemd/system/gsm-gateway-web.service

systemctl daemon-reload

systemctl enable --now gsm-gateway-status.timer
# Einmal sofort erzeugen, damit die Seite nicht leer startet.
if ! systemctl start gsm-gateway-status.service; then
	gg_warn "Die Statusdaten konnten nicht sofort erzeugt werden - der Timer versucht es erneut."
fi

systemctl enable gsm-gateway-web.service
if ! systemctl restart gsm-gateway-web.service; then
	gg_error "$(journalctl -u gsm-gateway-web.service -n 20 --no-pager 2>&1)"
	gg_die "Die Statusseite konnte nicht gestartet werden (Port ${GG_WEB_PORT} belegt?)."
fi

# Kurz pruefen, ob die Seite wirklich antwortet.
waited=0
while [ "$waited" -lt 20 ]; do
	if curl -fsS --max-time 3 "http://127.0.0.1:${GG_WEB_PORT}/health" >/dev/null 2>&1; then
		break
	fi
	sleep 2
	waited=$((waited + 2))
done

if curl -fsS --max-time 3 "http://127.0.0.1:${GG_WEB_PORT}/health" >/dev/null 2>&1; then
	gg_ok "Statusseite erreichbar: http://${GG_HOSTNAME}.local  (bzw. http://$(gg_primary_ip))"
else
	gg_warn "Die Statusseite antwortet nicht auf http://127.0.0.1:${GG_WEB_PORT}/health"
	gg_warn "Pruefen: sudo systemctl status gsm-gateway-web.service"
fi
