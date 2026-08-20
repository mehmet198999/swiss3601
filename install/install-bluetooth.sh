#!/usr/bin/env bash
# =====================================================================
#  install-bluetooth.sh - Bluetooth-Stack einrichten
#
#  Unterkommandos (werden von firstboot-install.sh einzeln aufgerufen,
#  damit jeder Schritt einzeln wiederholbar ist):
#
#     install    Pakete installieren (bluez, rfkill, Firmware)
#     configure  /etc/bluetooth/main.conf anpassen
#     detect     Adapter erkennen (ASUS USB-BT500) und Fakten speichern
#     diagnose   ausfuehrliche Bluetooth-Diagnose nach bluetooth.log
#
#  Ohne Argument werden alle vier nacheinander ausgefuehrt.
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

BLUEZ_MAIN_CONF="/etc/bluetooth/main.conf"
BLUEZ_BACKUP_DIR="/etc/bluetooth/backup"

# ---------------------------------------------------------------------
#  install - Pakete
# ---------------------------------------------------------------------

# Firmware-Pakete liegen bei Debian 12+ in der Komponente
# "non-free-firmware". Raspberry Pi OS aktiviert die normalerweise
# bereits; hier wird das nur sichergestellt.
ensure_nonfree_firmware() {
	if gg_apt_has_candidate firmware-realtek; then
		gg_info "Komponente non-free-firmware ist bereits verfuegbar."
		return 0
	fi

	local list
	list="$(grep -rl '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null |
		xargs grep -l 'debian.org\|raspbian' 2>/dev/null | head -n1 || true)"
	if [ -z "$list" ]; then
		gg_warn "Keine passende APT-Quelle gefunden - non-free-firmware kann nicht ergaenzt werden."
		return 0
	fi

	gg_info "Ergaenze 'non-free-firmware' in ${list}."
	gg_backup_file "$list" /etc/apt/backup
	sed -i -E '/^deb .*(debian\.org|raspbian)/ { /non-free-firmware/! s/$/ non-free-firmware/ }' "$list"

	if ! gg_apt_update; then
		gg_die "apt-get update nach dem Ergaenzen von non-free-firmware fehlgeschlagen."
	fi
}

cmd_install() {
	gg_headline "Bluetooth-Pakete installieren"

	local pkgs=(bluez libbluetooth3)

	# rfkill ist je nach Distribution ein eigenes Paket oder Teil von
	# util-linux. Nur installieren, was es wirklich gibt.
	if ! command -v rfkill >/dev/null 2>&1; then
		if gg_apt_has_candidate rfkill; then
			pkgs+=(rfkill)
		else
			pkgs+=(util-linux)
		fi
	fi

	# Raspberry-Pi-eigenes Bluetooth-Paket (interner Controller).
	if gg_apt_has_candidate pi-bluetooth; then
		pkgs+=(pi-bluetooth)
	fi

	if ! gg_apt_install "${pkgs[@]}"; then
		gg_die "Installation der Bluetooth-Pakete fehlgeschlagen."
	fi

	# Firmware fuer USB-Adapter. Der ASUS USB-BT500 nutzt einen Realtek
	# RTL8761B und laedt rtl_bt/rtl8761b*_fw.bin - ohne firmware-realtek
	# erscheint der Adapter gar nicht oder bleibt tot.
	ensure_nonfree_firmware
	local fw_pkgs=()
	local pkg
	for pkg in firmware-realtek firmware-atheros firmware-brcm80211; do
		if gg_apt_has_candidate "$pkg"; then
			fw_pkgs+=("$pkg")
		fi
	done
	if [ "${#fw_pkgs[@]}" -gt 0 ]; then
		if ! gg_apt_install "${fw_pkgs[@]}"; then
			gg_die "Installation der Bluetooth-Firmware fehlgeschlagen."
		fi
	else
		gg_warn "Keine Firmware-Pakete verfuegbar. Falls der USB-BT500 nicht"
		gg_warn "erkannt wird, fehlt sehr wahrscheinlich rtl_bt/rtl8761b_fw.bin."
	fi

	systemctl enable bluetooth.service
	if ! systemctl restart bluetooth.service; then
		gg_die "bluetooth.service konnte nicht gestartet werden."
	fi

	# Bluetooth darf nicht per rfkill gesperrt sein.
	if command -v rfkill >/dev/null 2>&1; then
		rfkill unblock bluetooth
		if rfkill list bluetooth | grep -qi 'blocked: yes'; then
			gg_die "Bluetooth ist weiterhin per rfkill blockiert: $(rfkill list bluetooth | tr '\n' ' ')"
		fi
		gg_ok "Bluetooth ist nicht blockiert."
	else
		gg_warn "rfkill nicht verfuegbar - Blockade konnte nicht geprueft werden."
	fi

	gg_ok "Bluetooth-Pakete installiert, bluetooth.service laeuft."
}

