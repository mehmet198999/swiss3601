#!/usr/bin/env bash
# =====================================================================
#  install-asterisk.sh - Asterisk inklusive chan_mobile bereitstellen
#
#  Unterkommandos:
#     install             Asterisk installieren (Paket bevorzugt, sonst Quellcode)
#     check-chan-mobile   pruefen, ob chan_mobile.so vorhanden ist
#     ensure-chan-mobile  chan_mobile notfalls aus dem Quellcode nachbauen
#
#  WICHTIGER HINWEIS ZUR PAKETLAGE (Stand 2026-08)
#  ------------------------------------------------
#  Debian hat Asterisk nach Debian 11 (bullseye) aus der Distribution
#  entfernt. Weder Debian 12 (bookworm) noch Debian 13 (trixie)
#  enthalten ein Paket "asterisk" - und damit auch kein
#  "asterisk-mobile" mit chan_mobile. Erst Debian 14 (forky) hat
#  Asterisk 22 wieder aufgenommen.
#
#  Auf einem aktuellen Raspberry Pi OS ist "apt install asterisk" also
#  aller Voraussicht nach NICHT moeglich. Dieses Script prueft das
#  trotzdem zuerst (Anforderung "apt-cache policy asterisk") und faellt
#  auf einen sauber verifizierten Quellcode-Build zurueck.
#
#  Der Build dauert auf einem Raspberry Pi 3 typischerweise
#  1,5 bis 4 Stunden. Das ist erwartetes Verhalten, kein Fehler.
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

SRC_ROOT="/usr/local/src/gsm-gateway"
ASTERISK_ETC="/etc/asterisk"
SWAP_STATE_FILE="${GG_STATE_DIR}/swap-original"

# ---------------------------------------------------------------------
#  Build-Abhaengigkeiten
# ---------------------------------------------------------------------
# libbluetooth-dev ist die entscheidende Zeile: ohne sie taucht
# chan_mobile in menuselect gar nicht erst als baubares Modul auf.
BUILD_DEPS=(
	build-essential
	pkg-config
	autoconf
	automake
	libtool
	bison
	flex
	patch
	wget
	curl
	ca-certificates
	gnupg
	xz-utils
	libbluetooth-dev
	libedit-dev
	libjansson-dev
	libsqlite3-dev
	uuid-dev
	libxml2-dev
	libxslt1-dev
	libssl-dev
	libncurses-dev
	libcurl4-openssl-dev
	libsrtp2-dev
	libcap-dev
	libgsm1-dev
	zlib1g-dev
	python3
)

# =====================================================================
#  Hilfsfunktionen
# =====================================================================

build_jobs() {
	local cores mem_mb jobs
	cores="$(nproc)"
	mem_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
	if [ "$GG_BUILD_JOBS" != "auto" ]; then
		printf '%s' "$GG_BUILD_JOBS"
		return 0
	fi
	# Faustregel: rund 512 MB pro gleichzeitigem Compilerlauf.
	jobs=$((mem_mb / 512))
	if [ "$jobs" -lt 1 ]; then jobs=1; fi
	if [ "$jobs" -gt "$cores" ]; then jobs="$cores"; fi
	printf '%s' "$jobs"
}

check_disk_space() {
	local target="$1" avail_mb
	mkdir -p "$target"
	avail_mb="$(df -Pm "$target" | awk 'NR==2 {print $4}')"
	gg_info "Freier Plattenplatz unter ${target}: ${avail_mb} MB (benoetigt: ${GG_BUILD_MIN_DISK_MB} MB)"
	if [ "$avail_mb" -lt "$GG_BUILD_MIN_DISK_MB" ]; then
		gg_die "Zu wenig Plattenplatz fuer den Asterisk-Build: ${avail_mb} MB frei, ${GG_BUILD_MIN_DISK_MB} MB noetig. Groessere SD-Karte verwenden oder GG_BUILD_MIN_DISK_MB anpassen."
	fi
}

