#!/usr/bin/env bash
# =====================================================================
#  gateway-credentials.sh - SIP-Zugangsdaten anzeigen
#
#  Das Passwort wird bei der Installation zufaellig erzeugt und liegt
#  ausschliesslich in /etc/gsm-gateway/secrets/ (nur root, 0600).
#  Es steht nirgends im Quellcode und wird bewusst NICHT ins
#  systemd-Journal geschrieben.
#
#  Aufruf:
#     sudo gateway-credentials            uebersichtlich anzeigen
#     sudo gateway-credentials --plain    knapp (fuer Konsolenausgabe)
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

set -euo pipefail
gg_load_config

PLAIN="no"
if [ "${1:-}" = "--plain" ]; then
	PLAIN="yes"
fi

if [ "$(id -u)" -ne 0 ]; then
	printf 'Die Zugangsdaten sind nur fuer root lesbar. Bitte mit sudo starten:\n' >&2
	printf '  sudo gateway-credentials\n' >&2
	exit 1
fi

SECRET_FILE="${GG_SECRET_DIR}/sip-${GG_SIP_EXTENSION}.conf"
if [ ! -r "$SECRET_FILE" ]; then
	printf 'Es sind noch keine SIP-Zugangsdaten vorhanden.\n' >&2
	printf 'Erwartet wurde: %s\n' "$SECRET_FILE" >&2
	printf 'Erzeugen mit:   sudo %s/install/setup-sip.sh\n' "$GG_PREFIX" >&2
	exit 1
fi

# shellcheck source=/dev/null
. "$SECRET_FILE"

SERVER="${SIP_SERVER:-$(gg_primary_ip)}"
CURRENT_IP="$(gg_primary_ip)"

if [ "$PLAIN" = "yes" ]; then
	printf 'SIP-Benutzer: %s\n' "${SIP_USERNAME:-$GG_SIP_EXTENSION}"
	printf 'SIP-Passwort: %s\n' "${SIP_PASSWORD:-unbekannt}"
	printf 'SIP-Server:   %s:%s\n' "$SERVER" "${SIP_PORT:-$GG_SIP_PORT}"
	exit 0
fi

cat <<CREDS

=======================================================
 SIP-Zugangsdaten
=======================================================

  Benutzername / Nebenstelle : ${SIP_USERNAME:-$GG_SIP_EXTENSION}
  Passwort                   : ${SIP_PASSWORD:-unbekannt}
  Server (Domain / Host)     : ${SERVER}
  Port                       : ${SIP_PORT:-$GG_SIP_PORT}
  Transport                  : UDP

So tragen Sie das in ein Softphone ein (z.B. Linphone, Zoiper,
Groundwire, MicroSIP):

  Benutzername : ${SIP_USERNAME:-$GG_SIP_EXTENSION}
  Passwort     : ${SIP_PASSWORD:-unbekannt}
  Domain       : ${SERVER}
  Proxy        : ${SERVER}:${SIP_PORT:-$GG_SIP_PORT}
  Transport    : UDP

Testrufnummern:

  600   Echo-Test (was Sie sagen, kommt zurueck)
  601   Status des Mobilgeraets protokollieren

Wichtig:

  * Dieser Zugang funktioniert nur im lokalen Netz.
  * Bitte KEINE Portweiterleitung auf ${SIP_PORT:-$GG_SIP_PORT} einrichten -
    fuer den Zugriff von unterwegs ist WireGuard vorgesehen.
    Siehe /etc/gsm-gateway/wireguard/README.txt
  * Datei mit den Zugangsdaten: ${SECRET_FILE}

=======================================================

CREDS

if [ -n "$CURRENT_IP" ] && [ -n "${SIP_SERVER:-}" ] && [ "$CURRENT_IP" != "$SIP_SERVER" ]; then
	printf 'ACHTUNG: Die IP-Adresse hat sich geaendert (%s -> %s).\n' "$SIP_SERVER" "$CURRENT_IP"
	printf 'Bitte einmal ausfuehren: sudo %s/install/setup-sip.sh\n' "$GG_PREFIX"
	printf 'Am besten im Router eine feste IP-Adresse (DHCP-Reservierung) vergeben.\n\n'
fi