# ---------------------------------------------------------------------
#  configure - BlueZ
# ---------------------------------------------------------------------

bluez_set() {
	local section="$1" key="$2" value="$3" result
	result="$("${GG_PREFIX}/lib/ini-set.py" "$BLUEZ_MAIN_CONF" "$section" "$key" "$value")"
	gg_info "main.conf [${section}] ${key} = ${value} (${result})"
	[ "$result" = "changed" ]
}

cmd_configure() {
	gg_headline "BlueZ konfigurieren"

	if [ ! -f "$BLUEZ_MAIN_CONF" ]; then
		gg_info "${BLUEZ_MAIN_CONF} existiert nicht - wird angelegt."
		mkdir -p /etc/bluetooth
		printf '[General]\n' >"$BLUEZ_MAIN_CONF"
		chmod 0644 "$BLUEZ_MAIN_CONF"
	fi

	gg_backup_file "$BLUEZ_MAIN_CONF" "$BLUEZ_BACKUP_DIR"

	local changed=0

	# Class of Device 0x200404 = Audio/Video -> Hands-free.
	# iOS bietet HFP nur Geraeten an, die sich als Freisprecheinrichtung
	# ausgeben. Ohne diesen Wert taucht der Pi als "sonstiges Geraet" auf
	# und der Handsfree-Dienst wird oft gar nicht erst angeboten.
	if bluez_set General Class "$GG_BT_CLASS"; then changed=1; fi

	# Name, unter dem der Pi auf dem iPhone erscheint.
	if bluez_set General Name "$GG_BT_NAME"; then changed=1; fi

	# Adapter nach dem Start automatisch einschalten.
	if bluez_set Policy AutoEnable true; then changed=1; fi

	# Schnelleres Page-Scanning: das iPhone findet den Pi zuverlaessiger
	# wieder, wenn die Verbindung zwischendurch abbricht.
	if bluez_set General FastConnectable true; then changed=1; fi

	# Nach dem Entkoppeln auf dem iPhone soll auch der Pi den Schluessel
	# vergessen duerfen, statt in einen halb gekoppelten Zustand zu geraten.
	if bluez_set General JustWorksRepairing always; then changed=1; fi

	if [ "$changed" -eq 1 ]; then
		gg_info "main.conf wurde geaendert - bluetooth.service wird neu gestartet."
		if ! systemctl restart bluetooth.service; then
			gg_die "bluetooth.service startet mit der neuen main.conf nicht mehr. Backup unter ${BLUEZ_BACKUP_DIR}."
		fi
		# BlueZ braucht einen Moment, bis der Adapter wieder da ist.
		sleep 3
	else
		gg_info "main.conf war bereits korrekt."
	fi

	if ! gg_service_active bluetooth.service; then
		gg_die "bluetooth.service laeuft nicht."
	fi
	gg_ok "BlueZ konfiguriert (Class=${GG_BT_CLASS}, Name=${GG_BT_NAME})."
}

