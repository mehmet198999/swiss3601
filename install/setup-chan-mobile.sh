#!/usr/bin/env bash
# =====================================================================
#  setup-chan-mobile.sh - chan_mobile konfigurieren
#
#  Erzeugt /etc/asterisk/chan_mobile.conf mit dem TATSAECHLICH
#  vorhandenen Bluetooth-Adapter. Es wird nichts erfunden: die
#  MAC-Adresse stammt aus /sys/class/bluetooth und wurde vorher von
#  install-bluetooth.sh ermittelt.
#
#  Das Telefon selbst wird hier NICHT eingetragen - das macht
#  pair-iphone.sh nach dem echten Pairing mit der echten MAC-Adresse.
#  Ist bereits ein Telefon gekoppelt, wird dessen Eintrag erhalten.
#
#  Vor jeder Aenderung wird /etc/asterisk gesichert:
#      /etc/asterisk/backup/JJJJ-MM-TT-HH-MM-SS/
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
GG_CURRENT_STEP="Asterisk/chan_mobile konfigurieren"

ASTERISK_ETC="/etc/asterisk"
BACKUP_ROOT="${ASTERISK_ETC}/backup"

gg_headline "chan_mobile konfigurieren"

# ---------------------------------------------------------------------
# 1. Voraussetzungen
# ---------------------------------------------------------------------
if ! gg_chan_mobile_file >/dev/null 2>&1; then
	gg_die "chan_mobile.so ist nicht vorhanden. Schritt 15 (chan_mobile bereitstellen) hat nicht funktioniert."
fi
if [ ! -d "$ASTERISK_ETC" ]; then
	gg_die "${ASTERISK_ETC} existiert nicht - Asterisk scheint nicht installiert zu sein."
fi

ADAPTER_HCI="$(gg_fact_get bt_adapter "")"
ADAPTER_MAC="$(gg_fact_get bt_adapter_address "")"
if [ -z "$ADAPTER_HCI" ] || [ -z "$ADAPTER_MAC" ]; then
	gg_die "Kein Bluetooth-Adapter bekannt. Bitte zuerst ausfuehren: sudo ${GG_PREFIX}/install/install-bluetooth.sh detect"
fi

# Sprechender, aber kurzer Adaptername fuer die Konfiguration.
if [ "$(gg_fact_get bt_adapter_is_bt500 no)" = "yes" ]; then
	ADAPTER_ID="bt500"
elif [ "$(gg_fact_get bt_adapter_kind internal)" = "usb" ]; then
	ADAPTER_ID="btusb"
else
	ADAPTER_ID="btinternal"
fi
gg_fact_set adapter_id "$ADAPTER_ID"
gg_info "Adapter ${ADAPTER_HCI} (${ADAPTER_MAC}) wird als '${ADAPTER_ID}' eingetragen."

