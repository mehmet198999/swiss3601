#!/usr/bin/env bash
# =====================================================================
#  prepare-sdcard.sh - Projekt auf eine frisch geschriebene SD-Karte
#                      legen (laeuft auf dem PC, NICHT auf dem Pi)
#
#  REIHENFOLGE - bitte genau so:
#
#    1. Raspberry Pi Imager: Raspberry Pi OS Lite auf die SD-Karte
#       schreiben, inklusive der Vorkonfiguration (Hostname, Benutzer,
#       SSH, WLAN, Zeitzone).
#    2. SD-Karte danach NICHT auswerfen, sondern erneut einstecken.
#    3. Dieses Script ausfuehren.
#
#  Zwei Betriebsarten:
#
#    rootfs  (empfohlen, nur Linux, braucht root)
#            Legt das Projekt direkt in das Wurzeldateisystem der Karte
#            und aktiviert den Dienst. Voellig unabhaengig von der
#            firstrun.sh des Imagers.
#
#    bootfs  (Linux, macOS, Windows)
#            Legt das Projekt auf die Boot-Partition (FAT) und haengt
#            sich in die firstrun.sh des Imagers ein. Diese Partition
#            ist auf jedem Betriebssystem sichtbar.
#
#  Aufruf:
#     sudo ./sdcard/prepare-sdcard.sh                  automatisch waehlen
#     sudo ./sdcard/prepare-sdcard.sh --mode bootfs    erzwingen
#     sudo ./sdcard/prepare-sdcard.sh --bootfs /media/ich/bootfs \
#                                     --rootfs /media/ich/rootfs
#     ./sdcard/prepare-sdcard.sh --dry-run             nur anzeigen
# =====================================================================

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="auto"
BOOTFS=""
ROOTFS=""
DRY_RUN="no"

# Erkennungsmarke, damit der Bootstrap nicht doppelt eingefuegt wird.
MARKER_BEGIN="# >>> gsm-gateway bootstrap >>>"

info() { printf '\033[1;34m[prepare]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[prepare]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[prepare]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[prepare] FEHLER:\033[0m %s\n' "$*" >&2
	exit 1
}

run() {
	if [ "$DRY_RUN" = "yes" ]; then
		printf '   (dry-run) %s\n' "$*"
		return 0
	fi
	"$@"
}

usage() {
	sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--mode)
		shift
		MODE="${1:-}"
		case "$MODE" in
		auto | rootfs | bootfs) ;;
		*) die "--mode erwartet auto, rootfs oder bootfs." ;;
		esac
		;;
	--bootfs)
		shift
		BOOTFS="${1:-}"
		;;
	--rootfs)
		shift
		ROOTFS="${1:-}"
		;;
	--dry-run) DRY_RUN="yes" ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "Unbekannte Option: $1" ;;
	esac
	shift
done

# ---------------------------------------------------------------------
#  Partitionen finden
# ---------------------------------------------------------------------
looks_like_bootfs() {
	[ -d "$1" ] && [ -f "$1/config.txt" ] && [ -f "$1/cmdline.txt" ]
}

looks_like_rootfs() {
	[ -d "$1" ] && [ -d "$1/etc" ] && [ -d "$1/usr" ] && [ -f "$1/etc/os-release" ]
}