# ---------------------------------------------------------------------
#  detect - Adapter erkennen
# ---------------------------------------------------------------------

# Bekannte USB-IDs. Die Liste dient nur der Beschriftung im Log -
# erkannt wird immer die tatsaechlich vorhandene Hardware.
usb_id_label() {
	case "$(printf '%s' "$1" | tr 'A-F' 'a-f')" in
	0b05:190e) printf 'ASUS USB-BT500 (Realtek RTL8761B)' ;;
	0b05:1919 | 0b05:1918) printf 'ASUS Bluetooth-Adapter (Realtek)' ;;
	0a12:0001) printf 'Cambridge Silicon Radio (CSR) Bluetooth' ;;
	0bda:8771) printf 'Realtek RTL8761BU Bluetooth' ;;
	8087:*) printf 'Intel Bluetooth' ;;
	*) printf 'unbekanntes Modell' ;;
	esac
}

adapter_driver() {
	local hci="$1" drv
	drv="$(readlink -f "/sys/class/bluetooth/${hci}/device/driver" 2>/dev/null)" || return 1
	basename "$drv"
}

cmd_detect() {
	gg_headline "Bluetooth-Adapter erkennen"

	local adapters
	adapters="$(gg_bt_adapters | tr '\n' ' ')"
	if [ -z "${adapters// /}" ]; then
		gg_error "Angeschlossene USB-Geraete:"
		lsusb >>"$GG_BLUETOOTH_LOG" 2>&1 || true
		gg_die "Kein Bluetooth-Adapter gefunden. USB-BT500 eingesteckt? 'lsusb' pruefen (Ausgabe in ${GG_BLUETOOTH_LOG})."
	fi
	gg_info "Gefundene Adapter: ${adapters}"

	local hci addr usbid label drv
	for hci in $(gg_bt_adapters); do
		addr="$(gg_bt_address "$hci")"
		drv="$(adapter_driver "$hci" || printf 'unbekannt')"
		if gg_bt_is_usb "$hci"; then
			usbid="$(gg_bt_usb_id "$hci" || printf 'unbekannt')"
			label="$(usb_id_label "$usbid")"
			gg_info "  ${hci}: USB  MAC=${addr}  USB-ID=${usbid}  Treiber=${drv}  -> ${label}"
		else
			gg_info "  ${hci}: intern (kein USB)  MAC=${addr}  Treiber=${drv}"
		fi
	done

	local selected
	if ! selected="$(gg_bt_select_adapter)"; then
		gg_error "GG_BT_ADAPTER='${GG_BT_ADAPTER}' passt auf keinen vorhandenen Adapter."
		gg_die "Kein passender Bluetooth-Adapter. Vorhanden: ${adapters}"
	fi

	addr="$(gg_bt_address "$selected")"
	if [ -z "$addr" ] || [ "$addr" = "00:00:00:00:00:00" ]; then
		gg_die "Adapter ${selected} liefert keine gueltige MAC-Adresse (${addr:-leer}). Fehlt die Firmware?"
	fi

	if gg_bt_is_usb "$selected"; then
		usbid="$(gg_bt_usb_id "$selected" || printf 'unbekannt')"
		label="$(usb_id_label "$usbid")"
		gg_ok "Ausgewaehlter Adapter: ${selected} (USB ${usbid} - ${label}), MAC ${addr}"
		gg_fact_set bt_adapter_usbid "$usbid"
		gg_fact_set bt_adapter_kind "usb"
		case "$(printf '%s' "$usbid" | tr 'A-F' 'a-f')" in
		0b05:190e) gg_fact_set bt_adapter_is_bt500 "yes" ;;
		*)
			gg_fact_set bt_adapter_is_bt500 "no"
			gg_warn "Der Adapter ist nicht der erwartete ASUS USB-BT500 (0b05:190e)."
			gg_warn "Das Setup laeuft weiter - getestet ist aber der BT500."
			;;
		esac
	else
		gg_fact_set bt_adapter_kind "internal"
		gg_fact_set bt_adapter_is_bt500 "no"
		gg_warn "Ausgewaehlt ist der interne Bluetooth-Controller (${selected}, MAC ${addr})."
		gg_warn "Das interne Bluetooth des Raspberry Pi 3 ist fuer HFP-Sprachverbindungen"
		gg_warn "deutlich unzuverlaessiger als ein USB-Adapter. USB-BT500 einstecken!"
	fi

	gg_fact_set bt_adapter "$selected"
	gg_fact_set bt_adapter_address "$addr"
	gg_fact_set bt_adapter_driver "$(adapter_driver "$selected" || printf 'unbekannt')"

	# Firmware-Ladefehler im Kernel-Log aufspueren.
	if command -v dmesg >/dev/null 2>&1; then
		local fw_errors
		fw_errors="$(dmesg 2>/dev/null | grep -iE 'bluetooth.*(firmware|rtl_bt).*(fail|error|not found)' | tail -n5 || true)"
		if [ -n "$fw_errors" ]; then
			gg_warn "Kernel meldet Firmware-Probleme:"
			printf '%s\n' "$fw_errors" | while IFS= read -r l; do gg_warn "  ${l}"; done
		fi
	fi

	# Adapter fuer chan_mobile vorbereiten (Voice Setting 0x0060).
	if ! "${GG_PREFIX}/scripts/gateway-hci-prepare.sh" "$selected"; then
		gg_die "Adapter ${selected} konnte nicht fuer chan_mobile vorbereitet werden."
	fi

	# udev-Regel und Dienst installieren, damit das auch nach dem
	# Aus- und Einstecken des Adapters automatisch passiert.
	install -m 0644 "${GG_PREFIX}/systemd/udev/99-gsm-gateway-bluetooth.rules" \
		/etc/udev/rules.d/99-gsm-gateway-bluetooth.rules
	install -m 0644 "${GG_PREFIX}/systemd/gsm-gateway-hci@.service" \
		/etc/systemd/system/gsm-gateway-hci@.service
	systemctl daemon-reload
	udevadm control --reload-rules
	gg_ok "udev-Regel fuer automatische Adaptervorbereitung installiert."
}

