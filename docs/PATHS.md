# Pfadübersicht

Alle Orte, an denen dieses Projekt Dateien anlegt oder verändert — mit
Begründung. Wer aufräumen, sichern oder Fehler suchen will, findet hier
alles.

---

## Projekt

| Pfad | Rechte | Inhalt |
|---|---|---|
| `/opt/gsm-gateway/` | `root:root 0755` | Das gesamte Projekt. Wird von `install/bootstrap.sh` hierher kopiert. |
| `/opt/gsm-gateway/lib/common.sh` | `0644` | Gemeinsame Shell-Funktionen (Protokollierung, Fehlerbehandlung, Erkennung). Wird eingebunden, nie direkt gestartet. |
| `/opt/gsm-gateway/keys/asterisk-release.asc` | `0644` | Öffentlicher Signaturschlüssel des Asterisk-Projekts. Damit wird das heruntergeladene Archiv geprüft, ohne auf einen Keyserver angewiesen zu sein. |
| `/usr/local/src/gsm-gateway/` | `root:root` | Asterisk-Quellcode und Build-Verzeichnis. Wird nur beim Quellcode-Build angelegt und kann nach erfolgreicher Installation gelöscht werden (spart ~2 GB). |

## Befehle

Alle Einträge in `/usr/local/bin/` sind Verweise nach
`/opt/gsm-gateway/scripts/`. Jeder existiert doppelt — mit und ohne
`.sh`, damit sowohl `gateway-test` als auch
`/usr/local/bin/gateway-test.sh` funktioniert.

| Befehl | Ziel |
|---|---|
| `gateway-check` / `gateway-check.sh` | Hardware- und Systemdiagnose |
| `bluetooth-check` / `bluetooth-check.sh` | Bluetooth- und HFP-Diagnose |
| `gateway-test` / `gateway-test.sh` | Gesamtstatus, auch als JSON |
| `pair-iphone` / `pair-iphone.sh` | iPhone koppeln |
| `gateway-credentials` / `.sh` | SIP-Zugangsdaten anzeigen |
| `gateway-watchdog` / `.sh` | Verbindungsüberwachung (Zustand, Zurücksetzen) |
| `gateway-calls` / `.sh` | Anrufliste |
| `gateway-hci-prepare` / `.sh` | Bluetooth-Adapter für `chan_mobile` vorbereiten |
| `backup-gateway` / `.sh` | Sicherung erstellen |
| `uninstall-gateway` / `.sh` | Gateway entfernen |

## Konfiguration

| Pfad | Rechte | Inhalt |
|---|---|---|
| `/etc/gsm-gateway/gateway.conf` | `0644` | Zentrale Einstellungen. Vorlage: `config/gateway.conf.example`. Wird bei erneutem Bootstrap **nicht** überschrieben. |
| `/etc/gsm-gateway/secrets/` | `0700` | Zugangsdaten. |
| `/etc/gsm-gateway/secrets/sip-1001.conf` | `0600 root:root` | Das erzeugte SIP-Passwort. Anzeigen mit `sudo gateway-credentials`. |
| `/etc/gsm-gateway/wireguard/` | `0700` | Platzhalter für die spätere VPN-Konfiguration; enthält eine Anleitung. |

## Asterisk