# ---------------------------------------------------------------------
# 2. Backup der bestehenden Konfiguration
# ---------------------------------------------------------------------
backup_asterisk_config() {
	local stamp dir count f
	# Erst zaehlen, dann anlegen - so entsteht kein leeres Backupverzeichnis.
	count=0
	for f in "${ASTERISK_ETC}"/*.conf; do
		[ -f "$f" ] || continue
		count=$((count + 1))
	done
	if [ "$count" -eq 0 ]; then
		gg_info "Keine bestehende Asterisk-Konfiguration zum Sichern gefunden."
		return 0
	fi

	stamp="$(date '+%Y-%m-%d-%H-%M-%S')"
	dir="${BACKUP_ROOT}/${stamp}"
	mkdir -p "$dir"
	for f in "${ASTERISK_ETC}"/*.conf; do
		[ -f "$f" ] || continue
		cp -a "$f" "$dir/"
	done
	chmod 0700 "$BACKUP_ROOT"
	gg_ok "${count} Konfigurationsdateien gesichert nach ${dir}"
	gg_fact_set last_asterisk_backup "$dir"
}
backup_asterisk_config

# ---------------------------------------------------------------------
# 3. chan_mobile.conf schreiben
# ---------------------------------------------------------------------
# Welchen Dateinamen erwartet genau diese chan_mobile-Version?
CONF_NAME="$(gg_chan_mobile_conf_name)"
CONF_PATH="${ASTERISK_ETC}/${CONF_NAME}"
gg_info "chan_mobile erwartet die Konfigurationsdatei: ${CONF_NAME}"

# Einen eventuell bereits vorhandenen Geraeteblock retten, damit ein
# erneuter Lauf ein gekoppeltes iPhone nicht aus der Konfiguration wirft.
EXISTING_DEVICES=""
if [ -f "$CONF_PATH" ]; then
	EXISTING_DEVICES="$(awk '
		/^\[/ {
			section = $0
			sub(/^\[/, "", section)
			sub(/\].*$/, "", section)
			keep = (section != "general" && section != "adapter")
		}
		keep { print }
	' "$CONF_PATH")"
fi

if [ -n "$EXISTING_DEVICES" ]; then
	gg_info "Bestehende Geraeteeintraege werden uebernommen."
fi

if ! gg_render_template "${GG_PREFIX}/asterisk/chan_mobile.conf.template" "$CONF_PATH" \
	"ADAPTER_ID=${ADAPTER_ID}" \
	"ADAPTER_MAC=${ADAPTER_MAC}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "chan_mobile.conf konnte nicht erzeugt werden."
fi

if [ -n "$EXISTING_DEVICES" ]; then
	printf '\n%s\n' "$EXISTING_DEVICES" >>"$CONF_PATH"
fi

# Alten Dateinamen als Symlink bereitstellen, damit sowohl
# chan_mobile.conf als auch mobile.conf funktionieren.
if [ "$CONF_NAME" != "mobile.conf" ]; then
	if [ -f "${ASTERISK_ETC}/mobile.conf" ] && [ ! -L "${ASTERISK_ETC}/mobile.conf" ]; then
		gg_backup_file "${ASTERISK_ETC}/mobile.conf" "$BACKUP_ROOT"
		rm -f "${ASTERISK_ETC}/mobile.conf"
	fi
	ln -sfn "$CONF_NAME" "${ASTERISK_ETC}/mobile.conf"
	gg_info "Symlink ${ASTERISK_ETC}/mobile.conf -> ${CONF_NAME} angelegt."
fi

gg_ok "${CONF_PATH} geschrieben."

# ---------------------------------------------------------------------
# 4. logger.conf (Sicherheitskanal fuer fail2ban)
# ---------------------------------------------------------------------
gg_backup_file "${ASTERISK_ETC}/logger.conf" "$BACKUP_ROOT"
if ! gg_render_template "${GG_PREFIX}/asterisk/logger.conf.template" "${ASTERISK_ETC}/logger.conf" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "logger.conf konnte nicht erzeugt werden."
fi
gg_ok "logger.conf geschrieben (Kanal 'security' aktiv - Basis fuer fail2ban)."

# ---------------------------------------------------------------------
# 5. modules.conf - chan_mobile darf nicht ausgeschlossen sein
# ---------------------------------------------------------------------
MODULES_CONF="${ASTERISK_ETC}/modules.conf"
if [ -f "$MODULES_CONF" ]; then
	if grep -qE '^[[:space:]]*noload[[:space:]]*=>[[:space:]]*chan_mobile\.so' "$MODULES_CONF"; then
		gg_backup_file "$MODULES_CONF" "$BACKUP_ROOT"
		sed -i -E 's/^([[:space:]]*noload[[:space:]]*=>[[:space:]]*chan_mobile\.so.*)$/;\1  ; von gsm-gateway deaktiviert/' "$MODULES_CONF"
		gg_warn "In modules.conf stand 'noload => chan_mobile.so' - der Eintrag wurde auskommentiert."
	fi
	if grep -qE '^[[:space:]]*autoload[[:space:]]*=[[:space:]]*no' "$MODULES_CONF"; then
		if ! grep -qE '^[[:space:]]*load[[:space:]]*=>[[:space:]]*chan_mobile\.so' "$MODULES_CONF"; then
			gg_backup_file "$MODULES_CONF" "$BACKUP_ROOT"
			printf '\n; von gsm-gateway ergaenzt\nload => chan_mobile.so\n' >>"$MODULES_CONF"
			gg_info "autoload=no erkannt - 'load => chan_mobile.so' ergaenzt."
		fi
	fi
else
	gg_warn "${MODULES_CONF} fehlt. Asterisk laedt dann alle vorhandenen Module (autoload)."
fi

# ---------------------------------------------------------------------
# 6. Rechte
# ---------------------------------------------------------------------
if getent passwd asterisk >/dev/null; then
	chown -R asterisk:asterisk "$ASTERISK_ETC"
	find "$ASTERISK_ETC" -maxdepth 1 -type f -name '*.conf' -exec chmod 0640 {} +
	chmod 0750 "$ASTERISK_ETC"
	if [ -d "$BACKUP_ROOT" ]; then
		chmod 0700 "$BACKUP_ROOT"
	fi
	gg_ok "Rechte in ${ASTERISK_ETC} gesetzt (asterisk:asterisk, 0640)."
else
	gg_warn "Benutzer 'asterisk' existiert nicht - Rechte wurden nicht angepasst."
fi

# ---------------------------------------------------------------------
# 7. Logrotation fuer die Asterisk-Protokolle
# ---------------------------------------------------------------------
# Erst hier, weil logrotate die Konfiguration ablehnt, solange der
# Benutzer "asterisk" nicht existiert.
if [ -f /etc/logrotate.d/asterisk ]; then
	gg_info "Asterisk bringt bereits eine eigene Logrotation mit - unveraendert gelassen."
elif getent passwd asterisk >/dev/null; then
	install -m 0644 "${GG_PREFIX}/etc/logrotate.d/gsm-gateway-asterisk" \
		/etc/logrotate.d/gsm-gateway-asterisk
	if ! logrotate --debug /etc/logrotate.d/gsm-gateway-asterisk >/dev/null 2>&1; then
		rm -f /etc/logrotate.d/gsm-gateway-asterisk
		gg_die "Die Logrotation fuer Asterisk wurde von logrotate abgelehnt."
	fi
	gg_ok "Logrotation fuer /var/log/asterisk eingerichtet."
else
	gg_warn "Benutzer 'asterisk' fehlt - Logrotation fuer Asterisk nicht eingerichtet."
fi

gg_ok "chan_mobile ist konfiguriert. Das Telefon traegt pair-iphone.sh nach dem Pairing ein."