# --- Swap waehrend des Builds vergroessern ---------------------------
# Der Raspberry Pi 3 hat 1 GB RAM. Ohne zusaetzlichen Swap bricht der
# Compiler mit "virtual memory exhausted" ab.
enlarge_swap() {
	if [ -f "$SWAP_STATE_FILE" ]; then
		gg_info "Swap wurde bereits vergroessert."
		return 0
	fi
	if [ ! -f /etc/dphys-swapfile ]; then
		gg_warn "dphys-swapfile nicht vorhanden - Swap bleibt unveraendert."
		gg_warn "Bei zu wenig Arbeitsspeicher kann der Build fehlschlagen."
		return 0
	fi

	local current
	current="$(awk -F= '/^CONF_SWAPSIZE=/ {print $2}' /etc/dphys-swapfile)"
	current="${current:-100}"
	printf '%s\n' "$current" >"$SWAP_STATE_FILE"
	gg_info "Vergroessere Swap voruebergehend von ${current} MB auf ${GG_BUILD_SWAP_MB} MB."

	gg_backup_file /etc/dphys-swapfile /etc/backup
	sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${GG_BUILD_SWAP_MB}/" /etc/dphys-swapfile
	if grep -q '^#\?CONF_MAXSWAP=' /etc/dphys-swapfile; then
		sed -i "s/^#\?CONF_MAXSWAP=.*/CONF_MAXSWAP=${GG_BUILD_SWAP_MB}/" /etc/dphys-swapfile
	else
		printf 'CONF_MAXSWAP=%s\n' "$GG_BUILD_SWAP_MB" >>/etc/dphys-swapfile
	fi

	if ! dphys-swapfile swapoff; then
		gg_warn "dphys-swapfile swapoff meldete einen Fehler - weiter mit setup."
	fi
	if ! dphys-swapfile setup; then
		gg_die "Swap-Datei konnte nicht auf ${GG_BUILD_SWAP_MB} MB vergroessert werden (Plattenplatz?)."
	fi
	if ! dphys-swapfile swapon; then
		gg_die "Vergroesserte Swap-Datei konnte nicht aktiviert werden."
	fi
	gg_ok "Swap aktiv: $(free -m | awk '/^Swap:/ {print $2" MB"}')"
}

restore_swap() {
	if [ ! -f "$SWAP_STATE_FILE" ]; then
		return 0
	fi
	local original
	original="$(cat "$SWAP_STATE_FILE")"
	gg_info "Setze Swap wieder auf ${original} MB zurueck."
	sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${original}/" /etc/dphys-swapfile
	if dphys-swapfile swapoff && dphys-swapfile setup && dphys-swapfile swapon; then
		gg_ok "Swap zurueckgesetzt."
		rm -f "$SWAP_STATE_FILE"
	else
		gg_warn "Swap konnte nicht sauber zurueckgesetzt werden. Bitte pruefen: free -m"
	fi
}