| Pfad | Rechte | Inhalt |
|---|---|---|
| `/etc/asterisk/` | `0750 asterisk:asterisk` | Asterisk-Konfiguration |
| `/etc/asterisk/chan_mobile.conf` | `0640` | Bluetooth-Adapter und gekoppeltes Telefon. **Die maßgebliche Datei.** |
| `/etc/asterisk/mobile.conf` | Verweis | Zeigt auf `chan_mobile.conf`, damit auch der ältere Name funktioniert. |
| `/etc/asterisk/pjsip.conf` | `0640` | SIP-Nebenstelle, Transport (nur LAN), Zugriffsliste. Enthält das Passwort. |
| `/etc/asterisk/extensions.conf` | `0640` | Wählplan: eingehend, ausgehend, Sperrliste, Testnummern |
| `/etc/asterisk/rtp.conf` | `0640` | Portbereich der Sprachdaten (10000–10100) |
| `/etc/asterisk/logger.conf` | `0640` | Protokollkanäle, u. a. `security` für fail2ban |
| `/etc/asterisk/cdr.conf` | `0640` | Anrufaufzeichnung. `unanswered=yes` sorgt dafür, dass auch verpasste Anrufe erscheinen. |
| `/var/log/asterisk/cdr-csv/Master.csv` | `0640 asterisk:asterisk` | Die Anrufliste. Enthält Rufnummern und Zeitpunkte; das Verzeichnis ist `0750`. |
| `/etc/asterisk/backup/` | `0700` | Sicherungen vor jeder Änderung, zeitgestempelt |
| `/usr/lib/asterisk/modules/chan_mobile.so` | — | Das Kanalmodul |
| `/usr/sbin/asterisk` | — | Das Programm (bei Quellcode-Build; `--prefix=/usr`) |
| `/var/log/asterisk/` | `asterisk:asterisk` | Asterisk-eigene Protokolle |
| `/var/lib/asterisk/`, `/var/spool/asterisk/` | `asterisk:asterisk` | Laufzeitdaten |

## Bluetooth

| Pfad | Inhalt |
|---|---|
| `/etc/bluetooth/main.conf` | BlueZ-Einstellungen. Geändert werden `Class` (0x200404 = Freisprecheinrichtung), `Name`, `AutoEnable`, `FastConnectable`, `JustWorksRepairing`. |
| `/etc/bluetooth/backup/` | Sicherungen der `main.conf` |
| `/var/lib/bluetooth/<Adapter-MAC>/` | Von BlueZ verwaltet: Kopplungsschlüssel |
| `/etc/modprobe.d/gsm-gateway-bluetooth.conf` | Schaltet USB-Autosuspend für `btusb` ab, damit die Sprachverbindung nicht mitten im Gespräch abreißt |
| `/etc/udev/rules.d/99-gsm-gateway-bluetooth.rules` | Startet beim Einstecken eines Adapters `gsm-gateway-hci@<hciX>.service` |

## systemd-Dienste

| Unit | Zweck |
|---|---|
| `gsm-gateway-firstboot.service` | Erstinstallation. Läuft dank zweier `ConditionPathExists` nur, solange das Setup weder fertig noch endgültig aufgegeben ist. `TimeoutStartSec=infinity`, weil der Build Stunden dauert. |
| `gsm-gateway-hci@.service` | Setzt das HCI-Voice-Setting auf `0x0060` und schaltet den Adapter ein. Wird per udev gestartet. |
| `gsm-gateway-status.service` + `.timer` | Erzeugt jede Minute `/run/gsm-gateway/status.json` |
| `gsm-gateway-watchdog.service` + `.timer` | Prüft jede Minute die Kette Asterisk → chan_mobile → iPhone und stellt sie gestuft wieder her. Läuft dank `ConditionPathExists` erst nach abgeschlossener Erstinstallation. |
| `gsm-gateway-web.service` | Statusseite, läuft als `gsm-web` ohne Systemrechte |
| `asterisk.service` | **Nur bei Quellcode-Installation.** Setzt `CAP_NET_RAW` und `CAP_NET_ADMIN`, damit Asterisk als Benutzer `asterisk` an die Bluetooth-Sockets kommt. |

## Status und Protokolle

