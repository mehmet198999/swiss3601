#!/usr/bin/env bash
# =====================================================================
#  firstboot-install.sh
#
#  Laeuft beim ersten Start des Raspberry Pi automatisch ueber
#  gsm-gateway-firstboot.service und richtet das komplette Gateway ein.
#
#  Eigenschaften:
#    * jeder Schritt wird einzeln protokolliert und einzeln als
#      "erledigt" markiert  -> nach einem Fehler wird beim naechsten
#      Boot genau dort weitergemacht
#    * Fehler werden NICHT verschluckt (set -Eeuo pipefail + ERR-Trap)
#    * begrenzte Anzahl Versuche -> keine Endlosschleife
#    * nach Erfolg: Marker setzen und Service deaktivieren
#
#  Manuell erneut ausfuehrbar:  sudo /opt/gsm-gateway/install/firstboot-install.sh
#  Einzelnen Schritt wiederholen:
#      sudo rm /var/lib/gsm-gateway/steps/13-asterisk-install.done
#      sudo /opt/gsm-gateway/install/firstboot-install.sh
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

gg_strict
gg_require_root
gg_ensure_dirs
gg_log_target "$GG_INSTALL_LOG"
gg_load_config

GG_FIRSTBOOT_SERVICE="gsm-gateway-firstboot.service"

# ---------------------------------------------------------------------
# Hilfsfunktion: ein Installationsschritt
# ---------------------------------------------------------------------

# gg_run_step <id> <beschreibung> <funktion|kommando> [argumente...]
gg_run_step() {
	local id="$1" desc="$2"
	shift 2
	GG_CURRENT_STEP="${id} - ${desc}"
	if gg_step_is_done "$id"; then
		gg_info "Schritt ${id} (${desc}) war bereits erfolgreich - wird uebersprungen."
		return 0
	fi
	gg_headline "Schritt ${id}: ${desc}"
	gg_set_status "RUNNING" "$GG_CURRENT_STEP"
	"$@"
	gg_step_mark_done "$id"
	gg_ok "Schritt ${id} abgeschlossen: ${desc}"
}

# Ein Sub-Script aus install/ ausfuehren.
gg_sub() {
	local script="$1"
	shift
	local path="${GG_PREFIX}/install/${script}"
	if [ ! -x "$path" ]; then
		gg_die "Installationsscript fehlt oder ist nicht ausfuehrbar: ${path}"
	fi
	"$path" "$@"
}

# ---------------------------------------------------------------------
# Preflight - darf die Installation ueberhaupt jetzt starten?
# ---------------------------------------------------------------------

preflight() {
	GG_CURRENT_STEP="00 - Preflight"

	if [ -f "$GG_COMPLETE_MARKER" ]; then
		gg_info "Setup ist bereits abgeschlossen (${GG_COMPLETE_MARKER}). Nichts zu tun."
		exit 0
	fi

	if [ -f "$GG_ABANDONED_MARKER" ]; then
		gg_warn "Die Erstinstallation wurde nach zu vielen Fehlversuchen dauerhaft gestoppt."
		gg_warn "Ursache siehe ${GG_ERROR_LOG}."
		gg_warn "Nach Behebung: sudo rm ${GG_ABANDONED_MARKER} && sudo systemctl start ${GG_FIRSTBOOT_SERVICE}"
		exit 0
	fi

	# Die Erstkonfiguration des Raspberry Pi Imagers (firstrun.sh) loescht
	# sich selbst und startet danach neu. Solange sie existiert, warten wir.
	local frs
	for frs in /boot/firmware/firstrun.sh /boot/firstrun.sh; do
		if [ -f "$frs" ]; then
			gg_info "Raspberry-Pi-Erstkonfiguration (${frs}) laeuft noch."
			gg_info "Die Gateway-Installation startet automatisch beim naechsten Boot."
			exit 0
		fi
	done

	# Ohne halbwegs korrekte Uhrzeit schlagen TLS-Pruefungen fehl.
	wait_for_clock
}