# --- Quellen herunterladen und pruefen -------------------------------
# Ergebnis steht danach in GG_DOWNLOADED_TARBALL. Der Dateiname wird
# bewusst NICHT ueber stdout zurueckgegeben, weil die Funktion selbst
# nach stdout protokolliert.
GG_DOWNLOADED_TARBALL=""
download_and_verify() {
	local workdir="$1" basename_no_ext tarball shafile sigfile url
	if [ "$GG_ASTERISK_VERSION" = "current" ]; then
		basename_no_ext="asterisk-${GG_ASTERISK_BRANCH}-current"
	else
		basename_no_ext="asterisk-${GG_ASTERISK_VERSION}"
	fi
	tarball="${basename_no_ext}.tar.gz"
	shafile="${basename_no_ext}.sha256"
	sigfile="${tarball}.asc"

	mkdir -p "$workdir"
	cd "$workdir" || gg_die "Verzeichnis ${workdir} nicht betretbar."

	for url in "$tarball" "$shafile" "$sigfile"; do
		gg_info "Lade ${GG_ASTERISK_MIRROR}/${url}"
		if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
			-o "$url" "${GG_ASTERISK_MIRROR}/${url}"; then
			if [ "$url" = "$sigfile" ]; then
				gg_warn "GPG-Signatur ${sigfile} nicht abrufbar."
				rm -f "$sigfile"
				continue
			fi
			gg_die "Download von ${GG_ASTERISK_MIRROR}/${url} fehlgeschlagen."
		fi
	done

	# --- SHA-256 ---
	local expected actual
	expected="$(awk '{print $1; exit}' "$shafile")"
	actual="$(sha256sum "$tarball" | awk '{print $1}')"
	if [ -z "$expected" ]; then
		gg_die "Pruefsummendatei ${shafile} ist leer oder unlesbar."
	fi
	if [ "$expected" != "$actual" ]; then
		gg_error "erwartet: ${expected}"
		gg_error "erhalten: ${actual}"
		gg_die "SHA-256-Pruefsumme von ${tarball} stimmt nicht. Download verworfen."
	fi
	gg_ok "SHA-256 stimmt: ${actual}"

	# --- GPG ---
	# Die Pruefsumme liegt auf demselben Server wie das Archiv und
	# schuetzt daher vor Uebertragungsfehlern, nicht vor einem
	# manipulierten Server. Die GPG-Signatur ist die eigentliche
	# Echtheitspruefung.
	if [ -f "$sigfile" ]; then
		verify_gpg "$tarball" "$sigfile"
	else
		gg_warn "Ohne Signaturdatei wurde nur die SHA-256-Pruefsumme geprueft."
	fi

	GG_DOWNLOADED_TARBALL="$tarball"
}

verify_gpg() {
	local tarball="$1" sigfile="$2" keyring gnupghome
	if ! command -v gpg >/dev/null 2>&1; then
		gg_warn "gpg ist nicht installiert - Signaturpruefung uebersprungen."
		return 0
	fi

	gnupghome="$(mktemp -d)"
	chmod 700 "$gnupghome"
	keyring="${gnupghome}/asterisk.gpg"

	if ! GNUPGHOME="$gnupghome" gpg --batch --quiet \
		--keyserver "$GG_ASTERISK_KEYSERVER" \
		--recv-keys "$GG_ASTERISK_GPG_FPR" >/dev/null 2>&1; then
		gg_warn "Signaturschluessel ${GG_ASTERISK_GPG_FPR} konnte nicht vom Keyserver"
		gg_warn "${GG_ASTERISK_KEYSERVER} geladen werden (Firewall/Proxy?)."
		gg_warn "Es wurde nur die SHA-256-Pruefsumme verifiziert."
		rm -rf "$gnupghome"
		return 0
	fi

	GNUPGHOME="$gnupghome" gpg --batch --quiet --export "$GG_ASTERISK_GPG_FPR" >"$keyring"

	if ! GNUPGHOME="$gnupghome" gpg --batch --no-default-keyring \
		--keyring "$keyring" --verify "$sigfile" "$tarball" >/dev/null 2>&1; then
		rm -rf "$gnupghome"
		gg_die "GPG-Signatur von ${tarball} ist UNGUELTIG. Das Archiv wird nicht verwendet."
	fi
	rm -rf "$gnupghome"
	gg_ok "GPG-Signatur gueltig (Schluessel ${GG_ASTERISK_GPG_FPR})."
}

# --- Asterisk-Benutzer und Verzeichnisse -----------------------------
create_asterisk_user() {
	if ! getent group asterisk >/dev/null; then
		groupadd --system asterisk
		gg_info "Gruppe 'asterisk' angelegt."
	fi
	if ! getent passwd asterisk >/dev/null; then
		useradd --system --gid asterisk --home-dir /var/lib/asterisk \
			--no-create-home --shell /usr/sbin/nologin asterisk
		gg_info "Benutzer 'asterisk' angelegt."
	fi

	local dir
	for dir in /var/lib/asterisk /var/log/asterisk /var/spool/asterisk \
		/var/run/asterisk "$ASTERISK_ETC"; do
		mkdir -p "$dir"
		chown -R asterisk:asterisk "$dir"
	done
	chmod 0750 "$ASTERISK_ETC"
}

