#!/usr/bin/env bash
# =====================================================================
#  uninstall-gateway.sh - Gateway wieder entfernen
#
#  Entfernt wird ausschliesslich, was dieses Projekt installiert hat:
#     * Asterisk (Paket oder Quellcode-Installation)
#     * die Gateway-Konfiguration
#     * die eigenen systemd-Dienste
#     * die eigenen Scripts und Befehle
#
#  NICHT angetastet werden:
#     * Raspberry Pi OS und dessen Pakete
#     * Benutzerkonten und SSH-Zugang
#     * Netzwerkkonfiguration
#
#  Vor dem Entfernen wird IMMER ein Backup erstellt.
#
#  Aufruf:
#     sudo uninstall-gateway              mit Rueckfragen
#     sudo uninstall-gateway --yes        ohne Rueckfragen
#     sudo uninstall-gateway --keep-bluez BlueZ-Pakete behalten
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
GG_CURRENT_STEP="Deinstallation"

ASSUME_YES="no"
REMOVE_BLUEZ="yes"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--yes | -y) ASSUME_YES="yes" ;;
	--keep-bluez) REMOVE_BLUEZ="no" ;;
	-h | --help)
		sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'Unbekannte Option: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

confirm() {
	if [ "$ASSUME_YES" = "yes" ]; then
		return 0
	fi
	local answer
	printf '%s [j/N]: ' "$1"
	read -r answer </dev/tty
	case "$answer" in
	j | J | ja | Ja | JA | y | Y | yes) return 0 ;;
	*) return 1 ;;
	esac
}

cat <<'WARN'

=======================================================
 GSM-Gateway deinstallieren
=======================================================

Entfernt wird:
  - Asterisk samt Konfiguration
  - chan_mobile-Einstellungen
  - die Gateway-Dienste und -Scripts
  - die Firewallregeln des Gateways
  - die SIP-Zugangsdaten

Nicht entfernt wird:
  - Raspberry Pi OS
  - Benutzerkonten, SSH, Netzwerk
  - die Bluetooth-Kopplung im iPhone
    (dort bei Bedarf "Dieses Geraet ignorieren" antippen)

Vorher wird automatisch ein Backup erstellt.

=======================================================

WARN

if ! confirm "Wirklich deinstallieren?"; then
	gg_info "Abgebrochen - es wurde nichts geaendert."
	exit 0
fi

# ---------------------------------------------------------------------
# 1. Backup
# ---------------------------------------------------------------------
gg_headline "Backup vor der Deinstallation"
if ! "${GG_PREFIX}/scripts/backup-gateway.sh"; then
	gg_error "Das Backup ist fehlgeschlagen."
	if ! confirm "Trotzdem ohne Backup fortfahren?"; then
		gg_die "Deinstallation abgebrochen - kein Backup vorhanden."
	fi
fi

# ---------------------------------------------------------------------
# 2. Dienste stoppen und entfernen
# ---------------------------------------------------------------------
gg_headline "Dienste stoppen"
for unit in gsm-gateway-firstboot.service gsm-gateway-web.service \
	gsm-gateway-status.timer gsm-gateway-status.service asterisk.service; do
	if systemctl cat "$unit" >/dev/null 2>&1; then
		if systemctl disable --now "$unit" >/dev/null 2>&1; then
			gg_info "  ${unit} gestoppt und deaktiviert"
		else
			gg_warn "  ${unit} liess sich nicht sauber stoppen - wird trotzdem entfernt"
		fi
	fi
done

# Instanzen der HCI-Vorbereitung
while IFS= read -r unit; do
	[ -n "$unit" ] || continue
	if systemctl disable --now "$unit" >/dev/null 2>&1; then
		gg_info "  ${unit} gestoppt"
	fi
done < <(systemctl list-units --all --no-legend 'gsm-gateway-hci@*' 2>/dev/null | awk '{print $1}')