| Pfad | Inhalt |
|---|---|
| `/var/lib/gsm-gateway/setup-complete` | Existiert, sobald die Erstinstallation fertig ist. Der First-Boot-Dienst startet dann nicht mehr. |
| `/var/lib/gsm-gateway/setup-abandoned` | Existiert nach zu vielen Fehlversuchen. Verhindert Endlosschleifen. Zum erneuten Versuch löschen. |
| `/var/lib/gsm-gateway/install-attempts` | Zähler der Installationsversuche |
| `/var/lib/gsm-gateway/install-status` | `RUNNING`, `OK` oder `FAILED` mit Zeitstempel |
| `/var/lib/gsm-gateway/steps/*.done` | Je ein Merker pro erledigtem Schritt. Löschen = diesen Schritt wiederholen. |
| `/var/lib/gsm-gateway/watchdog` | Zustand der Überwachung: Fehlerzähler, letzte Maßnahme, Zeitpunkt. Wird von `gateway-test` mit ausgewertet. |
| `/var/log/gsm-gateway/watchdog.log` | Was der Watchdog unternommen hat |
| `/var/lib/gsm-gateway/facts/*` | Ermittelte Werte: Adapter, MAC-Adressen, RFCOMM-Kanal, Installationsart. Damit spätere Scripts nichts raten müssen. |
| `/run/gsm-gateway/status.json` | Aktueller Status für die Webseite (liegt im Arbeitsspeicher) |
| `/var/log/gsm-gateway/install.log` | Kompletter Installationsverlauf |
| `/var/log/gsm-gateway/error.log` | Nur Fehler, mit Schrittangabe |
| `/var/log/gsm-gateway/hardware.log` | Hardware- und Systemdiagnose |
| `/var/log/gsm-gateway/bluetooth.log` | Bluetooth, Pairing, HFP |
| `/var/log/gsm-gateway/asterisk.log` | Asterisk-Installation und Build-Ausgabe |
| `/var/log/gsm-gateway/status.log` | Statusberichte und Abschlussmeldung |
| `/var/backups/gsm-gateway/` | `0700`. Sicherungen von `backup-gateway`. |

## Firewall und Zusatzkonfiguration

| Pfad | Inhalt |
|---|---|
| `/etc/nftables.d/gsm-gateway.nft` | Regeln der Tabelle `inet gsm_gateway` |
| `/etc/nftables.conf` | Wird nur um eine `include`-Zeile ergänzt, falls sie fehlt |
| `/etc/fail2ban/jail.d/gsm-gateway.conf` | Jail gegen SIP-Passwortraten |
| `/etc/logrotate.d/gsm-gateway` | Rotation der Gateway-Protokolle |
| `/etc/logrotate.d/gsm-gateway-cdr` | Rotation der Anrufliste (monatlich, spätestens ab 5 MB) |
| `/etc/logrotate.d/gsm-gateway-asterisk` | Rotation der Asterisk-Protokolle. Wird erst installiert, wenn der Benutzer `asterisk` existiert — sonst lehnt logrotate die Datei ab. Bringt das Asterisk-Paket eine eigene mit, bleibt diese unangetastet. |

## Auf der SD-Karte (nur Betriebsart `bootfs`)

| Pfad | Inhalt |
|---|---|
| `<boot>/gsm-gateway/` | Kopie des Projekts, wird beim ersten Start nach `/opt` übernommen |
| `<boot>/firstrun.sh` | Erstkonfiguration des Imagers, um den Bootstrap-Aufruf ergänzt |
| `<boot>/firstrun.sh.gsm-gateway-backup` | Original vor der Änderung |
| `<boot>/gsm-gateway/bootstrap.log` | Ergebnis des Bootstraps beim ersten Start |

Der Boot-Ordner heißt auf aktuellem Raspberry Pi OS `/boot/firmware`,
auf älteren Versionen `/boot`. Die Scripts prüfen beide.

---

## Was nicht angefasst wird

* `/etc/passwd`, `/etc/shadow` außer den Systembenutzern `asterisk` und
  `gsm-web`
* `/etc/ssh/` — der SSH-Zugang bleibt unverändert
* Netzwerkkonfiguration (`/etc/network/`, NetworkManager, dhcpcd)
* `/boot/firmware/config.txt` — das interne Bluetooth wird **nicht**
  abgeschaltet
* alles unter `/home/`