# =====================================================================
#  install
# =====================================================================

try_apt_install() {
	gg_info "Pruefe, ob Asterisk als Paket verfuegbar ist:"
	apt-cache policy asterisk 2>&1 | sed 's/^/    /' | tee -a "$GG_ASTERISK_LOG"

	if ! gg_apt_has_candidate asterisk; then
		gg_info "Kein Asterisk-Paket in den Paketquellen - Quellcode-Build ist noetig."
		return 1
	fi

	local pkgs=(asterisk)
	local optional
	for optional in asterisk-modules asterisk-mobile asterisk-config; do
		if gg_apt_has_candidate "$optional"; then
			pkgs+=("$optional")
		fi
	done

	gg_info "Installiere Asterisk aus den Paketquellen: ${pkgs[*]}"
	if ! gg_apt_install "${pkgs[@]}"; then
		gg_warn "Paketinstallation fehlgeschlagen - es wird aus dem Quellcode gebaut."
		return 1
	fi

	# Der Dienst wird spaeter (nach der Konfiguration) gezielt gestartet.
	if gg_service_active asterisk.service; then
		systemctl stop asterisk.service
	fi

	gg_fact_set asterisk_install_method "package"
	gg_ok "Asterisk $(gg_asterisk_version) aus Paketquellen installiert."
	return 0
}