for f in /etc/systemd/system/gsm-gateway-firstboot.service \
	/etc/systemd/system/gsm-gateway-web.service \
	/etc/systemd/system/gsm-gateway-status.service \
	/etc/systemd/system/gsm-gateway-status.timer \
	/etc/systemd/system/gsm-gateway-hci@.service; do
	if [ -f "$f" ]; then
		rm -f "$f"
		gg_info "  entfernt: ${f}"
	fi
done
systemctl daemon-reload
gg_ok "Eigene Dienste entfernt."

# ---------------------------------------------------------------------
# 3. Asterisk entfernen
# ---------------------------------------------------------------------
gg_headline "Asterisk entfernen"
METHOD="$(gg_fact_get asterisk_install_method 'unbekannt')"
gg_info "Installationsart laut Protokoll: ${METHOD}"

if gg_pkg_installed asterisk; then
	gg_info "Entferne die Asterisk-Pakete ..."
	if ! gg_apt_wait; then
		gg_die "APT ist gesperrt - Deinstallation abgebrochen."
	fi
	DEBIAN_FRONTEND=noninteractive apt-get -y purge 'asterisk*'
	DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
	gg_ok "Asterisk-Pakete entfernt."
else
	SRC_DIR="$(gg_fact_get asterisk_source_dir '')"
	if [ -n "$SRC_DIR" ] && [ -f "${SRC_DIR}/Makefile" ]; then
		gg_info "Rufe 'make uninstall' im Quellverzeichnis auf ..."
		if ! make -C "$SRC_DIR" uninstall >>"$GG_ASTERISK_LOG" 2>&1; then
			gg_warn "'make uninstall' meldete Fehler - die Dateien werden gleich direkt entfernt."
		fi
	fi

	# Was 'make uninstall' stehen laesst bzw. was ohne Quellverzeichnis
	# uebrig bleibt, wird hier gezielt entfernt.
	for path in /usr/sbin/asterisk /usr/sbin/astcanary /usr/sbin/astdb2sqlite3 \
		/usr/sbin/astdb2bdb /usr/sbin/rasterisk /usr/sbin/safe_asterisk \
		/usr/lib/asterisk /var/lib/asterisk /var/spool/asterisk \
		/usr/include/asterisk /usr/include/asterisk.h \
		/usr/share/man/man8/asterisk.8.gz; do
		if [ -e "$path" ]; then
			rm -rf "$path"
			gg_info "  entfernt: ${path}"
		fi
	done
	gg_ok "Quellcode-Installation von Asterisk entfernt."
fi

if [ -d /etc/asterisk ]; then
	rm -rf /etc/asterisk
	gg_info "  entfernt: /etc/asterisk (Sicherung liegt im Backup)"
fi
if [ -d /var/log/asterisk ]; then
	rm -rf /var/log/asterisk
	gg_info "  entfernt: /var/log/asterisk"
fi
if getent passwd asterisk >/dev/null; then
	if userdel asterisk >/dev/null 2>&1; then
		gg_info "  Benutzer 'asterisk' entfernt"
	else
		gg_warn "  Benutzer 'asterisk' konnte nicht entfernt werden (noch Prozesse aktiv?)"
	fi
fi
if getent group asterisk >/dev/null; then
	if ! groupdel asterisk >/dev/null 2>&1; then
		gg_warn "  Gruppe 'asterisk' konnte nicht entfernt werden"
	fi
fi

# Quellcode und Build-Verzeichnis
if [ -d /usr/local/src/gsm-gateway ]; then
	rm -rf /usr/local/src/gsm-gateway
	gg_info "  entfernt: /usr/local/src/gsm-gateway"
fi

# ---------------------------------------------------------------------
# 4. Firewall, fail2ban, logrotate, udev
# ---------------------------------------------------------------------
gg_headline "Zusatzkonfiguration entfernen"

if command -v nft >/dev/null 2>&1 && nft list table inet gsm_gateway >/dev/null 2>&1; then
	nft delete table inet gsm_gateway
	gg_info "  nftables-Tabelle inet gsm_gateway geloescht"