wait_for_clock() {
	local waited=0
	if ! command -v timedatectl >/dev/null 2>&1; then
		return 0
	fi
	while [ "$waited" -lt 180 ]; do
		if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
			gg_ok "Systemuhr ist mit NTP synchronisiert: $(date)"
			return 0
		fi
		if [ "$waited" -eq 0 ]; then
			gg_info "Warte auf Zeitsynchronisation (max. 180s) ..."
		fi
		sleep 10
		waited=$((waited + 10))
	done
	gg_warn "Zeitsynchronisation nicht bestaetigt. Systemzeit: $(date)"
	gg_warn "Falls Downloads mit Zertifikatsfehlern scheitern, ist das die Ursache."
	return 0
}

# ---------------------------------------------------------------------
# Versuchszaehler - verhindert Endlosschleifen
# ---------------------------------------------------------------------

bump_attempt_counter() {
	local attempts=0
	if [ -r "$GG_ATTEMPT_FILE" ]; then
		attempts="$(tr -cd '0-9' <"$GG_ATTEMPT_FILE")"
		attempts="${attempts:-0}"
	fi
	attempts=$((attempts + 1))
	printf '%s\n' "$attempts" >"$GG_ATTEMPT_FILE"

	if [ "$attempts" -gt "$GG_MAX_INSTALL_ATTEMPTS" ]; then
		gg_error "Versuch ${attempts} von maximal ${GG_MAX_INSTALL_ATTEMPTS} - Installation wird dauerhaft gestoppt."
		gg_set_status "FAILED" "Maximale Anzahl Installationsversuche erreicht"
		printf 'Aufgegeben nach %s Versuchen am %s\n' "$attempts" "$(gg_timestamp)" >"$GG_ABANDONED_MARKER"
		gg_fail_banner "Erstinstallation" \
			"Nach ${GG_MAX_INSTALL_ATTEMPTS} Versuchen war die Installation nicht erfolgreich. Es wird nicht weiter automatisch versucht."
		exit 1
	fi
	gg_info "Installationsversuch ${attempts} von maximal ${GG_MAX_INSTALL_ATTEMPTS}."
}

# =====================================================================
#  Die einzelnen Schritte (Reihenfolge gemaess Projektvorgabe)
# =====================================================================

# --- 1. Hardware erkennen --------------------------------------------
step_hardware() {
	gg_log_target "$GG_HARDWARE_LOG"
	local model mem_kb mem_mb arch cores
	model="$(gg_pi_model)"
	arch="$(uname -m)"
	cores="$(nproc)"
	mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
	mem_mb=$((mem_kb / 1024))

	gg_info "Modell:       ${model}"
	gg_info "Architektur:  ${arch}"
	gg_info "CPU-Kerne:    ${cores}"
	gg_info "Arbeitsspeicher: ${mem_mb} MB"

	gg_fact_set model "$model"
	gg_fact_set arch "$arch"
	gg_fact_set cores "$cores"
	gg_fact_set mem_mb "$mem_mb"

	case "$model" in
	*"Raspberry Pi"*)
		gg_ok "Raspberry Pi erkannt."
		;;
	*)
		gg_warn "Kein Raspberry Pi erkannt (${model}). Das Setup laeuft weiter,"
		gg_warn "ist aber nur auf Raspberry Pi OS getestet."
		;;
	esac

	if [ "$mem_mb" -lt 700 ]; then
		gg_die "Zu wenig Arbeitsspeicher (${mem_mb} MB). Mindestens 1 GB werden benoetigt."
	fi

	{
		printf '\n===== Hardware-Erfassung %s =====\n' "$(gg_timestamp)"
		printf -- '--- /proc/device-tree/model ---\n%s\n' "$model"
		printf -- '--- uname -a ---\n'
		uname -a
		printf -- '--- /proc/cpuinfo ---\n'
		cat /proc/cpuinfo
		printf -- '--- free -h ---\n'
		free -h
		printf -- '--- lsblk ---\n'
		lsblk 2>/dev/null || printf '(lsblk nicht verfuegbar)\n'
		printf -- '--- df -h ---\n'
		df -h
	} >>"$GG_HARDWARE_LOG"

	gg_log_target "$GG_INSTALL_LOG"
}