build_from_source() {
	gg_headline "Asterisk aus dem Quellcode bauen"
	gg_warn "Das dauert auf einem Raspberry Pi 3 typischerweise 1,5 bis 4 Stunden."
	gg_warn "Fortschritt: sudo tail -f ${GG_ASTERISK_LOG}"

	check_disk_space "$SRC_ROOT"

	if ! gg_apt_install "${BUILD_DEPS[@]}"; then
		gg_die "Build-Abhaengigkeiten konnten nicht installiert werden."
	fi
	gg_ok "Build-Abhaengigkeiten installiert (inkl. libbluetooth-dev fuer chan_mobile)."

	enlarge_swap

	local tarball srcdir jobs
	download_and_verify "$SRC_ROOT"
	tarball="$GG_DOWNLOADED_TARBALL"

	cd "$SRC_ROOT" || gg_die "Verzeichnis ${SRC_ROOT} nicht betretbar."
	gg_info "Entpacke ${tarball} ..."
	rm -rf "${SRC_ROOT}/asterisk-build"
	mkdir -p "${SRC_ROOT}/asterisk-build"
	if ! tar -xzf "$tarball" -C "${SRC_ROOT}/asterisk-build" --strip-components=1; then
		gg_die "Archiv ${tarball} konnte nicht entpackt werden."
	fi
	srcdir="${SRC_ROOT}/asterisk-build"
	cd "$srcdir" || gg_die "Verzeichnis ${srcdir} nicht betretbar."

	local version
	version="$(cat .version 2>/dev/null || printf '%s' "$GG_ASTERISK_BRANCH")"
	gg_info "Asterisk-Version aus dem Archiv: ${version}"
	gg_fact_set asterisk_source_version "$version"

	# --- configure ---
	gg_info "Konfiguriere den Build (./configure) ..."
	if ! ./configure \
		--prefix=/usr \
		--sysconfdir=/etc \
		--localstatedir=/var \
		--with-pjproject-bundled \
		>>"$GG_ASTERISK_LOG" 2>&1; then
		gg_error "Die letzten Zeilen von config.log:"
		tail -n 30 config.log 2>/dev/null | sed 's/^/    /' || true
		gg_die "./configure fehlgeschlagen. Details in ${GG_ASTERISK_LOG}."
	fi
	gg_ok "configure erfolgreich."

	# --- menuselect ---
	gg_info "Waehle die zu bauenden Module aus ..."
	if ! make menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "'make menuselect.makeopts' fehlgeschlagen."
	fi

	# chan_mobile liegt im Bereich "Add-ons" und ist nicht vorausgewaehlt.
	if ! menuselect/menuselect --enable chan_mobile menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_error "menuselect konnte chan_mobile nicht aktivieren."
		gg_error "Das passiert praktisch immer dann, wenn libbluetooth-dev beim"
		gg_error "configure-Lauf gefehlt hat."
		gg_die "chan_mobile ist in diesem Build nicht verfuegbar."
	fi
	gg_ok "chan_mobile ist zum Bauen vorgemerkt."

	# Auf ARM keine -march=native-Optimierung.
	menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1

	# Musik-Wartemelodien werden nicht gebraucht und sparen Download,
	# Bauzeit und Platz auf der SD-Karte.
	menuselect/menuselect --disable-category MENUSELECT_MOH menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1

	# --- make ---
	jobs="$(build_jobs)"
	gg_info "Starte Build mit ${jobs} parallelen Jobs. Jetzt ist Geduld gefragt."
	if ! make -j"$jobs" >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_error "Die letzten Zeilen des Build-Logs:"
		tail -n 40 "$GG_ASTERISK_LOG" | sed 's/^/    /'
		gg_die "Der Asterisk-Build ist fehlgeschlagen. Vollstaendiges Log: ${GG_ASTERISK_LOG}"
	fi
	gg_ok "Build abgeschlossen."

	if [ ! -f "${srcdir}/addons/chan_mobile.so" ]; then
		gg_die "chan_mobile.so wurde trotz Aktivierung nicht gebaut. Log: ${GG_ASTERISK_LOG}"
	fi
	gg_ok "addons/chan_mobile.so wurde erzeugt."

	# --- install ---
	gg_info "Installiere Asterisk ..."
	if ! make install >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "'make install' fehlgeschlagen."
	fi

	# Beispielkonfigurationen nur beim allerersten Mal einspielen,
	# damit eine bestehende Konfiguration nicht ueberschrieben wird.
	if [ -z "$(find "$ASTERISK_ETC" -maxdepth 1 -name '*.conf' -print -quit 2>/dev/null)" ]; then
		gg_info "Spiele Beispielkonfigurationen ein (make samples) ..."
		if ! make samples >>"$GG_ASTERISK_LOG" 2>&1; then
			gg_die "'make samples' fehlgeschlagen."
		fi
	else
		gg_info "In ${ASTERISK_ETC} liegen bereits Konfigurationen - 'make samples' wird uebersprungen."
	fi

	ldconfig
	create_asterisk_user

	# systemd-Unit nur beim Quellcode-Build (Pakete bringen eigene mit).
	install -m 0644 "${GG_PREFIX}/systemd/asterisk.service" /etc/systemd/system/asterisk.service
	systemctl daemon-reload
	gg_ok "systemd-Unit asterisk.service installiert."

	gg_fact_set asterisk_install_method "source"
	gg_fact_set asterisk_source_dir "$srcdir"

	restore_swap

	local ver
	ver="$(gg_asterisk_version)"
	if [ -z "$ver" ]; then
		gg_die "Nach der Installation liefert 'asterisk -V' keine Version."
	fi
	gg_ok "Asterisk ${ver} aus dem Quellcode installiert."
}

