#!/usr/bin/env bash
# =====================================================================
#  setup-firewall.sh - SIP/RTP auf das LAN begrenzen
#
#  Zwei Bausteine:
#    1. nftables-Tabelle "inet gsm_gateway"
#       Laesst SIP, RTP und die Statusseite nur aus den in
#       GG_LAN_NETWORKS eingetragenen Netzen zu und verwirft sie sonst.
#    2. fail2ban
#       Sperrt IP-Adressen, die wiederholt SIP-Registrierungen
#       fehlschlagen lassen.
#
#  Was hier bewusst NICHT passiert:
#  Es wird keine Firewall mit "policy drop" eingerichtet. Wer sich per
#  SSH verbindet, soll sich mit diesem Script nicht aussperren koennen.
#  Ziel ist "kein offener SIP-Server", nicht "Komplettabschottung".
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
GG_CURRENT_STEP="Firewall vorbereiten"

NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/gsm-gateway.nft"
NFT_MAIN="/etc/nftables.conf"
NFT_INCLUDE='include "/etc/nftables.d/*.nft"'

gg_headline "Firewall vorbereiten"

# ---------------------------------------------------------------------
# 1. nftables
# ---------------------------------------------------------------------
if ! command -v nft >/dev/null 2>&1; then
	if ! gg_apt_install nftables; then
		gg_die "nftables konnte nicht installiert werden."
	fi
fi