fi
for f in /etc/nftables.d/gsm-gateway.nft \
	/etc/fail2ban/jail.d/gsm-gateway.conf \
	/etc/logrotate.d/gsm-gateway \
	/etc/logrotate.d/gsm-gateway-asterisk \
	/etc/modprobe.d/gsm-gateway-bluetooth.conf \
	/etc/udev/rules.d/99-gsm-gateway-bluetooth.rules; do
	if [ -f "$f" ]; then
		rm -f "$f"
		gg_info "  entfernt: ${f}"
	fi
done
if command -v udevadm >/dev/null 2>&1; then
	udevadm control --reload-rules
fi
if systemctl cat fail2ban.service >/dev/null 2>&1 && gg_service_active fail2ban.service; then
	systemctl restart fail2ban.service
fi

# Maskierte Audio-Dienste wieder freigeben - setup-audio.sh hatte sie
# nur wegen chan_mobile stillgelegt.
for unit in bluealsa.service pulseaudio.service pipewire.service \
	pipewire-pulse.service wireplumber.service bluetooth-meshd.service; do
	if [ "$(systemctl is-enabled "$unit" 2>/dev/null)" = "masked" ]; then
		systemctl unmask "$unit"
		gg_info "  ${unit} wieder freigegeben"
	fi
done

# ---------------------------------------------------------------------
# 5. Befehle in /usr/local/bin
# ---------------------------------------------------------------------
for f in /usr/local/bin/*; do
	[ -e "$f" ] || continue
	target="$(readlink -f "$f" 2>/dev/null)"
	[ -n "$target" ] || target="$f"
	case "$target" in
	"${GG_PREFIX}"/*)
		rm -f "$f"
		gg_info "  entfernt: ${f}"
		;;
	esac
done

# ---------------------------------------------------------------------
# 6. Gateway-Konfiguration und Status
# ---------------------------------------------------------------------
gg_headline "Gateway-Daten entfernen"

if getent passwd gsm-web >/dev/null; then
	if userdel gsm-web >/dev/null 2>&1; then
		gg_info "  Benutzer 'gsm-web' entfernt"
	else
		gg_warn "  Benutzer 'gsm-web' konnte nicht entfernt werden"
	fi
fi

REMOVED_SECRETS="nein"
if confirm "Auch die SIP-Zugangsdaten in ${GG_SECRET_DIR} loeschen?"; then
	rm -rf "$GG_ETC_DIR"
	REMOVED_SECRETS="ja"
	gg_info "  entfernt: ${GG_ETC_DIR}"
else
	gg_info "  ${GG_ETC_DIR} bleibt erhalten."
fi

rm -rf "$GG_STATE_DIR"
gg_info "  entfernt: ${GG_STATE_DIR}"
rm -rf /run/gsm-gateway

# ---------------------------------------------------------------------
# 7. BlueZ (optional)
# ---------------------------------------------------------------------
if [ "$REMOVE_BLUEZ" = "yes" ]; then
	if confirm "Auch die Bluetooth-Pakete (bluez) entfernen?"; then
		if ! gg_apt_wait; then
			gg_warn "APT ist gesperrt - bluez bleibt installiert."
		else
			DEBIAN_FRONTEND=noninteractive apt-get -y purge bluez
			DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
			gg_info "  bluez entfernt"
		fi
	else
		gg_info "  bluez bleibt installiert."
	fi
fi

# ---------------------------------------------------------------------
gg_headline "Deinstallation abgeschlossen"
cat <<DONE

Entfernt wurden Asterisk, chan_mobile, die Gateway-Dienste und die
Zusatzkonfiguration. Raspberry Pi OS ist unveraendert.

  Backups:            ${GG_BACKUP_DIR}
  SIP-Zugangsdaten:   ${REMOVED_SECRETS} geloescht
  Projektverzeichnis: ${GG_PREFIX}
                      (bleibt bestehen - bei Bedarf selbst loeschen:
                       sudo rm -rf ${GG_PREFIX})
  Protokolle:         ${GG_LOG_DIR}
                      (bleiben bestehen)

Am iPhone kann die Kopplung unter
  Einstellungen -> Bluetooth -> (i) -> "Dieses Geraet ignorieren"
entfernt werden.

DONE
