# Annahmen und bekannte Einschränkungen

Dieses Dokument sagt offen, was dieses Setup kann, was nicht, und worauf
es sich verlässt. Es ist bewusst nüchtern gehalten — ein Gateway, von dem
man Falsches erwartet, ist ärgerlicher als eines, dessen Grenzen man kennt.

---

## 1. Getroffene Annahmen

Diese Punkte werden vorausgesetzt. Stimmen sie nicht, funktioniert das
Setup möglicherweise trotzdem, aber es ist nicht dafür entworfen.

### Hardware

| Annahme | Begründung / Auswirkung |
|---|---|
| Raspberry Pi 3 Model B, mindestens 1 GB RAM | Der Asterisk-Build braucht zusätzlichen Swap. Bei weniger als 700 MB RAM bricht die Installation kontrolliert ab. |
| microSD-Karte mit mindestens 16 GB | Der Quellcode-Build braucht rund 2 GB. Geprüft werden 3,5 GB freier Platz; sonst Abbruch mit Meldung. |
| USB-Bluetooth-Adapter vorhanden | Vorzugsweise ASUS USB-BT500 (`0b05:190e`, Realtek RTL8761B). Ein anderer USB-Adapter wird akzeptiert, aber als Abweichung protokolliert. |
| Ethernet-Verbindung | WLAN funktioniert, ist aber beim Pi 3 mit gleichzeitigem Bluetooth-Betrieb deutlich instabiler (gemeinsamer 2,4-GHz-Funkbereich). |
| Original-Netzteil | Unterspannung führt zu Abstürzen mitten im mehrstündigen Build. `gateway-check` liest `vcgencmd get_throttled` aus und warnt. |

### Software

| Annahme | Begründung / Auswirkung |
|---|---|
| Raspberry Pi OS Lite, Debian-basiert | Bekannt und unterstützt sind die Codenamen `bookworm`, `trixie` und `forky`. Andere werden mit Warnung akzeptiert. |
| Kein Desktop, kein Audiosystem installiert | PulseAudio, PipeWire und BlueALSA würden `chan_mobile` das HFP-Profil streitig machen. Laufen sie doch, werden sie gestoppt und maskiert (rückgängig zu machen mit `systemctl unmask`). |
| SD-Karte wurde mit dem Raspberry Pi Imager beschrieben | `prepare-sdcard.sh` hängt sich in die `firstrun.sh` des Imagers ein bzw. legt die Dateien direkt im Wurzeldateisystem ab. |
| Das lokale Netz ist vertrauenswürdig | SIP ist im LAN erreichbar, aber passwortgeschützt und mit Zugriffsliste. Im offenen Gäste-WLAN wäre das zu großzügig. |
| Systemuhr wird per NTP gestellt | Ohne halbwegs richtige Zeit scheitern TLS-Prüfungen beim Download. Es wird bis zu 180 Sekunden gewartet und sonst gewarnt. |

### Netzwerk

| Annahme | Auswirkung |
|---|---|
| DHCP im lokalen Netz | Die IP-Adresse wird beim Setup fest in `pjsip.conf` eingetragen. Ändert sie sich, meldet `gateway-test` das und `setup-sip.sh` korrigiert es. **Empfehlung: DHCP-Reservierung im Router.** |
| Ausgehender Internetzugriff auf HTTPS | Für Paketquellen und den Asterisk-Download. Ein Proxy-Zwang wird nicht unterstützt. |
| IPv4 | Die Firewallregeln und die SIP-Bindung arbeiten mit IPv4. IPv6-Pakete auf den SIP-Ports werden verworfen. |

---

## 2. `chan_mobile`

`chan_mobile` ist der Asterisk-Kanaltreiber, der ein Mobiltelefon über
das Bluetooth-Freisprechprofil (HFP) als Telefonleitung nutzbar macht.

### Einordnung

Das Modul liegt im Asterisk-Quellbaum unter `addons/` und gilt als
Komponente mit **erweitertem Support**: Es wird gepflegt und hat zuletzt
sogar Verbesserungen erhalten, steht aber nicht im Zentrum der
Asterisk-Entwicklung. Es gibt deutlich weniger Nutzer als bei SIP, und
entsprechend weniger getestete Kombinationen.

**Das heißt konkret:** Es gibt keine Garantie, dass eine beliebige
Kombination aus Bluetooth-Adapter, Kernel-Version und iOS-Version
funktioniert. Wenn dieses Setup meldet, dass etwas nicht geht, dann geht
es auch wirklich nicht — es wird nichts beschönigt.

### Harte technische Grenzen