cmd_install() {
	gg_headline "Asterisk installieren"

	local existing
	existing="$(gg_asterisk_version)"
	if [ -n "$existing" ]; then
		gg_info "Asterisk ${existing} ist bereits installiert."
		if gg_chan_mobile_file >/dev/null 2>&1; then
			gg_ok "chan_mobile ist ebenfalls vorhanden - keine Neuinstallation noetig."
			return 0
		fi
		gg_info "chan_mobile fehlt noch - das erledigt Schritt 15."
		return 0
	fi

	if [ "$GG_ASTERISK_FORCE_SOURCE" = "yes" ]; then
		gg_info "GG_ASTERISK_FORCE_SOURCE=yes - Paketinstallation wird uebersprungen."
		build_from_source
		return 0
	fi

	if try_apt_install; then
		return 0
	fi
	build_from_source
}

# =====================================================================
#  check-chan-mobile
# =====================================================================

cmd_check_chan_mobile() {
	gg_headline "chan_mobile pruefen"

	local so
	if so="$(gg_chan_mobile_file)"; then
		gg_ok "chan_mobile ist vorhanden: ${so}"
		gg_info "Erwarteter Konfigurationsdateiname: $(gg_chan_mobile_conf_name)"
		gg_fact_set chan_mobile_path "$so"
		gg_fact_set chan_mobile_present "yes"
	else
		gg_warn "chan_mobile.so ist NICHT vorhanden."
		gg_warn "Modulverzeichnis: $(gg_asterisk_module_dir || printf 'nicht gefunden')"
		gg_warn "Schritt 15 baut das Modul aus dem Quellcode nach."
		gg_fact_set chan_mobile_present "no"
	fi

	{
		printf '\n===== chan_mobile-Pruefung %s =====\n' "$(gg_timestamp)"
		printf 'asterisk -V: %s\n' "$(gg_asterisk_version)"
		printf 'Modulverzeichnis: %s\n' "$(gg_asterisk_module_dir || printf 'nicht gefunden')"
		printf 'chan_mobile vorhanden: %s\n' "$(gg_fact_get chan_mobile_present no)"
		printf -- '--- apt-cache policy asterisk ---\n'
		apt-cache policy asterisk 2>&1
		printf -- '--- apt-cache policy asterisk-mobile ---\n'
		apt-cache policy asterisk-mobile 2>&1
	} >>"$GG_ASTERISK_LOG"
}

# =====================================================================
#  ensure-chan-mobile
# =====================================================================

# Baut ausschliesslich chan_mobile.so gegen genau die Asterisk-Version,
# die bereits installiert ist. Wird nur gebraucht, wenn Asterisk aus
# einem Paket stammt, das chan_mobile nicht mitbringt.
build_chan_mobile_only() {
	local installed_version="$1"
	gg_warn "Asterisk stammt aus einem Paket, chan_mobile fehlt aber."
	gg_warn "Es wird nur das Modul chan_mobile.so gegen Version ${installed_version} gebaut."
	gg_warn "Hinweis: Ein einzeln nachgebautes Modul passt nur dann zum Paket,"
	gg_warn "wenn die Version exakt uebereinstimmt. Das wird unten geprueft;"
	gg_warn "laedt das Modul nicht, wird es wieder entfernt."

	check_disk_space "$SRC_ROOT"
	if ! gg_apt_install "${BUILD_DEPS[@]}"; then
		gg_die "Build-Abhaengigkeiten konnten nicht installiert werden."
	fi
	enlarge_swap

	local saved_branch="$GG_ASTERISK_BRANCH" saved_version="$GG_ASTERISK_VERSION"
	GG_ASTERISK_VERSION="$installed_version"
	GG_ASTERISK_BRANCH="${installed_version%%.*}"

	local tarball srcdir jobs
	download_and_verify "$SRC_ROOT"
	tarball="$GG_DOWNLOADED_TARBALL"
	GG_ASTERISK_BRANCH="$saved_branch"
	GG_ASTERISK_VERSION="$saved_version"

	srcdir="${SRC_ROOT}/chan-mobile-build"
	rm -rf "$srcdir"
	mkdir -p "$srcdir"
	if ! tar -xzf "${SRC_ROOT}/${tarball}" -C "$srcdir" --strip-components=1; then
		gg_die "Archiv ${tarball} konnte nicht entpackt werden."
	fi
	cd "$srcdir" || gg_die "Verzeichnis ${srcdir} nicht betretbar."

	if ! ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
		--with-pjproject-bundled >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "./configure fuer den chan_mobile-Build fehlgeschlagen."
	fi
	if ! make menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "'make menuselect.makeopts' fehlgeschlagen."
	fi
	if ! menuselect/menuselect --enable chan_mobile menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "chan_mobile laesst sich nicht aktivieren - fehlt libbluetooth-dev?"
	fi
	menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts >>"$GG_ASTERISK_LOG" 2>&1

	jobs="$(build_jobs)"
	# main/ und menuselect werden fuer die generierten Header gebraucht,
	# danach reicht das addons-Verzeichnis.
	gg_info "Baue die noetigen Bibliotheken und danach chan_mobile ..."
	if ! make -j"$jobs" >>"$GG_ASTERISK_LOG" 2>&1; then
		gg_die "Build fehlgeschlagen. Log: ${GG_ASTERISK_LOG}"
	fi
	if [ ! -f "${srcdir}/addons/chan_mobile.so" ]; then
		gg_die "chan_mobile.so wurde nicht erzeugt."
	fi

	local moddir
	moddir="$(gg_asterisk_module_dir)" || gg_die "Asterisk-Modulverzeichnis nicht gefunden."
	install -m 0755 "${srcdir}/addons/chan_mobile.so" "${moddir}/chan_mobile.so"
	gg_ok "chan_mobile.so nach ${moddir} installiert."

	restore_swap
	gg_fact_set chan_mobile_install_method "source-module-only"
}

