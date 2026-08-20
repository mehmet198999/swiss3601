#!/usr/bin/env bash
# =====================================================================
#  backup-gateway.sh - Konfiguration sichern
#
#  Sichert nach /var/backups/gsm-gateway/JJJJ-MM-TT-HH-MM-SS/:
#
#     /etc/asterisk/          Asterisk inkl. chan_mobile.conf
#     /etc/bluetooth/         BlueZ
#     /etc/systemd/system/    eigene Dienste
#     /usr/local/bin/         Startbefehle
#     /etc/gsm-gateway/       Konfiguration und Zugangsdaten
#     /var/lib/gsm-gateway/   Installationsstatus und ermittelte Werte
#
#  Das Backupverzeichnis ist 0700 - es enthaelt das SIP-Passwort und
#  die Bluetooth-Kopplungsschluessel.
#
#  Aufruf:  sudo backup-gateway  [--keep N]
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
GG_CURRENT_STEP="Backup erstellen"

KEEP=10
if [ "${1:-}" = "--keep" ]; then
	KEEP="${2:-10}"
	case "$KEEP" in
	'' | *[!0-9]*) gg_die "--keep erwartet eine Zahl." ;;
	esac
fi

STAMP="$(date '+%Y-%m-%d-%H-%M-%S')"
DEST="${GG_BACKUP_DIR}/${STAMP}"

mkdir -p "$DEST"
chmod 0700 "$GG_BACKUP_DIR"
chmod 0700 "$DEST"

gg_headline "Backup nach ${DEST}"

copy_tree() {
	local src="$1" name="$2"
	if [ ! -e "$src" ]; then
		gg_info "  ${name}: nicht vorhanden, uebersprungen"
		return 0
	fi
	mkdir -p "${DEST}/${name}"
	if ! cp -a "$src/." "${DEST}/${name}/"; then
		gg_die "Kopieren von ${src} nach ${DEST}/${name} fehlgeschlagen."
	fi
	gg_info "  ${name}: $(du -sh "${DEST}/${name}" | awk '{print $1}')"
}

copy_tree /etc/asterisk asterisk
copy_tree /etc/bluetooth bluetooth
copy_tree "$GG_ETC_DIR" gsm-gateway-etc
copy_tree "$GG_STATE_DIR" gsm-gateway-state

# Nur die eigenen Units sichern, nicht das gesamte systemd-Verzeichnis.
mkdir -p "${DEST}/systemd"
FOUND_UNITS=0
for unit in /etc/systemd/system/gsm-gateway-*.service \
	/etc/systemd/system/gsm-gateway-*.timer \
	/etc/systemd/system/asterisk.service; do
	if [ -f "$unit" ]; then
		cp -a "$unit" "${DEST}/systemd/"
		FOUND_UNITS=$((FOUND_UNITS + 1))
	fi
done
gg_info "  systemd: ${FOUND_UNITS} Unit-Dateien"

# Eigene Befehle in /usr/local/bin (nur Verweise auf dieses Projekt).
mkdir -p "${DEST}/usr-local-bin"
FOUND_BINS=0
for f in /usr/local/bin/*; do
	[ -e "$f" ] || continue
	target="$(readlink -f "$f" 2>/dev/null)"
	[ -n "$target" ] || target="$f"
	case "$target" in
	"${GG_PREFIX}"/*)
		cp -a "$f" "${DEST}/usr-local-bin/"
		FOUND_BINS=$((FOUND_BINS + 1))
		;;
	esac
done
gg_info "  usr-local-bin: ${FOUND_BINS} Eintraege"

# Firewall und fail2ban
mkdir -p "${DEST}/firewall"
for f in /etc/nftables.d/gsm-gateway.nft /etc/fail2ban/jail.d/gsm-gateway.conf \
	/etc/logrotate.d/gsm-gateway /etc/logrotate.d/gsm-gateway-asterisk \
	/etc/modprobe.d/gsm-gateway-bluetooth.conf \
	/etc/udev/rules.d/99-gsm-gateway-bluetooth.rules; do
	if [ -f "$f" ]; then
		cp -a "$f" "${DEST}/firewall/"
	fi
done

# Kurzbericht mitsichern - hilft beim Wiederherstellen enorm.
{
	printf 'GSM-Gateway Backup\n'
	printf 'Erstellt:     %s\n' "$(gg_timestamp)"
	printf 'Hostname:     %s\n' "$(hostname)"
	printf 'Modell:       %s\n' "$(gg_pi_model)"
	printf 'OS:           %s\n' "$(gg_os_pretty)"
	printf 'Asterisk:     %s (%s)\n' "$(gg_asterisk_version)" "$(gg_fact_get asterisk_install_method unbekannt)"
	printf 'BT-Adapter:   %s / %s\n' "$(gg_fact_get bt_adapter -)" "$(gg_fact_get bt_adapter_address -)"
	printf 'iPhone:       %s / %s\n' "$(gg_fact_get phone_name -)" "$(gg_fact_get phone_mac -)"
	printf 'RFCOMM-Port:  %s\n' "$(gg_fact_get rfcomm_port -)"
	printf 'SIP-Bind-IP:  %s\n' "$(gg_fact_get sip_bind_ip -)"
} >"${DEST}/INFO.txt"

chmod -R go-rwx "$DEST"

gg_ok "Backup abgeschlossen: ${DEST} ($(du -sh "$DEST" | awk '{print $1}'))"

# Alte Backups aufraeumen.
mapfile -t OLD < <(find "$GG_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | tail -n +$((KEEP + 1)))
if [ "${#OLD[@]}" -gt 0 ]; then
	for dir in "${OLD[@]}"; do
		rm -rf "$dir"
		gg_info "Altes Backup entfernt: ${dir}"
	done
fi

printf '\nWiederherstellen (Beispiel Asterisk-Konfiguration):\n'
printf '  sudo systemctl stop asterisk\n'
printf '  sudo cp -a %s/asterisk/. /etc/asterisk/\n' "$DEST"
printf '  sudo systemctl start asterisk\n\n'