find_bootfs() {
	local candidate
	for candidate in \
		/media/*/bootfs /media/*/boot /media/*/system-boot \
		/media/"${SUDO_USER:-${USER:-root}}"/bootfs /media/"${SUDO_USER:-${USER:-root}}"/boot \
		/run/media/*/bootfs /run/media/*/boot \
		/Volumes/bootfs /Volumes/boot /mnt/bootfs; do
		if looks_like_bootfs "$candidate"; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

find_rootfs() {
	local candidate
	for candidate in \
		/media/*/rootfs /media/"${SUDO_USER:-${USER:-root}}"/rootfs \
		/run/media/*/rootfs /mnt/rootfs; do
		if looks_like_rootfs "$candidate"; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

if [ -z "$BOOTFS" ]; then
	BOOTFS="$(find_bootfs || printf '')"
fi
if [ -z "$ROOTFS" ]; then
	ROOTFS="$(find_rootfs || printf '')"
fi

if [ -n "$BOOTFS" ] && ! looks_like_bootfs "$BOOTFS"; then
	die "In ${BOOTFS} liegen keine config.txt und cmdline.txt - das ist keine Raspberry-Pi-Boot-Partition."
fi
if [ -n "$ROOTFS" ] && ! looks_like_rootfs "$ROOTFS"; then
	die "In ${ROOTFS} liegt kein Linux-Wurzeldateisystem."
fi

info "Boot-Partition:  ${BOOTFS:-nicht gefunden}"
info "Wurzeldateisystem: ${ROOTFS:-nicht gefunden}"

# ---------------------------------------------------------------------
#  Betriebsart bestimmen
# ---------------------------------------------------------------------
if [ "$MODE" = "auto" ]; then
	if [ -n "$ROOTFS" ] && [ "$(id -u)" -eq 0 ]; then
		MODE="rootfs"
	elif [ -n "$BOOTFS" ]; then
		MODE="bootfs"
	else
		die "Weder Boot- noch Wurzelpartition gefunden. Ist die SD-Karte eingesteckt und eingehaengt?
Notfalls die Pfade angeben:
  sudo $0 --bootfs /media/<benutzer>/bootfs --rootfs /media/<benutzer>/rootfs"
	fi
fi
info "Betriebsart: ${MODE}"

if [ "$MODE" = "rootfs" ] && [ -z "$ROOTFS" ]; then
	die "Betriebsart rootfs verlangt eine eingehaengte Wurzelpartition (--rootfs PFAD)."
fi
if [ "$MODE" = "bootfs" ] && [ -z "$BOOTFS" ]; then
	die "Betriebsart bootfs verlangt eine eingehaengte Boot-Partition (--bootfs PFAD)."
fi
if [ "$DRY_RUN" = "no" ] && [ "$(id -u)" -ne 0 ] && [ "$MODE" = "rootfs" ]; then
	die "Betriebsart rootfs braucht root-Rechte. Bitte mit sudo starten."
fi

# ---------------------------------------------------------------------
#  Projektdateien kopieren
# ---------------------------------------------------------------------
copy_project() {
	local dest="$1"
	info "Kopiere Projektdateien nach ${dest}"
	run mkdir -p "$dest"
	if command -v rsync >/dev/null 2>&1; then
		run rsync -a --delete --no-owner --no-group \
			--exclude '.git' --exclude '.github' \
			"${PROJECT_DIR}/" "${dest}/"
	else
		run cp -a "${PROJECT_DIR}/." "${dest}/"
		run rm -rf "${dest}/.git" "${dest}/.github"
	fi
}

# =====================================================================
#  Betriebsart rootfs
# =====================================================================
prepare_rootfs() {
	local target="${ROOTFS}/opt/gsm-gateway"
	copy_project "$target"

	run chown -R 0:0 "$target"
	run find "$target" -type d -exec chmod 0755 {} +
	run find "$target" -type f -exec chmod 0644 {} +
	run find "${target}/install" "${target}/scripts" -type f -name '*.sh' -exec chmod 0755 {} +
	run find "${target}/lib" -type f -name '*.py' -exec chmod 0755 {} +
	run chmod 0755 "${target}/web/status/status-server.py"

	# Konfiguration
	run mkdir -p "${ROOTFS}/etc/gsm-gateway/secrets"
	run chmod 0700 "${ROOTFS}/etc/gsm-gateway/secrets"
	if [ ! -f "${ROOTFS}/etc/gsm-gateway/gateway.conf" ]; then
		run cp "${PROJECT_DIR}/config/gateway.conf.example" \
			"${ROOTFS}/etc/gsm-gateway/gateway.conf"
		run chmod 0644 "${ROOTFS}/etc/gsm-gateway/gateway.conf"
		info "gateway.conf angelegt."
	else
		info "gateway.conf ist bereits vorhanden und bleibt unveraendert."
	fi

	# systemd-Unit aktivieren
	run mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
	run cp "${PROJECT_DIR}/systemd/gsm-gateway-firstboot.service" \
		"${ROOTFS}/etc/systemd/system/gsm-gateway-firstboot.service"
	run chmod 0644 "${ROOTFS}/etc/systemd/system/gsm-gateway-firstboot.service"
	run ln -sfn /etc/systemd/system/gsm-gateway-firstboot.service \
		"${ROOTFS}/etc/systemd/system/multi-user.target.wants/gsm-gateway-firstboot.service"

	# Befehle in /usr/local/bin (Ziele gelten auf dem Pi)
	run mkdir -p "${ROOTFS}/usr/local/bin"
	local script base
	for script in gateway-check.sh bluetooth-check.sh gateway-test.sh \
		pair-iphone.sh backup-gateway.sh uninstall-gateway.sh \
		gateway-credentials.sh gateway-hci-prepare.sh \
		gateway-watchdog.sh gateway-calls.sh; do
		base="${script%.sh}"
		run ln -sfn "/opt/gsm-gateway/scripts/${script}" "${ROOTFS}/usr/local/bin/${script}"
		run ln -sfn "/opt/gsm-gateway/scripts/${script}" "${ROOTFS}/usr/local/bin/${base}"
	done

	run mkdir -p "${ROOTFS}/var/log/gsm-gateway" \
		"${ROOTFS}/var/lib/gsm-gateway/steps" \
		"${ROOTFS}/var/lib/gsm-gateway/facts"

	ok "Wurzeldateisystem vorbereitet - der Dienst startet beim ersten Boot."
}

# =====================================================================
#  Betriebsart bootfs
# =====================================================================
firstrun_snippet() {
	cat <<'SNIPPET'
# >>> gsm-gateway bootstrap >>>
# Von prepare-sdcard.sh eingefuegt. Kopiert das Gateway-Projekt nach
# /opt/gsm-gateway und aktiviert den First-Boot-Dienst.
# Das Ergebnis steht in <boot>/gsm-gateway/bootstrap.log.
# Ein Fehler darf die Erstkonfiguration des Imagers NICHT abbrechen -
# sonst startet der Pi ohne Benutzer und ohne SSH. Der Rueckgabewert
# wird deshalb protokolliert statt weitergereicht.
GG_SRC=""
for _gg_dir in /boot/firmware/gsm-gateway /boot/gsm-gateway; do
    if [ -f "$_gg_dir/install/bootstrap.sh" ]; then
        GG_SRC="$_gg_dir"
        break
    fi
done
if [ -n "$GG_SRC" ]; then
    /bin/bash "$GG_SRC/install/bootstrap.sh" > "$GG_SRC/bootstrap.log" 2>&1
    echo "bootstrap-exit=$?" >> "$GG_SRC/bootstrap.log"
else
    echo "gsm-gateway: Projektdateien auf der Boot-Partition nicht gefunden" >&2
fi
# <<< gsm-gateway bootstrap <<<
SNIPPET
}

prepare_bootfs() {
	copy_project "${BOOTFS}/gsm-gateway"

	local firstrun="${BOOTFS}/firstrun.sh"
	local cmdline="${BOOTFS}/cmdline.txt"

	if [ -f "$firstrun" ]; then
		if grep -qF "$MARKER_BEGIN" "$firstrun"; then
			info "firstrun.sh enthaelt den Bootstrap bereits - wird nicht doppelt eingefuegt."
			ok "Boot-Partition vorbereitet."
			return 0
		fi

		info "Ergaenze die firstrun.sh des Imagers."
		run cp "$firstrun" "${firstrun}.gsm-gateway-backup"

		if [ "$DRY_RUN" = "yes" ]; then
			printf '   (dry-run) Einfuegen nach der ersten Zeile von %s\n' "$firstrun"
		else
			local tmp
			tmp="$(mktemp)"
			{
				head -n1 "$firstrun"
				printf '\n'
				firstrun_snippet
				printf '\n'
				tail -n +2 "$firstrun"
			} >"$tmp"
			cat "$tmp" >"$firstrun"
			rm -f "$tmp"
		fi
		ok "firstrun.sh ergaenzt (Sicherung: firstrun.sh.gsm-gateway-backup)."
	else
		warn "Es gibt keine firstrun.sh - offenbar wurde der Raspberry Pi Imager"
		warn "ohne Vorkonfiguration verwendet. Es wird eine eigene angelegt."
		warn "ACHTUNG: Ohne die Imager-Vorkonfiguration gibt es keinen Benutzer"
		warn "und keinen SSH-Zugang. Besser: die Karte im Imager neu schreiben"
		warn "und dort Hostname, Benutzer und SSH konfigurieren."

		if [ "$DRY_RUN" = "no" ]; then
			{
				printf '#!/bin/bash\n'
				printf '# Von gsm-gateway/prepare-sdcard.sh angelegt.\n'
				printf 'set +e\n\n'
				firstrun_snippet
				printf '\n'
				printf 'rm -f /boot/firmware/firstrun.sh /boot/firstrun.sh\n'
				printf 'sed -i "s| systemd.run[^ ]*||g" /boot/firmware/cmdline.txt 2>/dev/null\n'
				printf 'sed -i "s| systemd.run[^ ]*||g" /boot/cmdline.txt 2>/dev/null\n'
				printf 'exit 0\n'
			} >"$firstrun"
			# Auf FAT-Dateisystemen gibt es keine Ausfuehrungsrechte -
			# ein Fehlschlag ist hier unkritisch, weil die Datei mit
			# "/bin/bash datei" gestartet wird.
			if ! chmod 0755 "$firstrun" 2>/dev/null; then
				info "Ausfuehrungsrecht auf FAT nicht setzbar (unkritisch)."
			fi
		fi

		if ! grep -q 'systemd.run=' "$cmdline"; then
			info "Ergaenze cmdline.txt um den Aufruf der firstrun.sh."
			run cp "$cmdline" "${cmdline}.gsm-gateway-backup"
			if [ "$DRY_RUN" = "no" ]; then
				local line
				line="$(tr -d '\n' <"$cmdline")"
				printf '%s systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n' \
					"$line" >"$cmdline"
			fi
		fi
		ok "Eigene firstrun.sh angelegt."
	fi
}

case "$MODE" in
rootfs) prepare_rootfs ;;
bootfs) prepare_bootfs ;;
esac

cat <<SUMMARY

=======================================================
 SD-Karte vorbereitet
=======================================================

Naechste Schritte:

  1. SD-Karte im Betriebssystem sicher auswerfen
  2. SD-Karte in den Raspberry Pi stecken
  3. ASUS USB-BT500 einstecken
  4. Netzwerkkabel einstecken
  5. Strom anschliessen und warten

Der Pi installiert danach alles selbst. Je nachdem, ob Asterisk
gebaut werden muss, dauert das 30 Minuten bis mehrere Stunden.

Fortschritt ansehen (sobald SSH erreichbar ist):

    ssh gateway@gsm-gateway.local
    sudo tail -f /var/log/gsm-gateway/install.log

=======================================================

SUMMARY