# --- 2. Betriebssystem erkennen --------------------------------------
step_os() {
	local id codename pretty arch
	id="$(gg_os_id)"
	codename="$(gg_os_codename)"
	pretty="$(gg_os_pretty)"
	arch="$(dpkg --print-architecture)"

	gg_info "Betriebssystem: ${pretty}"
	gg_info "ID:             ${id}"
	gg_info "Codename:       ${codename}"
	gg_info "APT-Architektur: ${arch}"

	gg_fact_set os_id "$id"
	gg_fact_set os_codename "$codename"
	gg_fact_set os_pretty "$pretty"
	gg_fact_set dpkg_arch "$arch"

	case "$id" in
	raspbian | debian)
		gg_ok "Debian-basiertes System - unterstuetzt."
		;;
	*)
		gg_die "Nicht unterstuetztes Betriebssystem: ${pretty}. Erwartet wird Raspberry Pi OS (Debian-basiert)."
		;;
	esac

	case "$codename" in
	bookworm | trixie | forky)
		gg_ok "Distribution '${codename}' ist bekannt und unterstuetzt."
		;;
	bullseye)
		gg_warn "Debian 11 (bullseye) ist sehr alt. Das Setup laeuft, ein aktuelles"
		gg_warn "Raspberry Pi OS wird aber dringend empfohlen."
		;;
	*)
		gg_warn "Unbekannte Distribution '${codename}'. Das Setup versucht es trotzdem."
		;;
	esac

	{
		printf '\n===== Betriebssystem %s =====\n' "$(gg_timestamp)"
		cat /etc/os-release
	} >>"$GG_HARDWARE_LOG"
}

# --- 3. Netzwerk pruefen ---------------------------------------------
step_network() {
	local waited=0 ip gw iface
	while [ "$waited" -lt 120 ]; do
		ip="$(gg_primary_ip)"
		if [ -n "$ip" ]; then
			break
		fi
		if [ "$waited" -eq 0 ]; then
			gg_info "Warte auf eine IP-Adresse (max. 120s) ..."
		fi
		sleep 5
		waited=$((waited + 5))
	done

	ip="$(gg_primary_ip)"
	gw="$(gg_default_gateway)"
	iface="$(gg_default_iface)"

	if [ -z "$ip" ]; then
		gg_die "Keine IP-Adresse erhalten. Bitte Ethernet-Kabel und DHCP im Router pruefen."
	fi
	if [ -z "$gw" ]; then
		gg_die "Kein Standard-Gateway gesetzt. Netzwerkkonfiguration pruefen."
	fi

	gg_info "Schnittstelle: ${iface}"
	gg_info "IP-Adresse:    ${ip}"
	gg_info "Gateway:       ${gw}"
	gg_fact_set lan_ip "$ip"
	gg_fact_set lan_iface "$iface"

	if ! gg_have_internet; then
		gg_die "Keine Internetverbindung. Fuer die Installation werden Pakete aus dem Netz benoetigt."
	fi
	gg_ok "Internetverbindung besteht."
}

# --- 4. DNS pruefen ---------------------------------------------------
step_dns() {
	local waited=0
	while [ "$waited" -lt 60 ]; do
		if gg_dns_works; then
			gg_ok "Namensaufloesung funktioniert. DNS-Server: $(gg_dns_servers)"
			return 0
		fi
		sleep 5
		waited=$((waited + 5))
	done
	gg_error "DNS-Server laut System: $(gg_dns_servers)"
	gg_die "Namensaufloesung schlaegt fehl. Ohne DNS koennen keine Pakete geladen werden."
}

# --- 5. apt update ----------------------------------------------------
step_apt_update() {
	if ! gg_apt_update; then
		gg_die "'apt-get update' ist fehlgeschlagen. Paketquellen bzw. Internetverbindung pruefen."
	fi
	gg_ok "Paketlisten aktualisiert."
}

# --- 6. System aktualisieren -----------------------------------------
step_system_upgrade() {
	if [ "$GG_FULL_UPGRADE" != "yes" ]; then
		gg_warn "GG_FULL_UPGRADE=no - das System wird NICHT aktualisiert."
		return 0
	fi
	gg_info "Systemaktualisierung laeuft. Das kann beim ersten Start lange dauern."
	if ! gg_apt_wait; then
		gg_die "APT ist dauerhaft gesperrt."
	fi
	if ! DEBIAN_FRONTEND=noninteractive apt-get -y \
		-o Acquire::Retries=3 \
		-o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold \
		full-upgrade; then
		gg_die "Systemaktualisierung ('apt-get full-upgrade') fehlgeschlagen."
	fi
	if ! gg_apt_wait; then
		gg_die "APT ist nach dem Upgrade dauerhaft gesperrt."
	fi
	DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
	gg_ok "System ist aktuell."
}