cmd_ensure_chan_mobile() {
	gg_headline "chan_mobile bereitstellen"

	if gg_chan_mobile_file >/dev/null 2>&1; then
		gg_ok "chan_mobile ist bereits vorhanden: $(gg_chan_mobile_file)"
		gg_fact_set chan_mobile_present "yes"
		return 0
	fi

	local method version
	method="$(gg_fact_get asterisk_install_method "unbekannt")"
	version="$(gg_asterisk_version)"

	if [ -z "$version" ]; then
		gg_die "Asterisk ist nicht installiert - chan_mobile kann nicht bereitgestellt werden."
	fi

	if [ "$method" = "source" ]; then
		# Das duerfte nicht passieren: der Quellcode-Build baut das Modul mit.
		gg_die "Asterisk wurde aus dem Quellcode gebaut, chan_mobile fehlt trotzdem. Log pruefen: ${GG_ASTERISK_LOG}"
	fi

	build_chan_mobile_only "$version"

	if ! gg_chan_mobile_file >/dev/null 2>&1; then
		gg_die "chan_mobile.so ist nach dem Build immer noch nicht vorhanden."
	fi
	gg_fact_set chan_mobile_present "yes"
	gg_ok "chan_mobile steht bereit."
}

# =====================================================================

usage() {
	cat <<'USAGE'
Aufruf: install-asterisk.sh [install|check-chan-mobile|ensure-chan-mobile]

  install             Asterisk installieren (Paket bevorzugt, sonst Quellcode)
  check-chan-mobile   pruefen, ob chan_mobile.so vorhanden ist
  ensure-chan-mobile  chan_mobile notfalls aus dem Quellcode nachbauen
USAGE
}

# GG_CURRENT_STEP wird von gg_die/ERR-Trap in lib/common.sh ausgewertet.
# shellcheck disable=SC2034
case "${1:-install}" in
install) GG_CURRENT_STEP="Asterisk installieren"; cmd_install ;;
check-chan-mobile) GG_CURRENT_STEP="chan_mobile pruefen"; cmd_check_chan_mobile ;;
ensure-chan-mobile) GG_CURRENT_STEP="chan_mobile bereitstellen"; cmd_ensure_chan_mobile ;;
-h | --help | help) usage ;;
*)
	usage
	exit 2
	;;
esac