# ---------------------------------------------------------------------
#  diagnose
# ---------------------------------------------------------------------

# Hinweis zu "|| true" in diesem Abschnitt:
# Hier werden ausschliesslich Informationen gesammelt. Fehlt ein
# Werkzeug oder liefert es einen Fehlercode, soll das die Diagnose nicht
# abbrechen - die Ausgabe landet trotzdem im Protokoll. Die Kriterien,
# die wirklich stimmen muessen, werden weiter unten getrennt geprueft
# und fuehren dort zu einem echten Abbruch.
cmd_diagnose() {
	gg_headline "Bluetooth-Diagnose"

	local hci
	hci="$(gg_fact_get bt_adapter "")"
	if [ -z "$hci" ]; then
		hci="$(gg_bt_select_adapter || printf '')"
	fi

	{
		printf '\n===== Bluetooth-Diagnose %s =====\n' "$(gg_timestamp)"

		printf -- '--- systemctl status bluetooth ---\n'
		systemctl status bluetooth.service --no-pager --lines=10 2>&1 || true

		printf -- '\n--- rfkill list ---\n'
		if command -v rfkill >/dev/null 2>&1; then
			rfkill list 2>&1 || true
		else
			printf '(rfkill nicht installiert)\n'
		fi

		printf -- '\n--- lsusb ---\n'
		lsusb 2>&1 || printf '(lsusb nicht verfuegbar)\n'

		printf -- '\n--- /sys/class/bluetooth ---\n'
		ls -l /sys/class/bluetooth/ 2>&1 || true

		printf -- '\n--- bluetoothctl list ---\n'
		bluetoothctl list 2>&1 || true

		printf -- '\n--- bluetoothctl show ---\n'
		if [ -n "$hci" ]; then
			bluetoothctl show "$(gg_bt_address "$hci")" 2>&1 || bluetoothctl show 2>&1 || true
		else
			bluetoothctl show 2>&1 || true
		fi

		printf -- '\n--- bluetoothctl devices ---\n'
		bluetoothctl devices 2>&1 || true

		if command -v hciconfig >/dev/null 2>&1; then
			printf -- '\n--- hciconfig -a ---\n'
			hciconfig -a 2>&1 || true
		else
			printf -- '\n--- hciconfig ---\n(nicht installiert - BlueZ liefert die veralteten Werkzeuge nicht mehr mit)\n'
		fi

		printf -- '\n--- HCI Voice Setting ---\n'
		if [ -n "$hci" ]; then
			"${GG_PREFIX}/scripts/gateway-hci-prepare.sh" --show "$hci" 2>&1 || true
		fi

		printf -- '\n--- Kernelmodule ---\n'
		lsmod 2>/dev/null | grep -E '^(bluetooth|btusb|btrtl|btbcm|btintel|hci_uart|rfcomm|bnep)' || printf '(keine Bluetooth-Module gelistet)\n'

		printf -- '\n--- SCO/eSCO Parameter ---\n'
		local p
		for p in disable_esco disable_ertm; do
			if [ -r "/sys/module/bluetooth/parameters/${p}" ]; then
				printf '%s = %s\n' "$p" "$(cat "/sys/module/bluetooth/parameters/${p}")"
			fi
		done

		printf -- '\n--- dmesg (Bluetooth) ---\n'
		dmesg 2>/dev/null | grep -iE 'bluetooth|btusb|rtl_bt|hci' | tail -n 40 || printf '(kein Zugriff auf dmesg)\n'
	} >>"$GG_BLUETOOTH_LOG" 2>&1

	# Harte Kriterien, die stimmen muessen.
	if ! gg_service_active bluetooth.service; then
		gg_die "bluetooth.service laeuft nicht."
	fi
	if [ -z "$hci" ]; then
		gg_die "Kein Bluetooth-Adapter verfuegbar."
	fi
	if command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth | grep -qi 'blocked: yes'; then
		gg_die "Bluetooth ist per rfkill blockiert."
	fi

	gg_ok "Bluetooth-Diagnose gespeichert in ${GG_BLUETOOTH_LOG}."
	gg_info "Adapter ${hci} / MAC $(gg_bt_address "$hci")"
}