# Netzliste in nft-Schreibweise: "a/24, b/16"
LAN_ELEMENTS=""
for net in $GG_LAN_NETWORKS; do
	case "$net" in
	*:*)
		gg_warn "IPv6-Netz ${net} wird uebersprungen - die Regeln arbeiten mit IPv4."
		continue
		;;
	*/*) ;;
	*)
		gg_die "GG_LAN_NETWORKS enthaelt '${net}' ohne Praefixlaenge (erwartet z.B. 192.168.1.0/24)."
		;;
	esac
	if [ -n "$LAN_ELEMENTS" ]; then
		LAN_ELEMENTS="${LAN_ELEMENTS}, ${net}"
	else
		LAN_ELEMENTS="${net}"
	fi
done
if [ -z "$LAN_ELEMENTS" ]; then
	gg_die "GG_LAN_NETWORKS enthaelt kein einziges IPv4-Netz - so waere SIP fuer niemanden erreichbar."
fi

mkdir -p "$NFT_DIR"
if ! gg_render_template "${GG_PREFIX}/etc/nftables/gsm-gateway.nft.template" "$NFT_FILE" \
	"LAN_ELEMENTS=${LAN_ELEMENTS}" \
	"SIP_PORT=${GG_SIP_PORT}" \
	"RTP_START=${GG_RTP_START}" \
	"RTP_END=${GG_RTP_END}" \
	"WEB_PORT=${GG_WEB_PORT}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "Die nftables-Regeldatei konnte nicht erzeugt werden."
fi
chmod 0644 "$NFT_FILE"

# Syntaxpruefung, bevor irgendetwas aktiviert wird.
if ! nft -c -f "$NFT_FILE"; then
	gg_die "Die erzeugten nftables-Regeln sind syntaktisch fehlerhaft: ${NFT_FILE}"
fi
gg_ok "nftables-Regeln geprueft: ${NFT_FILE}"

# In /etc/nftables.conf einbinden, damit sie beim Booten geladen werden.
if [ ! -f "$NFT_MAIN" ]; then
	gg_info "${NFT_MAIN} existiert nicht - wird angelegt."
	cat >"$NFT_MAIN" <<'NFTMAIN'
#!/usr/sbin/nft -f
# Von gsm-gateway angelegt.
flush ruleset
include "/etc/nftables.d/*.nft"
NFTMAIN
	chmod 0755 "$NFT_MAIN"
elif ! grep -qF '/etc/nftables.d/' "$NFT_MAIN"; then
	gg_backup_file "$NFT_MAIN" /etc/backup
	printf '\n# von gsm-gateway ergaenzt\n%s\n' "$NFT_INCLUDE" >>"$NFT_MAIN"
	gg_info "include-Zeile in ${NFT_MAIN} ergaenzt."
else
	gg_info "${NFT_MAIN} bindet /etc/nftables.d/ bereits ein."
fi

# Regeln jetzt aktivieren.
if ! nft -f "$NFT_FILE"; then
	gg_die "Die nftables-Regeln liessen sich nicht laden."
fi
systemctl enable nftables.service
if ! systemctl restart nftables.service; then
	gg_die "nftables.service startet nicht."
fi

if ! nft list table inet gsm_gateway >/dev/null 2>&1; then
	gg_die "Die Tabelle 'inet gsm_gateway' ist nach dem Laden nicht vorhanden."
fi
gg_ok "Firewallregeln aktiv. Anzeigen mit: sudo nft list table inet gsm_gateway"
gg_info "Erlaubte Netze: ${LAN_ELEMENTS}"

# ---------------------------------------------------------------------
# 2. fail2ban
# ---------------------------------------------------------------------
if ! gg_pkg_installed fail2ban; then
	if ! gg_apt_install fail2ban; then
		gg_warn "fail2ban konnte nicht installiert werden - der Schutz gegen"
		gg_warn "SIP-Passwortraten fehlt damit. Die nftables-Regeln greifen trotzdem."
		gg_fact_set fail2ban "no"
		exit 0
	fi
fi

if [ ! -f /etc/fail2ban/filter.d/asterisk.conf ]; then
	gg_warn "fail2ban bringt keinen Asterisk-Filter mit - Jail wird nicht eingerichtet."
	gg_fact_set fail2ban "no"
	exit 0
fi

# nftables-Aktion nur verwenden, wenn diese fail2ban-Version sie kennt.
BANACTION_LINE="# banaction: Voreinstellung der Distribution"
if [ -f /etc/fail2ban/action.d/nftables.conf ]; then
	BANACTION_LINE="banaction = nftables[type=multiport]"
	gg_info "fail2ban nutzt die nftables-Aktion."
fi

mkdir -p /etc/fail2ban/jail.d
if ! gg_render_template "${GG_PREFIX}/etc/fail2ban/jail.d/gsm-gateway.conf.template" \
	/etc/fail2ban/jail.d/gsm-gateway.conf \
	"SIP_PORT=${GG_SIP_PORT}" \
	"BANACTION_LINE=${BANACTION_LINE}" \
	"GENERATED_AT=$(gg_timestamp)"; then
	gg_die "fail2ban-Jail konnte nicht erzeugt werden."
fi
chmod 0644 /etc/fail2ban/jail.d/gsm-gateway.conf

# fail2ban braucht die Logdatei, sonst startet das Jail nicht.
mkdir -p /var/log/asterisk
if [ ! -f /var/log/asterisk/messages ]; then
	touch /var/log/asterisk/messages
	if getent passwd asterisk >/dev/null; then
		chown asterisk:asterisk /var/log/asterisk/messages
	fi
	chmod 0640 /var/log/asterisk/messages
fi

systemctl enable fail2ban.service
if ! systemctl restart fail2ban.service; then
	gg_error "$(journalctl -u fail2ban.service -n 20 --no-pager 2>&1)"
	gg_die "fail2ban.service startet nicht."
fi

# Kurz warten, bis fail2ban die Jails geladen hat.
waited=0
while [ "$waited" -lt 30 ]; do
	if fail2ban-client status asterisk >/dev/null 2>&1; then
		break
	fi
	sleep 2
	waited=$((waited + 2))
done

if fail2ban-client status asterisk >/dev/null 2>&1; then
	gg_ok "fail2ban-Jail 'asterisk' ist aktiv (5 Fehlversuche -> 1 Stunde Sperre)."
	gg_fact_set fail2ban "yes"
else
	gg_warn "Das fail2ban-Jail 'asterisk' meldet sich nicht. Pruefen mit:"
	gg_warn "  sudo fail2ban-client status"
	gg_fact_set fail2ban "partial"
fi
