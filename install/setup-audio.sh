#!/usr/bin/env bash
# =====================================================================
#  setup-audio.sh - Sprachkanal vorbereiten
#
#  WICHTIG - bitte einmal lesen, das ist der am haeufigsten
#  missverstandene Teil des Projekts:
#
#  chan_mobile benutzt WEDER ALSA NOCH PulseAudio NOCH PipeWire NOCH
#  BlueALSA. Der Kanaltreiber oeffnet den Bluetooth-SCO-Socket selbst
#  und tauscht die Sprachdaten direkt mit Asterisk aus:
#
#      iPhone-Mikrofon -> HFP/SCO -> chan_mobile -> Asterisk -> SIP
#      SIP -> Asterisk -> chan_mobile -> HFP/SCO -> iPhone-Lautsprecher
#
#  Ein zusaetzliches Audiosystem ist deshalb nicht noetig - es waere
#  sogar schaedlich: PulseAudio, PipeWire und BlueALSA registrieren
#  ueber die BlueZ-Profile-API selbst HFP/HSP. Dann streiten sich zwei
#  Programme um denselben Dienst des iPhones, und typischerweise
#  gewinnt keines davon.
#
#  Dieses Script installiert daher KEIN Audiosystem, sondern stellt
#  sicher, dass keines im Weg steht, und prueft, ob der SCO-Pfad des
#  Kernels benutzbar ist.
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

# shellcheck disable=SC2034
GG_CURRENT_STEP="Audio-Unterstuetzung vorbereiten"

MODPROBE_CONF="/etc/modprobe.d/gsm-gateway-bluetooth.conf"

# Dienste, die sich mit chan_mobile um das HFP-Profil streiten wuerden.
COMPETING_UNITS=(
	bluealsa.service
	bluetooth-meshd.service
	pulseaudio.service
	pipewire.service
	pipewire-pulse.service
	wireplumber.service
)

gg_headline "Sprachkanal (HFP/SCO) vorbereiten"

# ---------------------------------------------------------------------
# 1. Konkurrierende Audio-Dienste
# ---------------------------------------------------------------------
disabled_any=0
for unit in "${COMPETING_UNITS[@]}"; do
	if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
		continue
	fi
	if ! systemctl cat "$unit" >/dev/null 2>&1; then
		continue
	fi
	if systemctl is-active --quiet "$unit"; then
		gg_warn "${unit} laeuft und wuerde chan_mobile das HFP-Profil streitig machen."
		systemctl stop "$unit"
		systemctl mask "$unit"
		gg_warn "${unit} wurde gestoppt und maskiert."
		gg_warn "Rueckgaengig machen: sudo systemctl unmask ${unit}"
		disabled_any=1
	elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
		gg_warn "${unit} ist aktiviert (laeuft aber nicht). Wird maskiert, damit"
		gg_warn "es beim naechsten Boot nicht mit chan_mobile kollidiert."
		systemctl mask "$unit"
		disabled_any=1
	fi
done

if [ "$disabled_any" -eq 0 ]; then
	gg_ok "Kein konkurrierendes Audiosystem aktiv - genau so soll es sein."
fi

# Auch nur installierte Pakete sind einen Hinweis wert.
for pkg in bluez-alsa-utils pulseaudio pipewire pipewire-pulse; do
	if gg_pkg_installed "$pkg"; then
		gg_warn "Paket ${pkg} ist installiert. Fuer dieses Gateway wird es nicht"
		gg_warn "benoetigt. Falls Audioprobleme auftreten, zuerst hier suchen."
	fi
done

# ---------------------------------------------------------------------
# 2. USB-Autosuspend fuer den Bluetooth-Adapter abschalten
# ---------------------------------------------------------------------
# Legt der Kernel den USB-Adapter waehrend eines Gespraechs schlafen,
# reisst die SCO-Verbindung ab. Fuer ein Telefonie-Gateway ist der
# Stromsparmodus die falsche Voreinstellung.
cat >"$MODPROBE_CONF" <<'MODPROBE'
# Von gsm-gateway angelegt - siehe install/setup-audio.sh
#
# USB-Autosuspend fuer Bluetooth-Adapter abschalten. Sonst kann der
# Kernel den Adapter waehrend eines Telefonats schlafen legen und die
# SCO-Sprachverbindung reisst ab.
options btusb enable_autosuspend=0
MODPROBE
chmod 0644 "$MODPROBE_CONF"
gg_ok "USB-Autosuspend fuer btusb deaktiviert (${MODPROBE_CONF})."

# Laufenden Treiber ebenfalls umstellen, damit kein Neustart noetig ist.
if [ -w /sys/module/btusb/parameters/enable_autosuspend ]; then
	printf 'N\n' >/sys/module/btusb/parameters/enable_autosuspend
	gg_info "Laufender btusb-Treiber auf enable_autosuspend=N umgestellt."
fi

# ---------------------------------------------------------------------
# 3. SCO-Unterstuetzung des Kernels pruefen
# ---------------------------------------------------------------------
sco_result="$("${GG_PREFIX}/lib/sco-check.py" 2>&1)" && sco_rc=0 || sco_rc=$?
if [ "$sco_rc" -ne 0 ]; then
	gg_error "${sco_result}"
	gg_die "Der Kernel stellt keine SCO-Sockets bereit. Ohne SCO gibt es keinen Sprachkanal."
fi
gg_ok "$sco_result"
gg_fact_set sco_available "yes"

# eSCO-Status protokollieren. eSCO ist die modernere Variante; einige
# Adapter kommen damit nicht zurecht. Umschalten ist ein
# Troubleshooting-Schritt, keine Voreinstellung - siehe
# docs/TROUBLESHOOTING.md.
if [ -r /sys/module/bluetooth/parameters/disable_esco ]; then
	esco="$(cat /sys/module/bluetooth/parameters/disable_esco)"
	gg_info "Kernelparameter bluetooth.disable_esco = ${esco}"
	gg_fact_set disable_esco "$esco"
fi

# ---------------------------------------------------------------------
# 4. Protokoll
# ---------------------------------------------------------------------
{
	printf '\n===== Audio-/SCO-Vorbereitung %s =====\n' "$(gg_timestamp)"
	printf 'Audio-Architektur: keine - chan_mobile nutzt SCO-Sockets direkt\n'
	printf 'SCO verfuegbar:    %s\n' "$sco_result"
	printf 'btusb autosuspend: aus (%s)\n' "$MODPROBE_CONF"
	printf -- '--- geladene Bluetooth-Module ---\n'
	lsmod | grep -E '^(bluetooth|btusb|btrtl|btbcm|hci_uart)' || printf '(keine)\n'
} >>"$GG_BLUETOOTH_LOG" 2>&1

gg_ok "Sprachkanal vorbereitet. Es wurde bewusst kein zusaetzliches Audiosystem installiert."
