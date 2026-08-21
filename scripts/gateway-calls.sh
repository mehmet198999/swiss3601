#!/usr/bin/env bash
# =====================================================================
#  gateway-calls.sh - Anrufliste anzeigen
#
#  Zeigt die letzten Gespraeche: eingehend, ausgehend, verpasst.
#  Grundlage ist die Anrufaufzeichnung von Asterisk
#  (/var/log/asterisk/cdr-csv/Master.csv).
#
#  Aufruf:
#     sudo gateway-calls              die letzten 20 Anrufe
#     sudo gateway-calls --limit 50   die letzten 50
#     sudo gateway-calls --missed     nur verpasste Anrufe
#     sudo gateway-calls --json       maschinenlesbar
#
#  Datenschutz: In der Liste stehen Rufnummern. Die Datei ist nur fuer
#  root und den Benutzer asterisk lesbar.
# =====================================================================

GG_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GG_PREFIX="${GG_PREFIX:-$(dirname "$GG_SELF_DIR")}"
# shellcheck source=../lib/common.sh
. "${GG_PREFIX}/lib/common.sh"

set -uo pipefail
gg_load_config

CDR_FILE="${GG_CDR_FILE:-/var/log/asterisk/cdr-csv/Master.csv}"

if [ ! -r "$CDR_FILE" ] && [ "$(id -u)" -ne 0 ]; then
	printf 'Die Anrufliste ist nur fuer root lesbar. Bitte mit sudo starten:\n' >&2
	printf '  sudo gateway-calls\n' >&2
	exit 1
fi

if [ "$GG_CDR_ENABLE" != "yes" ]; then
	printf 'Die Anrufaufzeichnung ist abgeschaltet (GG_CDR_ENABLE="%s").\n' "$GG_CDR_ENABLE" >&2
	printf 'Einschalten in /etc/gsm-gateway/gateway.conf, danach:\n' >&2
	printf '  sudo %s/install/setup-monitoring.sh\n' "$GG_PREFIX" >&2
	exit 1
fi

exec "${GG_PREFIX}/lib/cdr-report.py" --file "$CDR_FILE" "$@"