| Grenze | Erklärung |
|---|---|
| **Ein Telefon je Bluetooth-Adapter** | `chan_mobile` belegt einen Adapter exklusiv für ein Gerät. Für eine zweite SIM braucht es einen zweiten USB-Adapter. |
| **Ein Gespräch gleichzeitig** | HFP kennt nur einen Sprachkanal. Ein zweiter Anruf bekommt „besetzt". |
| **`port=` ist Pflicht** | Der RFCOMM-Kanal des Freisprechdienstes muss in der Konfiguration stehen. Er wird per SDP vom Telefon ausgelesen — niemals geraten. Ändert das iPhone ihn nach einem iOS-Update, muss `sudo pair-iphone` erneut laufen. |
| **Voice Setting muss `0x0060` sein** | `chan_mobile` lehnt jeden Bluetooth-Adapter mit abweichendem HCI-Voice-Setting komplett ab. Das Setup setzt und prüft den Wert bei jedem Boot und beim Einstecken des Adapters. |
| **Kein Anklopfen, keine Konferenz, keine Weiterleitung** | HFP kann das teilweise, `chan_mobile` setzt es nicht um. |
| **Kein Wideband-Audio (mSBC)** | `chan_mobile` beherrscht nur CVSD-Schmalband. Moderne Telefone könnten mehr, hier wird die schmalbandige Variante ausgehandelt. |
| **DTMF nur in eine Richtung zuverlässig** | Töne vom Softphone in Richtung Mobilfunknetz funktionieren in der Regel. Töne, die von der Gegenseite kommen, gibt HFP nicht als Signal weiter — nur als Audio. Sprachmenüs („Drücken Sie die 1") sind daher aus Richtung Softphone bedienbar, umgekehrt aber nicht auswertbar. |

---

## 3. iPhone und HFP

Das iPhone ist ein besonders eigensinniger HFP-Partner.

| Verhalten | Auswirkung |
|---|---|
| **Kein SMS über HFP** | HFP sieht AT-Befehle für SMS vor (`AT+CMGS`, `AT+CMGL`). iOS bietet sie nicht an. **SMS-Versand und -Empfang sind mit einem iPhone nicht möglich.** Die Zeile „SMS" in `gateway-test` bleibt deshalb dauerhaft offen. Mit einem Android-Telefon kann es funktionieren — versprochen wird es nicht. |
| **HFP wird nur Freisprech-Geräten angeboten** | Deshalb setzt das Setup in `/etc/bluetooth/main.conf` die Geräteklasse `0x200404` (Audio/Video → Freisprecheinrichtung). Ohne diesen Wert erscheint der Pi als „sonstiges Gerät" und iOS bietet HFP oft gar nicht erst an. |
| **iPhone ist nur sichtbar, solange der Bluetooth-Bildschirm offen ist** | Deshalb fragt `pair-iphone` ausdrücklich danach. |
| **iOS trennt HFP im Leerlauf** | `chan_mobile` verbindet alle 30 Sekunden neu (`interval=30`). Ein Anruf unmittelbar nach dem Trennen kann ins Leere gehen. |
| **iOS-Updates können die Kopplung entwerten** | Nach größeren iOS-Updates kann es nötig sein, am iPhone „Dieses Gerät ignorieren" zu wählen und neu zu koppeln. |
| **Anrufe am iPhone selbst haben Vorrang** | Wird am iPhone abgenommen, verliert das Gateway den Anruf. |
| **Kein Nebeneinander mit dem Auto** | Verbindet sich das iPhone mit einer Freisprechanlage im Auto, ist die HFP-Verbindung zum Pi weg. Das iPhone hält nur eine HFP-Verbindung gleichzeitig. |
| **Anruferkennung hängt vom Netz ab** | Unterdrückte Nummern kommen ohne Nummer an. |

### `bluetoothctl connect` schlägt fehl — und das ist normal

Beim Pairing meldet BlueZ häufig, dass keine Profilverbindung aufgebaut
werden konnte. Grund: Auf dem Gateway läuft absichtlich **kein**
Bluetooth-Audiodienst, der ein Profil annehmen würde. `chan_mobile` baut
die Verbindung später selbst auf — über einen eigenen RFCOMM- und
SCO-Socket, an BlueZ vorbei. Maßgeblich ist deshalb nicht
`bluetoothctl info`, sondern:

```bash
sudo asterisk -rx "mobile show devices"
```

---

## 4. Audio

### Warum kein PulseAudio, PipeWire oder BlueALSA?

Weil `chan_mobile` sie nicht benutzt. Der Kanaltreiber öffnet den
Bluetooth-SCO-Socket selbst und übergibt die Sprachdaten direkt an
Asterisk:

```
iPhone-Mikrofon  → HFP/SCO → chan_mobile → Asterisk → SIP
SIP → Asterisk → chan_mobile → HFP/SCO → iPhone-Lautsprecher
```

Ein zusätzliches Audiosystem wäre nicht nur überflüssig, sondern
schädlich: PulseAudio, PipeWire und BlueALSA registrieren über die
BlueZ-Profile-API selbst HFP/HSP. Dann streiten sich zwei Programme um
denselben Dienst des iPhones — und typischerweise gewinnt keines davon.

Die einfachste und stabilste Lösung ist deshalb: **gar kein Audiosystem.**
`setup-audio.sh` prüft nur, ob der SCO-Pfad des Kernels benutzbar ist,
und schaltet konkurrierende Dienste ab.

### Was das für die Qualität bedeutet

| Punkt | Erwartung |
|---|---|
| Bandbreite | 8 kHz Schmalband (CVSD). Klingt wie eine Freisprecheinrichtung. |
| Verzögerung | Spürbar. Bluetooth-Puffer, Umkodierung und Netzwerk summieren sich; typisch sind einige hundert Millisekunden. |
| Echo | Möglich. Das iPhone macht Echounterdrückung für sein eigenes Mikrofon, nicht für die SIP-Strecke. Ein Headset am Softphone hilft mehr als jede Einstellung. |
| Aussetzer | Möglich, wenn das iPhone weit weg liegt oder WLAN und Bluetooth sich in die Quere kommen. |

**Es wird ausdrücklich nicht behauptet, dass die Audioqualität perfekt
ist.** Sie ist brauchbar für Gespräche, nicht für Musik oder
Konferenzschaltungen.

---

## 5. Paketlage: warum Asterisk aus dem Quellcode

Debian hat Asterisk nach Debian 11 (bullseye) aus der Distribution
entfernt. Weder Debian 12 (bookworm) noch Debian 13 (trixie) enthalten
ein Paket `asterisk` — und damit auch kein `asterisk-mobile` mit
`chan_mobile`. Erst Debian 14 (forky) hat Asterisk 22 wieder aufgenommen.

Da Raspberry Pi OS auf Debian aufbaut, gilt dasselbe dort.

Das Setup prüft trotzdem zuerst `apt-cache policy asterisk`. Gibt es ein
Paket — etwa auf einem älteren Raspberry Pi OS oder in einer künftigen
Version — wird es bevorzugt. Sonst wird gebaut:

* Asterisk **22 LTS**, Standarddownload `asterisk-22-current.tar.gz`
* Prüfung der **SHA-256-Summe** (gegen unvollständige Downloads)
* Prüfung der **GPG-Signatur** gegen den Fingerabdruck
  `F2FC93DB7587BD1FB49E045A5D984BE337191CE7`. Der öffentliche Schlüssel
  liegt dem Projekt bei (`keys/asterisk-release.asc`) und wird bevorzugt
  verwendet — die Echtheitsprüfung hängt damit weder von einem Keyserver
  noch vom Download-Server ab. Passt der mitgelieferte Schlüssel nicht
  zum konfigurierten Fingerabdruck, bricht die Installation ab.
  Eine **ungültige** Signatur führt immer zum Abbruch.
  Nur wenn weder der mitgelieferte Schlüssel noch ein Keyserver
  verfügbar sind, wird auf die reine Prüfsumme zurückgefallen — und das
  wird deutlich protokolliert.
* Es werden nur die benötigten Module gebaut; Wartemelodien werden
  abgewählt.

**Folgen des Quellcode-Builds:**

* Die Installation dauert 1,5–4 Stunden.
* `apt upgrade` aktualisiert Asterisk **nicht**. Sicherheitsmeldungen
  müssen selbst verfolgt werden:
  <https://www.asterisk.org/downloads/security-advisories/>
  Eine neue Version installiert man mit:
  ```bash
  sudo GG_ASTERISK_VERSION=22.11.0 /opt/gsm-gateway/install/install-asterisk.sh install
  ```
* Der Sonderfall „Asterisk kommt aus einem Paket, `chan_mobile` fehlt
  aber" wird abgedeckt, indem nur dieses eine Modul gegen die exakt
  gleiche Version nachgebaut wird. Lädt es danach nicht, wird das
  gemeldet und nicht überspielt.

---

## 6. Sicherheit — was abgedeckt ist und was nicht

**Abgedeckt**

* SIP lauscht nur auf der LAN-Adresse, nie auf `0.0.0.0` (wird nach der
  Installation aktiv nachgeprüft)
* Zugriffsliste in Asterisk auf private Netze
* kein anonymer SIP-Zugang
* zufälliges Passwort, nur für `root` lesbar, nicht im Quellcode, nicht
  im Systemprotokoll
* nftables verwirft SIP/RTP/Statusseite von außerhalb des LAN
* fail2ban gegen das Raten von SIP-Passwörtern
* Mehrwert- und Satellitennummern im Wählplan gesperrt
* höchstens ein ausgehendes Gespräch gleichzeitig
* Asterisk läuft nicht als `root`

**Nicht abgedeckt**

| Punkt | Warum |
|---|---|
| Vollständige Systemfirewall | Bewusste Entscheidung: Die Regeln laufen in einer eigenen Tabelle mit `policy accept`. So kann man sich nicht per SSH aussperren. Wer mehr will, ergänzt `/etc/nftables.conf`. |
| SIP-Verschlüsselung (TLS/SRTP) | Im LAN unverschlüsselt. Für den Zugriff von außen ist WireGuard vorgesehen — das verschlüsselt die gesamte Strecke. |
| Schutz gegen Angreifer im eigenen LAN | Wer im selben Netz ist und das Passwort kennt, kann telefonieren. |
| Absicherung des Betriebssystems | Automatische Updates, SSH-Härtung, Schlüsselanmeldung: nicht Teil dieses Projekts. |
| Verschlüsselung der SD-Karte | Wer die Karte in der Hand hat, liest das SIP-Passwort und die Bluetooth-Schlüssel. |

---

## 6a. Watchdog und Anrufliste — was sie leisten und was nicht

**Der Watchdog** prüft jede Minute, ob Asterisk antwortet, `chan_mobile`
geladen ist und das iPhone verbunden ist, und stellt die Verbindung
gestuft wieder her.

Was er **nicht** kann:

* Er kann kein iPhone wieder in Reichweite bringen und keines aus dem
  Auto zurückholen. Ist die Ursache außerhalb des Pi, meldet er das nach
  20 Minuten und hört auf einzugreifen — absichtlich, damit der Pi nicht
  in einer Neustartschleife landet.
* Er greift **während eines Gesprächs nicht ein**. Reißt eine Verbindung
  mitten im Telefonat ab, wird sie erst nach dem Auflegen wieder
  aufgebaut.
* Er verschickt keine Benachrichtigungen. Der Zustand steht in
  `gateway-test`, auf der Statusseite und in `watchdog.log` — wer aktiv
  informiert werden möchte, braucht zusätzlich etwas Eigenes.
* Erkennt er ein Problem, das er nicht lösen kann, bleibt es bestehen.
  Der Watchdog ersetzt keine Fehlersuche.

**Die Anrufliste** stammt aus Asterisks eigener Aufzeichnung. Sie zeigt
nur, was über das Gateway lief:

* Anrufe, die direkt am iPhone angenommen wurden, tauchen **nicht** auf.
* Anrufe, die das Mobilfunknetz gar nicht erst durchgestellt hat (weil
  das iPhone nicht verbunden war), tauchen ebenfalls nicht auf — dort
  hilft nur die Anrufliste des iPhones selbst.
* Die Rufnummer kommt aus der Anruferkennung des Netzes. Unterdrückte
  Nummern bleiben unbekannt.

---

## 7. Betrieb und Recht

* **Keine Notrufe.** Standortübermittlung und Rückrufbarkeit sind nicht
  gegeben.
* **Vertragsbedingungen prüfen.** Manche Mobilfunkanbieter untersagen es,
  einen Anschluss als Gateway für Dritte zu nutzen (Stichworte
  „GSM-Gateway", „SIM-Boxing"). Bei ungewöhnlichem Verkehrsmuster kann
  eine SIM gesperrt werden.
* **Roaming.** Verlässt das iPhone die Schweiz, telefoniert es im
  Roaming — mit den entsprechenden Kosten. Das Gateway merkt davon
  nichts.
* **Akku.** Das iPhone sollte dauerhaft am Ladegerät hängen. HFP hält das
  Funkmodul wach.
* **Datenschutz.** Anrufe laufen über Geräte in Ihrer Wohnung.
  Gesprächsdaten stehen in den Asterisk-Protokollen.

---

## 8. Was dieses Setup ausdrücklich nicht tut

* Es richtet **keine zweite SIM und kein zweites Gateway** ein.
* Es öffnet **keinen Port ins Internet** und richtet keine
  Portweiterleitung ein.
* Es aktiviert **kein VPN** — WireGuard ist nur vorbereitet.
* Es behauptet **nicht**, dass die Audioqualität perfekt ist.
* Es schreibt **keine Asterisk-Konfiguration mit erfundenen
  MAC-Adressen**. Fehlt eine echte Angabe, bricht es ab und sagt, warum.
