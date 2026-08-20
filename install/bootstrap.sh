#!/usr/bin/env bash
# =====================================================================
#  bootstrap.sh - Projekt auf dem Raspberry Pi einrichten
#
#  Kopiert das Projekt nach /opt/gsm-gateway, legt die Konfiguration
#  an, erzeugt die Befehle in /usr/local/bin und aktiviert den
#  First-Boot-Dienst. Die eigentliche Installation macht danach
#  firstboot-install.sh.
#
#  Wird in drei Situationen aufgerufen:
#
#   1. automatisch beim ersten Boot aus /boot/firmware/gsm-gateway/
#      (eingehaengt von prepare-sdcard.sh in die firstrun.sh des
#      Raspberry Pi Imagers)
#   2. von Hand nach einem "git clone" auf dem Pi
#   3. erneut, um Scripts und Dienste zu aktualisieren
#
#  Aufruf:
#     sudo ./install/bootstrap.sh              nur einrichten
#     sudo ./install/bootstrap.sh --run-now    einrichten und sofort
#                                              die Installation starten
# =====================================================================

set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="/opt/gsm-gateway"
UNIT_NAME="gsm-gateway-firstboot.service"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/gsm-gateway"

RUN_NOW="no"
if [ "${1:-}" = "--run-now" ]; then
	RUN_NOW="yes"
fi

log() { printf '[bootstrap] %s\n' "$*"; }
die() {
	printf '[bootstrap] FEHLER: %s\n' "$*" >&2
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die "Bitte mit sudo starten:  sudo $0"
fi

# --- Plausibilitaetspruefung der Quelle -------------------------------
for needed in install/firstboot-install.sh lib/common.sh systemd/"$UNIT_NAME"; do
	[ -e "${SOURCE_DIR}/${needed}" ] ||
		die "Die Projektdateien sind unvollstaendig - ${needed} fehlt in ${SOURCE_DIR}."
done

log "Quelle: ${SOURCE_DIR}"
log "Ziel:   ${TARGET_DIR}"

# --- Projekt nach /opt kopieren --------------------------------------
if [ "$SOURCE_DIR" != "$TARGET_DIR" ]; then
	mkdir -p "$TARGET_DIR"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete \
			--exclude '.git' --exclude '.github' \
			"${SOURCE_DIR}/" "${TARGET_DIR}/"
	else
		# rsync fehlt beim allerersten Boot moeglicherweise noch.
		find "$TARGET_DIR" -mindepth 1 -maxdepth 1 ! -name 'lost+found' -exec rm -rf {} +
		cp -a "${SOURCE_DIR}/." "${TARGET_DIR}/"
		rm -rf "${TARGET_DIR}/.git" "${TARGET_DIR}/.github"
	fi
	log "Projektdateien kopiert."
else
	log "Projekt liegt bereits am Zielort."
fi

chown -R root:root "$TARGET_DIR"
find "$TARGET_DIR" -type d -exec chmod 0755 {} +
find "$TARGET_DIR" -type f -exec chmod 0644 {} +
find "$TARGET_DIR/install" "$TARGET_DIR/scripts" -type f -name '*.sh' -exec chmod 0755 {} +
find "$TARGET_DIR/lib" -type f -name '*.py' -exec chmod 0755 {} +
chmod 0755 "$TARGET_DIR/web/status/status-server.py"
chmod 0644 "$TARGET_DIR/lib/common.sh"

# --- Konfiguration ----------------------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"
if [ ! -f "${CONFIG_DIR}/gateway.conf" ]; then
	install -m 0644 "${TARGET_DIR}/config/gateway.conf.example" "${CONFIG_DIR}/gateway.conf"
	log "Konfiguration angelegt: ${CONFIG_DIR}/gateway.conf"
else
	log "Vorhandene Konfiguration bleibt unveraendert: ${CONFIG_DIR}/gateway.conf"
fi
mkdir -p "${CONFIG_DIR}/secrets"
chmod 0700 "${CONFIG_DIR}/secrets"

mkdir -p /var/log/gsm-gateway /var/lib/gsm-gateway/steps /var/lib/gsm-gateway/facts
chmod 0755 /var/log/gsm-gateway /var/lib/gsm-gateway

# --- Befehle in /usr/local/bin ---------------------------------------
# Es werden zwei Namen angelegt: mit und ohne .sh - so funktionieren
# sowohl "gateway-test" als auch der in der Projektbeschreibung
# genannte Pfad /usr/local/bin/gateway-test.sh.
link_command() {
	local script="$1" base
	base="$(basename "$script" .sh)"
	ln -sfn "${TARGET_DIR}/scripts/${script}" "/usr/local/bin/${script}"
	ln -sfn "${TARGET_DIR}/scripts/${script}" "/usr/local/bin/${base}"
}

for script in gateway-check.sh bluetooth-check.sh gateway-test.sh \
	pair-iphone.sh backup-gateway.sh uninstall-gateway.sh \
	gateway-credentials.sh gateway-hci-prepare.sh; do
	[ -f "${TARGET_DIR}/scripts/${script}" ] || die "Script fehlt: ${script}"
	link_command "$script"
done
log "Befehle in /usr/local/bin angelegt (z.B. 'sudo gateway-test')."

# --- systemd-Unit -----------------------------------------------------
install -m 0644 "${TARGET_DIR}/systemd/${UNIT_NAME}" "${SYSTEMD_DIR}/${UNIT_NAME}"

if command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null; then
	systemctl enable "$UNIT_NAME"
	log "${UNIT_NAME} aktiviert."
else
	# Notfallweg: Der Dienst wird auch ohne laufendes systemd aktiviert,
	# indem der Wants-Symlink direkt angelegt wird.
	mkdir -p "${SYSTEMD_DIR}/multi-user.target.wants"
	ln -sfn "${SYSTEMD_DIR}/${UNIT_NAME}" \
		"${SYSTEMD_DIR}/multi-user.target.wants/${UNIT_NAME}"
	log "${UNIT_NAME} ueber Symlink aktiviert (systemd antwortet gerade nicht)."
fi

# --- Abschluss --------------------------------------------------------
if [ -f /var/lib/gsm-gateway/setup-complete ]; then
	log "Hinweis: Das Setup wurde bereits abgeschlossen."
	log "Erneut ausfuehren: sudo rm /var/lib/gsm-gateway/setup-complete"
fi

if [ "$RUN_NOW" = "yes" ]; then
	log "Starte die Installation ..."
	exec "${TARGET_DIR}/install/firstboot-install.sh"
fi

cat <<'DONE'

[bootstrap] Fertig.

Die eigentliche Installation laeuft automatisch beim naechsten Start
des Raspberry Pi. Sofort starten geht auch:

    sudo systemctl start gsm-gateway-firstboot.service
    sudo journalctl -u gsm-gateway-firstboot.service -f

DONE