# --- 7. Basisprogramme installieren ----------------------------------
step_base_packages() {
	local pkgs=(
		ca-certificates curl wget gnupg
		rsync less nano
		usbutils pciutils
		iproute2 iputils-ping dnsutils
		logrotate
		python3
		jq
		file
		procps psmisc
		sudo
		avahi-daemon libnss-mdns
		nftables
	)
	if ! gg_apt_install "${pkgs[@]}"; then
		gg_die "Installation der Basispakete fehlgeschlagen."
	fi

	# avahi sorgt dafuer, dass gsm-gateway.local im LAN aufloesbar ist.
	systemctl enable --now avahi-daemon.service
	gg_ok "Basispakete installiert, mDNS (gsm-gateway.local) aktiv."
}

# --- 7a. Zeitzone, Locale, Hostname (Zusatzschritt) ------------------
step_locale_time() {
	# Der Raspberry Pi Imager setzt diese Werte normalerweise schon.
	# Hier wird nur nachgezogen, was fehlt - nichts wird ueberschrieben,
	# das bereits korrekt ist.
	local current_tz current_host
	current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || printf '')"
	if [ "$current_tz" != "$GG_TIMEZONE" ]; then
		gg_info "Setze Zeitzone auf ${GG_TIMEZONE} (war: ${current_tz:-unbekannt})."
		timedatectl set-timezone "$GG_TIMEZONE"
	else
		gg_info "Zeitzone bereits korrekt: ${current_tz}"
	fi

	current_host="$(hostnamectl --static 2>/dev/null || hostname)"
	if [ -z "$current_host" ] || [ "$current_host" = "raspberrypi" ]; then
		gg_info "Setze Hostnamen auf ${GG_HOSTNAME} (war: ${current_host:-leer})."
		hostnamectl set-hostname "$GG_HOSTNAME"
		if grep -q '127.0.1.1' /etc/hosts; then
			sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${GG_HOSTNAME}/" /etc/hosts
		else
			printf '127.0.1.1\t%s\n' "$GG_HOSTNAME" >>/etc/hosts
		fi
	else
		gg_info "Hostname bleibt unveraendert: ${current_host}"
	fi

	# Locale erzeugen, falls noch nicht vorhanden.
	if ! locale -a 2>/dev/null | grep -qi "^${GG_LOCALE%%.*}"; then
		gg_info "Erzeuge Locale ${GG_LOCALE}."
		if ! gg_pkg_installed locales; then
			gg_apt_install locales
		fi
		if ! grep -qE "^[# ]*${GG_LOCALE} " /etc/locale.gen 2>/dev/null; then
			printf '%s UTF-8\n' "$GG_LOCALE" >>/etc/locale.gen
		fi
		sed -i "s/^# *\(${GG_LOCALE} UTF-8\)/\1/" /etc/locale.gen
		locale-gen "$GG_LOCALE"
	else
		gg_info "Locale ${GG_LOCALE} ist vorhanden."
	fi
	gg_ok "Zeitzone, Hostname und Locale geprueft."
}

# --- 7b. Logrotate (Zusatzschritt) -----------------------------------
step_logrotate() {
	install -m 0644 "${GG_PREFIX}/etc/logrotate.d/gsm-gateway" /etc/logrotate.d/gsm-gateway
	if ! logrotate --debug /etc/logrotate.d/gsm-gateway >/dev/null; then
		gg_die "Die logrotate-Konfiguration /etc/logrotate.d/gsm-gateway ist fehlerhaft."
	fi
	gg_ok "Logrotation fuer ${GG_LOG_DIR} eingerichtet."
}

# --- 8..11 Bluetooth --------------------------------------------------
step_bluetooth_install() { gg_sub install-bluetooth.sh install; }
step_bluez_config() { gg_sub install-bluetooth.sh configure; }
step_adapter_detect() { gg_sub install-bluetooth.sh detect; }
step_bluetooth_diagnose() { gg_sub install-bluetooth.sh diagnose; }