# ---------------------------------------------------------------------

usage() {
	cat <<'USAGE'
Aufruf: install-bluetooth.sh [install|configure|detect|diagnose|all]

  install    Pakete (bluez, rfkill, Firmware) installieren
  configure  /etc/bluetooth/main.conf anpassen
  detect     Adapter erkennen und auswaehlen
  diagnose   Diagnose nach /var/log/gsm-gateway/bluetooth.log schreiben
  all        alles nacheinander (Voreinstellung)
USAGE
}

# GG_CURRENT_STEP wird von gg_die/ERR-Trap in lib/common.sh ausgewertet.
# shellcheck disable=SC2034
case "${1:-all}" in
install) GG_CURRENT_STEP="Bluetooth installieren"; cmd_install ;;
configure) GG_CURRENT_STEP="BlueZ konfigurieren"; cmd_configure ;;
detect) GG_CURRENT_STEP="Bluetooth-Adapter erkennen"; cmd_detect ;;
diagnose) GG_CURRENT_STEP="Bluetooth-Diagnose"; cmd_diagnose ;;
all)
	GG_CURRENT_STEP="Bluetooth einrichten"
	cmd_install
	cmd_configure
	cmd_detect
	cmd_diagnose
	;;
-h | --help | help) usage ;;
*)
	usage
	exit 2
	;;
esac
