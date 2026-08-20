# Raspberry Pi 3 als GSM → SIP Gateway

Diese Anleitung macht aus einem Raspberry Pi 3, einem ASUS USB-BT500 und
einem iPhone 11 Pro mit Schweizer SIM-Karte ein Telefon-Gateway:
Anrufe auf die Schweizer Nummer landen auf einem SIP-Telefon im lokalen
Netz, und umgekehrt.

```
   Schweizer SIM
        │
   iPhone 11 Pro
        │  Bluetooth HFP (Freisprechprofil)
   ASUS USB-BT500
        │  USB
   Raspberry Pi 3
        │  BlueZ → Asterisk → chan_mobile
        │
       SIP
        │  zunächst nur lokales Netz, später WireGuard
   SIP-App (Softphone)
```

Die SD-Karte wird einmal vorbereitet. Danach genügt:
**Karte einlegen → Netzwerkkabel → Strom → warten.**
Der Raspberry Pi installiert und konfiguriert alles selbst.

---

## Inhalt

1. [Bitte zuerst lesen](#1-bitte-zuerst-lesen)
2. [Was Sie brauchen](#2-was-sie-brauchen)
3. [SD-Karte vorbereiten](#3-sd-karte-vorbereiten)
4. [Erster Start](#4-erster-start)
5. [Verbinden und Status prüfen](#5-verbinden-und-status-prüfen)
6. [iPhone koppeln](#6-iphone-koppeln)
7. [Softphone einrichten](#7-softphone-einrichten)
8. [Telefonie-Tests](#8-telefonie-tests)
9. [Befehlsübersicht](#9-befehlsübersicht)
10. [Statusseite im Browser](#10-statusseite-im-browser)
11. [Sicherheit](#11-sicherheit)
12. [Zugriff von unterwegs (WireGuard)](#12-zugriff-von-unterwegs-wireguard)
13. [Wenn etwas nicht funktioniert](#13-wenn-etwas-nicht-funktioniert)
14. [Projektstruktur und Pfade](#14-projektstruktur-und-pfade)
15. [Backup und Deinstallation](#15-backup-und-deinstallation)
16. [Annahmen und bekannte Einschränkungen](#16-annahmen-und-bekannte-einschränkungen)
17. [Zweite Phase](#17-zweite-phase)

---

## 1. Bitte zuerst lesen

Drei Punkte, die man vorher wissen sollte:

**Die Installation dauert lange.**
Asterisk ist in aktuellen Raspberry-Pi-OS-Versionen nicht als fertiges
Paket verfügbar (Debian hat Asterisk nach Debian 11 aus der Distribution
entfernt). Der Raspberry Pi baut Asterisk deshalb selbst aus dem
Quellcode. Auf einem Pi 3 dauert das **1,5 bis 4 Stunden**. Das passiert
vollautomatisch — der Pi muss nur mit Strom und Netzwerk versorgt sein.

**Notrufe funktionieren nicht.**
Dieses Gateway ist keine Telefonanlage für Notfälle. Über SIP abgesetzte
Anrufe an 112, 117, 118 oder 144 gehen zwar technisch über die SIM-Karte
hinaus, übermitteln aber weder den richtigen Standort noch eine
zuverlässige Rückrufnummer. **Im Notfall immer direkt mit dem Mobiltelefon
anrufen.**

**Die Sprachqualität ist Telefonqualität, nicht mehr.**
Der Bluetooth-Freisprechkanal überträgt 8 kHz Schmalband. Das klingt wie
eine gewöhnliche Handy-Freisprecheinrichtung im Auto — verständlich, aber
nicht brillant. Dazu kommt eine spürbare Verzögerung. Details in
[docs/LIMITATIONS.md](docs/LIMITATIONS.md).

Bitte prüfen Sie außerdem die Vertragsbedingungen Ihres Mobilfunkanbieters.
Manche Anbieter untersagen es, einen Mobilfunkanschluss als Gateway für
Dritte zu verwenden.

---

## 2. Was Sie brauchen

**Hardware**

| Teil | Hinweis |
|---|---|
| Raspberry Pi 3 Model B | 1 GB RAM genügt |
| Original-Netzteil | 5 V / 2,5 A. Schwache Netzteile führen zu Abstürzen |
| microSD-Karte | **mindestens 16 GB**, besser 32 GB. Der Asterisk-Build braucht Platz |
| ASUS USB-BT500 | Bluetooth-5.0-Adapter (Realtek RTL8761B) |
| Netzwerkkabel | Ethernet ist deutlich stabiler als WLAN |
| iPhone 11 Pro | mit Schweizer SIM-Karte |

Das interne Bluetooth des Raspberry Pi 3 wird **nicht** empfohlen: Es
teilt sich Antenne und Funkbereich mit dem WLAN, und Sprachverbindungen
brechen damit deutlich häufiger ab.

**Software auf Ihrem Computer**

* [Raspberry Pi Imager](https://www.raspberrypi.com/software/) —
  gibt es für Windows, macOS und Linux
* dieses Projekt (heruntergeladen oder per `git clone`)

---

## 3. SD-Karte vorbereiten

### 3.1 Raspberry Pi Imager installieren

Von <https://www.raspberrypi.com/software/> herunterladen und
installieren. Dann starten.

### 3.2 Betriebssystem auswählen

1. Auf **„Modell wählen"** klicken → **Raspberry Pi 3** auswählen.
2. Auf **„OS wählen"** klicken.
3. **Raspberry Pi OS (other)** anklicken.
4. **Raspberry Pi OS Lite (32-bit)** auswählen.

> **Warum Lite und warum 32-bit?**
> „Lite" heißt: ohne grafische Oberfläche. Genau richtig für ein Gerät,
> das im Schrank steht — es spart Arbeitsspeicher, den der Pi 3 gut
> gebrauchen kann.
> 32-bit ist auf einem Pi 3 mit 1 GB RAM sparsamer.
> Die 64-bit-Variante funktioniert aber ebenso; das Setup erkennt die
> Architektur selbst und richtet sich danach.

### 3.3 SD-Karte auswählen

Auf **„SD-Karte wählen"** klicken und die Karte auswählen.

> ⚠️ Alle Daten auf der Karte werden gelöscht. Bitte doppelt prüfen,
> dass wirklich die SD-Karte ausgewählt ist und nicht eine externe
> Festplatte.

### 3.4 Vorkonfiguration ausfüllen

Auf das **Zahnrad** klicken (oder bei der Frage „Möchtest du
Einstellungen anpassen?" auf **„Einstellungen bearbeiten"**).

Bitte genau so ausfüllen:

| Feld | Wert |
|---|---|
| Hostname | `gsm-gateway` |
| Benutzername | `gateway` |
| Passwort | ein eigenes, sicheres Passwort — **bitte notieren** |
| SSH aktivieren | ✅ ja, „Passwort-Authentifizierung verwenden" |
| WLAN | nur ausfüllen, wenn kein Netzwerkkabel möglich ist |
| Zeitzone | `Europe/Zurich` |
| Tastaturlayout | `ch` |

Der Hostname `gsm-gateway` sorgt dafür, dass der Pi später im Netz als
`gsm-gateway.local` erreichbar ist.

Die Systemsprache `de_CH.UTF-8` lässt sich im Imager nicht einstellen —
das erledigt der Raspberry Pi beim ersten Start selbst.

### 3.5 Schreiben

Auf **„Schreiben"** klicken und warten, bis der Imager fertig meldet.

### 3.6 Das Gateway-Projekt auf die Karte legen

**Die SD-Karte jetzt noch einmal aus dem Rechner nehmen und wieder
einstecken.** Der Computer zeigt sie danach als Laufwerk (Windows und
macOS zeigen nur die kleine Boot-Partition — das genügt).

**Linux oder macOS:**

```bash
cd gsm-gateway
sudo ./sdcard/prepare-sdcard.sh
```

**Windows** (PowerShell im Projektordner öffnen):

```powershell
.\sdcard\prepare-sdcard.ps1
```

Das Script sucht die Karte selbst, kopiert das Projekt darauf und sorgt
dafür, dass die Installation beim ersten Start automatisch losläuft.
Findet es die Karte nicht, kann man den Pfad angeben:

```bash
sudo ./sdcard/prepare-sdcard.sh --bootfs /media/ich/bootfs
```

```powershell
.\sdcard\prepare-sdcard.ps1 -BootDrive E:
```

Danach die Karte im Betriebssystem **sicher auswerfen**.

---

## 4. Erster Start

1. SD-Karte in den Raspberry Pi stecken.
2. **ASUS USB-BT500 in einen USB-Anschluss stecken.**
3. Netzwerkkabel einstecken.
4. Netzteil anschließen.

Ab hier läuft alles von selbst. Der Pi

* startet einmal neu (Erstkonfiguration des Imagers),
* aktualisiert das System,
* installiert Bluetooth und richtet den USB-BT500 ein,
* baut und installiert Asterisk mit `chan_mobile`,
* richtet SIP ein — nur für das lokale Netz,
* richtet Firewall, Protokollierung und Statusseite ein,
* schaltet sich anschließend selbst ab (die Erstinstallation läuft
  danach nie wieder).

**Wie lange dauert das?**

| Schritt | Dauer |
|---|---|
| Systemaktualisierung | 5–20 Minuten |
| Bluetooth einrichten | 1–2 Minuten |
| Asterisk bauen | 1,5–4 Stunden |
| Rest | wenige Minuten |

Die grüne LED des Pi flackert währenddessen — das ist ein gutes Zeichen.
Man kann in Ruhe etwas anderes tun.

**Wenn beim ersten Start etwas schiefgeht:** Der Pi merkt sich, welche
Schritte schon geklappt haben, und macht beim nächsten Neustart genau
dort weiter. Nach fünf erfolglosen Anläufen hört er auf, es weiter zu
versuchen, damit er nicht endlos in einer Schleife läuft. Was schiefging,
steht dann in `/var/log/gsm-gateway/error.log`.

---

## 5. Verbinden und Status prüfen

### 5.1 IP-Adresse finden

Meist genügt der Name:

```bash
ping gsm-gateway.local
```

Falls das nicht klappt, hilft die Geräteliste im Router (oft unter
„Netzwerk", „Heimnetz" oder „Angeschlossene Geräte"). Gesucht ist der
Eintrag `gsm-gateway`.

### 5.2 Per SSH verbinden

```bash
ssh gateway@gsm-gateway.local
```

Unter Windows geht das genauso in der PowerShell oder mit
[PuTTY](https://www.putty.org/).

Beim ersten Mal fragt SSH nach der Echtheit des Rechners — mit `yes`
bestätigen. Danach das Passwort eingeben, das Sie im Imager vergeben
haben.

### 5.3 Läuft die Installation noch?

```bash
sudo tail -f /var/log/gsm-gateway/install.log
```

Beenden mit `Strg + C`. Solange dort noch Zeilen dazukommen, arbeitet der
Pi. Wenn Sie ganz am Ende so etwas sehen …

```
=============================================
 GSM → SIP GATEWAY SETUP COMPLETE
=============================================
```

… ist die Grundinstallation fertig.

### 5.4 Gesamtstatus anzeigen

```bash
sudo gateway-test
```

Ausgabe (Beispiel nach der Grundinstallation, noch ohne iPhone):

```
=======================================
 GSM -> SIP GATEWAY
=======================================

System:              OK
Internet:            OK
USB BT500:           OK
Bluetooth:           OK
iPhone:              TEST AUSSTEHEND
HFP:                 TEST AUSSTEHEND
Audio:               OK
Asterisk:            OK
chan_mobile:         OK
SIP:                 OK

GSM Incoming:        TEST AUSSTEHEND
GSM Outgoing:        TEST AUSSTEHEND
Audio Quality:       TEST AUSSTEHEND
SMS:                 TEST AUSSTEHEND

=======================================
```

Darunter steht jede Prüfung noch einmal einzeln mit Begründung.

---

## 6. iPhone koppeln

Das ist der einzige Schritt, der von Hand gemacht werden muss — mit
Absicht: Ein Gateway soll sich nicht selbstständig mit irgendeinem
Telefon in Reichweite verbinden.

**Am iPhone:**

1. **Einstellungen → Bluetooth**
2. Bluetooth einschalten
3. **Diesen Bildschirm geöffnet lassen.**
   Ein iPhone ist nur sichtbar, solange die Bluetooth-Seite offen ist.

**Am Raspberry Pi:**

```bash
sudo pair-iphone
```

Das Script

1. sucht 20 Sekunden nach Geräten,
2. zeigt die gefundenen Geräte nummeriert an,
3. lässt Sie das iPhone auswählen und **die Auswahl bestätigen**,
4. startet die Kopplung — dabei ggf. `yes` eingeben und am iPhone
   „Koppeln" antippen,
5. setzt „Trust", versucht eine Verbindung,
6. **prüft, ob das iPhone HFP anbietet**,
7. liest den RFCOMM-Kanal aus und trägt die **echte** MAC-Adresse in die
   Asterisk-Konfiguration ein.

Klappt es andersherum besser, kann man die Kopplung auch am iPhone
starten:

```bash
sudo pair-iphone --from-iphone
```

Dann erscheint der Pi am iPhone als **gsm-gateway** in der Geräteliste.

### Wenn HFP nicht erkannt wird

Dann bricht das Script ab und sagt genau das:

> Das iPhone ist per Bluetooth verbunden, aber der benötigte
> HFP-Telefoniedienst wurde nicht erkannt.

Es wird **keine** Asterisk-Konfiguration geschrieben, die Telefonie nur
vortäuschen würde. Was in dem Fall zu tun ist, steht direkt in der
Fehlermeldung und in [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

Nach erfolgreicher Kopplung noch einmal:

```bash
sudo gateway-test
```

---

## 7. Softphone einrichten

Zugangsdaten anzeigen:

```bash
sudo gateway-credentials
```

Das Passwort wurde bei der Installation zufällig erzeugt (24 Zeichen mit
Groß-, Kleinbuchstaben, Ziffern und Sonderzeichen) und liegt nur auf dem
Pi in `/etc/gsm-gateway/secrets/`.

Diese Werte in ein SIP-Programm eintragen — zum Beispiel
**Linphone** (kostenlos, alle Systeme), **Zoiper**, **Groundwire** (iOS)
oder **MicroSIP** (Windows):

| Feld | Wert |
|---|---|
| Benutzername | `1001` |
| Passwort | wie angezeigt |
| Domain / Server | IP-Adresse des Pi, z. B. `192.168.1.42` |
| Transport | UDP |

> **Tipp:** Im Router eine feste IP-Adresse für den Pi vergeben
> (DHCP-Reservierung). Ändert sich die Adresse, muss die SIP-Konfiguration
> neu geschrieben werden — `sudo gateway-test` weist darauf hin, und
> `sudo /opt/gsm-gateway/install/setup-sip.sh` erledigt es.

Erster Test ganz ohne Mobilfunk: die **600** anrufen. Das ist ein
Echo-Test — was Sie sagen, kommt zurück. Funktioniert das, stimmen SIP
und Audioweg zwischen Softphone und Asterisk.

---

## 8. Telefonie-Tests

Diese drei Tests kann nur ein Mensch durchführen.

### Test A — eingehender Anruf

Von einem anderen Telefon die **Schweizer Nummer der SIM-Karte** anrufen.

Erwartet:

```
Anrufer → Schweizer Mobilfunknetz → iPhone → Bluetooth →
Raspberry Pi → Asterisk → Softphone 1001 klingelt
```

### Test B — ausgehender Anruf

Vom Softphone (1001) eine Rufnummer wählen, z. B. `0791234567`.

Erwartet:

```
Softphone → Asterisk → Bluetooth → iPhone →
Schweizer Mobilfunknetz → Ziel klingelt
```

### Test C — Sprachqualität

Bitte bewusst darauf achten und ehrlich bewerten:

* Echo?
* Verzögerung (wie lange dauert es, bis die Gegenseite reagiert)?
* Lautstärke in beide Richtungen?
* Bricht das Gespräch nach einiger Zeit ab?
* Bleibt die Bluetooth-Verbindung stabil, wenn das iPhone im Raum liegt?

Erwartungshaltung: Es klingt wie eine Freisprecheinrichtung, und es gibt
eine merkliche Verzögerung. Erfahrungsgemäß liegt sie bei einigen hundert
Millisekunden. Das ist bauartbedingt und lässt sich nicht wegkonfigurieren.

### SMS

SMS funktionieren mit einem iPhone **nicht**. Das Freisprechprofil sieht
zwar SMS-Befehle vor, iOS bietet sie aber nicht an. Siehe
[docs/LIMITATIONS.md](docs/LIMITATIONS.md).

---

## 9. Befehlsübersicht

Alle Befehle brauchen `sudo`.

| Befehl | Zweck |
|---|---|
| `sudo gateway-test` | Gesamtstatus mit Checkliste |
| `sudo gateway-check` | Hardware- und Systemdiagnose |
| `sudo bluetooth-check` | Bluetooth- und HFP-Diagnose |
| `sudo pair-iphone` | iPhone koppeln |
| `sudo gateway-credentials` | SIP-Zugangsdaten anzeigen |
| `sudo backup-gateway` | Konfiguration sichern |
| `sudo uninstall-gateway` | Gateway entfernen |
| `sudo gateway-hci-prepare --show hci1` | Bluetooth-Adapter prüfen |

Jeder Befehl existiert auch mit `.sh` am Ende
(`/usr/local/bin/gateway-test.sh`).

Nützliche Asterisk-Befehle:

```bash
sudo asterisk -rvvv                       # Asterisk-Konsole (beenden: exit)
sudo asterisk -rx "mobile show devices"   # Zustand des iPhones
sudo asterisk -rx "pjsip show endpoints"  # Zustand des Softphones
sudo asterisk -rx "core show channels"    # laufende Gespräche
```

---

## 10. Statusseite im Browser

Im gleichen Netz:

```
http://gsm-gateway.local
```

Die Seite zeigt dieselben Prüfungen wie `gateway-test`, aktualisiert sich
alle 30 Sekunden und lässt sich auch am Handy ansehen.

Sie ist bewusst eine reine Anzeige: Man kann darüber nichts einstellen,
sie läuft ohne Systemrechte, und Anfragen von öffentlichen IP-Adressen
lehnt sie ab. Zusätzlich lässt die Firewall nur das lokale Netz durch.

Nicht gewünscht? In `/etc/gsm-gateway/gateway.conf` `GG_WEB_ENABLE="no"`
setzen und `sudo /opt/gsm-gateway/install/setup-web.sh` ausführen.

---

## 11. Sicherheit

Ein Telefon-Gateway ist ein lohnendes Ziel: Wer es übernimmt,
telefoniert auf Ihre Rechnung. Deshalb ist das Setup von vornherein
zurückhaltend eingestellt.

**Was standardmäßig gilt**

* **SIP lauscht nur auf der LAN-Adresse**, nicht auf `0.0.0.0`.
  `gateway-test` prüft das nach jeder Installation aktiv nach.
* **Zugriffsliste in Asterisk:** nur die in `GG_LAN_NETWORKS`
  eingetragenen privaten Netze dürfen überhaupt Anfragen stellen.
* **Kein anonymer SIP-Zugang.** Wer sich nicht anmeldet, erreicht den
  Wählplan nicht und kann keine Anrufe auslösen.
* **Firewall (nftables):** SIP, RTP und die Statusseite werden außerhalb
  des LAN verworfen. Bewusst wird *keine* Firewall mit
  „alles blockieren" eingerichtet — man soll sich per SSH nicht selbst
  aussperren können.
* **fail2ban** sperrt IP-Adressen nach fünf fehlgeschlagenen
  SIP-Anmeldungen für eine Stunde.
* **Zufälliges Passwort**, nur auf dem Pi, nur für `root` lesbar, nicht
  im Quellcode und nicht im Systemprotokoll.
* **Gesperrte Rufnummern:** Mehrwertdienste (0900, 0901, 0906) und
  Satellitennetze (0087x, 0088x) sind im Wählplan blockiert — auch in
  internationaler Schreibweise.
* **Nur ein Gespräch gleichzeitig** — mehr kann die GSM-Leitung ohnehin
  nicht, und es begrenzt den Schaden bei Missbrauch.
* **Asterisk läuft nicht als `root`**, sondern als eigener Benutzer mit
  genau den Rechten, die Bluetooth braucht.

**Was Sie bitte nicht tun**

* Keine Portweiterleitung auf Port 5060 im Router einrichten.
  SIP-Ports im Internet werden rund um die Uhr automatisiert abgeklopft.
  Für den Zugriff von unterwegs ist WireGuard vorgesehen.
* Das SIP-Passwort nicht durch etwas Kurzes ersetzen.

---

## 12. Zugriff von unterwegs (WireGuard)

Vorbereitet, aber **absichtlich noch nicht aktiviert**. Erst muss die
Telefonie im lokalen Netz zuverlässig laufen — sonst sucht man später
zwei Fehler gleichzeitig.

Der Plan:

```
Freund in der Türkei → WireGuard → Raspberry Pi → Asterisk →
iPhone → Schweizer Mobilfunknetz
```

Die vollständige Schritt-für-Schritt-Anleitung liegt auf dem Pi unter
`/etc/gsm-gateway/wireguard/README.txt`.

---

## 13. Wenn etwas nicht funktioniert

Erste Anlaufstelle:

```bash
sudo gateway-test        # was genau fehlt
sudo bluetooth-check     # Bluetooth im Detail
sudo gateway-check       # Hardware und System
```

Protokolle liegen alle in `/var/log/gsm-gateway/`:

| Datei | Inhalt |
|---|---|
| `install.log` | kompletter Installationsverlauf |
| `error.log` | nur die Fehler |
| `hardware.log` | Hardware- und Systemdiagnose |
| `bluetooth.log` | Bluetooth, Pairing, HFP |
| `asterisk.log` | Asterisk-Installation und -Build |
| `status.log` | Statusberichte |

Ausführliche Hilfe zu den häufigsten Problemen:
**[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**

Installation hängt oder ist abgebrochen? Sie lässt sich jederzeit
fortsetzen:

```bash
sudo systemctl start gsm-gateway-firstboot.service
sudo journalctl -u gsm-gateway-firstboot.service -f
```

Einen einzelnen Schritt wiederholen (Beispiel Bluetooth):

```bash
sudo rm /var/lib/gsm-gateway/steps/08-bluetooth-install.done
sudo /opt/gsm-gateway/install/firstboot-install.sh
```

---

## 14. Projektstruktur und Pfade

```
gsm-gateway/
├── README.md
├── install/
│   ├── bootstrap.sh              Projekt auf dem Pi einrichten
│   ├── firstboot-install.sh      Ablaufsteuerung der 20 Schritte
│   ├── install-bluetooth.sh      Bluetooth, BlueZ, Adaptererkennung
│   ├── install-asterisk.sh       Asterisk (Paket oder Quellcode)
│   ├── setup-audio.sh            Sprachkanal (SCO) vorbereiten
│   ├── setup-chan-mobile.sh      chan_mobile konfigurieren
│   ├── setup-sip.sh              SIP, Wählplan, Passwort
│   ├── setup-firewall.sh         nftables und fail2ban
│   └── setup-web.sh              Statusseite
├── scripts/
│   ├── gateway-check.sh          Hardware- und Systemdiagnose
│   ├── bluetooth-check.sh        Bluetooth-Diagnose
│   ├── pair-iphone.sh            iPhone koppeln
│   ├── gateway-test.sh           Gesamtstatus / JSON
│   ├── gateway-credentials.sh    SIP-Zugangsdaten anzeigen
│   ├── gateway-hci-prepare.sh    Adapter für chan_mobile vorbereiten
│   ├── backup-gateway.sh         Sicherung
│   └── uninstall-gateway.sh      Deinstallation
├── lib/                          gemeinsame Bausteine
│   ├── common.sh                 Protokollierung, Fehlerbehandlung
│   ├── hci-voice.py              HCI Voice Setting lesen/setzen
│   ├── sdp-rfcomm.py             RFCOMM-Kanal per SDP ermitteln
│   ├── sco-check.py              SCO-Unterstützung prüfen
│   ├── ini-set.py                BlueZ-Konfiguration bearbeiten
│   └── render-template.py        Vorlagen ausfüllen
├── systemd/
│   ├── gsm-gateway-firstboot.service
│   ├── gsm-gateway-hci@.service
│   ├── gsm-gateway-status.service / .timer
│   ├── gsm-gateway-web.service
│   ├── asterisk.service          nur bei Quellcode-Installation
│   └── udev/99-gsm-gateway-bluetooth.rules
├── asterisk/                     Konfigurationsvorlagen
│   ├── chan_mobile.conf.template
│   ├── mobile-device.conf.template
│   ├── pjsip.conf.template
│   ├── extensions.conf.template
│   ├── rtp.conf.template
│   └── logger.conf.template
├── etc/                          Vorlagen für /etc
│   ├── nftables/gsm-gateway.nft.template
│   ├── fail2ban/jail.d/gsm-gateway.conf.template
│   └── logrotate.d/gsm-gateway*
├── web/status/                   lokale Statusseite
├── config/gateway.conf.example   zentrale Einstellungen
├── sdcard/                       SD-Karte vorbereiten (PC-Seite)
└── docs/                         Details, Grenzen, Fehlersuche
```

Auf dem Raspberry Pi:

| Pfad | Inhalt |
|---|---|
| `/opt/gsm-gateway/` | dieses Projekt |
| `/etc/gsm-gateway/gateway.conf` | zentrale Einstellungen |
| `/etc/gsm-gateway/secrets/` | SIP-Passwort (nur `root`, 0600) |
| `/etc/asterisk/` | Asterisk-Konfiguration |
| `/etc/asterisk/backup/` | Sicherungen vor jeder Änderung |
| `/var/log/gsm-gateway/` | Protokolle |
| `/var/lib/gsm-gateway/` | Installationsstatus und ermittelte Werte |
| `/var/backups/gsm-gateway/` | Sicherungen |
| `/usr/local/bin/` | die Befehle aus der Übersicht |

Eine vollständige Liste mit Erklärung zu jedem Pfad:
[docs/PATHS.md](docs/PATHS.md)

**Warum heißt die Datei `chan_mobile.conf` und nicht `mobile.conf`?**
Aktuelle Asterisk-Versionen lesen zuerst `chan_mobile.conf` und nur
ersatzweise die ältere `mobile.conf`. Das Setup schreibt deshalb
`chan_mobile.conf` und legt `mobile.conf` als Verweis darauf an — beide
Namen funktionieren.

---

## 15. Backup und Deinstallation

**Sichern** (vor jeder größeren Änderung sinnvoll):

```bash
sudo backup-gateway
```

Landet in `/var/backups/gsm-gateway/JJJJ-MM-TT-HH-MM-SS/`. Enthalten sind
Asterisk, BlueZ, die eigenen Dienste, Scripts, Konfiguration und
Zugangsdaten. Das Verzeichnis ist nur für `root` lesbar — es enthält das
SIP-Passwort.

**Entfernen:**

```bash
sudo uninstall-gateway
```

Entfernt Asterisk, die Gateway-Konfiguration, die eigenen Dienste und
Scripts. **Raspberry Pi OS bleibt unangetastet**, ebenso Benutzerkonten,
SSH und Netzwerk. Vorher wird automatisch ein Backup erstellt.

---

## 16. Annahmen und bekannte Einschränkungen

Die vollständige, ehrliche Liste steht in
**[docs/LIMITATIONS.md](docs/LIMITATIONS.md)**. Die wichtigsten Punkte:

* **`chan_mobile` ist ein Zusatzmodul mit erweitertem Support.** Es wird
  gepflegt, steht aber nicht im Zentrum der Asterisk-Entwicklung. Nicht
  jede Kombination aus Bluetooth-Adapter, Kernel und iOS-Version
  funktioniert.
* **Nur ein Gespräch gleichzeitig**, und ein Bluetooth-Adapter kann genau
  ein Telefon bedienen.
* **Kein SMS-Versand und -Empfang mit iPhone.**
* **Schmalband-Audio (8 kHz, CVSD)**, spürbare Verzögerung.
* **iOS trennt die HFP-Verbindung im Leerlauf.** `chan_mobile` baut sie
  alle 30 Sekunden wieder auf; unmittelbar danach kann ein Anruf ins Leere
  gehen.
* **Keine Notrufe.**
* **Asterisk wird aus dem Quellcode gebaut**, weil es in aktuellen
  Debian-/Raspberry-Pi-OS-Versionen kein Paket dafür gibt. Für die
  Aktualisierung von Asterisk sind Sie dann selbst zuständig
  (Sicherheitsmeldungen: <https://www.asterisk.org/downloads/security-advisories/>).

---

## 17. Zweite Phase

Eine zweite SIM-Karte und ein zweites Gateway sind **bewusst nicht** Teil
dieses Setups. Erst muss die Kette

```
SIM 1 → iPhone → Bluetooth → Asterisk → SIP
```

zuverlässig laufen — über mehrere Tage, mit echten Gesprächen.

Danach spricht nichts dagegen, den vorhandenen ODROID-XU4 als zweites
Gateway aufzusetzen. Wichtig dabei: **ein Bluetooth-Adapter je Telefon.**
Zwei Telefone an einem Adapter funktionieren mit `chan_mobile` nicht.