# --- 12. Audio --------------------------------------------------------
step_audio() { gg_sub setup-audio.sh; }

# --- 13..15 Asterisk / chan_mobile -----------------------------------
step_asterisk_install() { gg_sub install-asterisk.sh install; }
step_chan_mobile_check() { gg_sub install-asterisk.sh check-chan-mobile; }
step_chan_mobile_build() { gg_sub install-asterisk.sh ensure-chan-mobile; }

# --- 16. Asterisk konfigurieren --------------------------------------
step_asterisk_config() { gg_sub setup-chan-mobile.sh; }
step_sip_config() { gg_sub setup-sip.sh; }

# --- 17. Firewall -----------------------------------------------------
step_firewall() { gg_sub setup-firewall.sh; }

# --- 17a. Web-Statusseite (Zusatzschritt) ----------------------------
step_web() { gg_sub setup-web.sh; }

# --- 17b. Watchdog und Anrufliste (Zusatzschritt) --------------------
step_monitoring() { gg_sub setup-monitoring.sh; }

# --- 18. Diagnose -----------------------------------------------------
step_diagnostics() {
	# Die Diagnose darf die Installation nicht abbrechen - sie sammelt
	# nur Informationen. Ein Fehlschlag wird aber deutlich protokolliert.
	if ! "${GG_PREFIX}/scripts/gateway-check.sh" --quiet; then
		gg_warn "gateway-check.sh meldete Probleme - Details in ${GG_HARDWARE_LOG}."
	fi
	if ! "${GG_PREFIX}/scripts/bluetooth-check.sh" --quiet; then
		gg_warn "bluetooth-check.sh meldete Probleme - Details in ${GG_BLUETOOTH_LOG}."
	fi
	gg_ok "Diagnosedaten gesammelt."
}

# --- 19. Statusbericht ------------------------------------------------
step_report() {
	gg_info "Erzeuge Statusbericht ..."
	if ! "${GG_PREFIX}/scripts/gateway-test.sh" --no-color | tee -a "$GG_STATUS_LOG"; then
		gg_warn "gateway-test.sh meldete offene Punkte (erwartet, solange kein iPhone gekoppelt ist)."
	fi
	gg_ok "Statusbericht liegt in ${GG_STATUS_LOG}."
}

# --- 20. First-Boot-Service deaktivieren ------------------------------
step_finalize() {
	printf 'GSM-Gateway Setup abgeschlossen am %s\n' "$(gg_timestamp)" >"$GG_COMPLETE_MARKER"
	gg_set_status "OK" "Setup abgeschlossen"

	if gg_service_enabled "$GG_FIRSTBOOT_SERVICE"; then
		systemctl disable "$GG_FIRSTBOOT_SERVICE"
		gg_ok "${GG_FIRSTBOOT_SERVICE} deaktiviert - laeuft beim naechsten Boot nicht erneut."
	else
		gg_info "${GG_FIRSTBOOT_SERVICE} war bereits deaktiviert."
	fi
}

# ---------------------------------------------------------------------
# Abschlussmeldung
# ---------------------------------------------------------------------

final_banner() {
	local bt_state="NOT DETECTED" ast_state="NOT READY" cm_state="NOT READY" bt_addr
	bt_addr="$(gg_fact_get bt_adapter_address "")"
	if [ -n "$bt_addr" ]; then
		bt_state="DETECTED"
	fi
	if [ -n "$(gg_asterisk_version)" ]; then
		ast_state="READY"
	fi
	if gg_chan_mobile_file >/dev/null 2>&1; then
		cm_state="READY"
	fi

	local banner
	banner="$(
		cat <<BANNER

=============================================
 GSM -> SIP GATEWAY SETUP COMPLETE
=============================================

Raspberry Pi:       READY
Bluetooth:          $(gg_service_active bluetooth.service && printf 'READY' || printf 'NOT RUNNING')
ASUS BT500:         ${bt_state}
Asterisk:           ${ast_state}
chan_mobile:        ${cm_state}

Next step:

1. iPhone 11 Pro Bluetooth einschalten
2. pair-iphone.sh ausfuehren
3. HFP pruefen
4. GSM-Testanruf durchfuehren

IMPORTANT:

Internet SIP access is NOT enabled.

=============================================
BANNER
	)"

	printf '%s\n' "$banner"
	printf '%s\n' "$banner" >>"$GG_STATUS_LOG"
	printf '%s\n' "$banner" >>"$GG_INSTALL_LOG"

	# Zugangsdaten nur auf der physischen Konsole zeigen, damit sie nicht
	# im systemd-Journal landen.
	if [ -w /dev/console ] && [ -x "${GG_PREFIX}/scripts/gateway-credentials.sh" ]; then
		{
			printf '\n%s\n' "$banner"
			if ! "${GG_PREFIX}/scripts/gateway-credentials.sh" --plain; then
				printf 'SIP-Zugangsdaten konnten nicht gelesen werden - siehe %s\n' "$GG_ERROR_LOG"
			fi
		} >/dev/console
	fi

	gg_info "SIP-Zugangsdaten anzeigen:  sudo gateway-credentials"
	gg_info "Status pruefen:             sudo gateway-test"
	gg_info "iPhone koppeln:             sudo pair-iphone"
}

# =====================================================================
#  Ablauf
# =====================================================================

main() {
	gg_headline "GSM -> SIP Gateway - Erstinstallation"
	gg_info "Startzeit: $(gg_timestamp)"
	gg_info "Projektverzeichnis: ${GG_PREFIX}"
	gg_info "Protokoll: ${GG_INSTALL_LOG}"

	preflight
	bump_attempt_counter

	gg_run_step "01-hardware"            "Hardware erkennen"                 step_hardware
	gg_run_step "02-os"                  "Betriebssystem erkennen"           step_os
	gg_run_step "03-network"             "Netzwerk pruefen"                  step_network
	gg_run_step "04-dns"                 "DNS pruefen"                       step_dns
	gg_run_step "05-apt-update"          "Paketlisten aktualisieren"         step_apt_update
	gg_run_step "06-system-upgrade"      "System aktualisieren"              step_system_upgrade
	gg_run_step "07-base-packages"       "Basisprogramme installieren"       step_base_packages
	gg_run_step "07a-locale-time"        "Zeitzone, Hostname, Locale"        step_locale_time
	gg_run_step "07b-logrotate"          "Logrotation einrichten"            step_logrotate
	gg_run_step "08-bluetooth-install"   "Bluetooth installieren"            step_bluetooth_install
	gg_run_step "09-bluez-config"        "BlueZ konfigurieren"               step_bluez_config
	gg_run_step "10-adapter-detect"      "Bluetooth-Adapter erkennen"        step_adapter_detect
	gg_run_step "11-bluetooth-diagnose"  "Bluetooth-Diagnose"                step_bluetooth_diagnose
	gg_run_step "12-audio"               "Audio-Unterstuetzung vorbereiten"  step_audio
	gg_run_step "13-asterisk-install"    "Asterisk installieren"             step_asterisk_install
	gg_run_step "14-chan-mobile-check"   "chan_mobile pruefen"               step_chan_mobile_check
	gg_run_step "15-chan-mobile-build"   "chan_mobile bereitstellen"         step_chan_mobile_build
	gg_run_step "16-asterisk-config"     "Asterisk/chan_mobile konfigurieren" step_asterisk_config
	gg_run_step "16a-sip-config"         "SIP einrichten (nur LAN)"          step_sip_config
	gg_run_step "17-firewall"            "Firewall vorbereiten"              step_firewall
	gg_run_step "17a-web-status"         "Web-Statusseite einrichten"        step_web
	gg_run_step "17b-monitoring"         "Watchdog und Anrufliste"           step_monitoring
	gg_run_step "18-diagnostics"         "Diagnose durchfuehren"             step_diagnostics
	gg_run_step "19-report"              "Statusbericht erstellen"           step_report
	gg_run_step "20-finalize"            "Erstinstallation abschliessen"     step_finalize

	GG_CURRENT_STEP="Abschluss"
	final_banner
	gg_ok "Erstinstallation erfolgreich abgeschlossen."
}

main "$@"
