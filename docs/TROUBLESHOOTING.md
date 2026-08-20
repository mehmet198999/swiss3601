# Fehlersuche

Immer zuerst:

```bash
sudo gateway-test
```

Die Ausgabe nennt zu jeder Prüfung den Grund. Danach gezielt hier
weiterlesen.

---

## Inhalt

* [Der Pi ist nicht erreichbar](#der-pi-ist-nicht-erreichbar)
* [Die Installation läuft nicht oder bricht ab](#die-installation-läuft-nicht-oder-bricht-ab)
* [Der USB-BT500 wird nicht erkannt](#der-usb-bt500-wird-nicht-erkannt)
* [Das iPhone lässt sich nicht koppeln](#das-iphone-lässt-sich-nicht-koppeln)
* [HFP wird nicht erkannt](#hfp-wird-nicht-erkannt)
* [chan_mobile lädt nicht](#chan_mobile-lädt-nicht)
* [Das iPhone verbindet sich nicht mit Asterisk](#das-iphone-verbindet-sich-nicht-mit-asterisk)
* [Das Softphone meldet sich nicht an](#das-softphone-meldet-sich-nicht-an)
* [Anrufe kommen nicht an](#anrufe-kommen-nicht-an)
* [Kein Ton oder nur in eine Richtung](#kein-ton-oder-nur-in-eine-richtung)
* [Gespräche brechen ab](#gespräche-brechen-ab)
* [Nach einem Neustart geht nichts mehr](#nach-einem-neustart-geht-nichts-mehr)
* [Ganz von vorn anfangen](#ganz-von-vorn-anfangen)

---

## Der Pi ist nicht erreichbar

**`ping gsm-gateway.local` schlägt fehl**

1. Leuchtet die rote LED am Pi? Ohne Strom passiert nichts.
2. Blinkt die grüne LED? Dauerhaft aus deutet auf eine nicht lesbare
   SD-Karte hin — dann im Imager neu schreiben.
3. Leuchten die LEDs an der Netzwerkbuchse?
4. Im Router unter „Netzwerk"/„Heimnetz" nach `gsm-gateway` suchen und
   die IP-Adresse direkt verwenden:
   ```bash
   ssh gateway@192.168.1.42
   ```
5. Manche Netze lösen `.local`-Namen nicht auf. Dann hilft nur die
   IP-Adresse.

**SSH verweigert die Verbindung**

SSH wird nur aktiviert, wenn es im Raspberry Pi Imager angehakt war.
War es das nicht, muss die Karte neu geschrieben werden.

**„REMOTE HOST IDENTIFICATION HAS CHANGED"**

Normal nach einer Neuinstallation. Alten Schlüssel entfernen:

```bash
ssh-keygen -R gsm-gateway.local
```

---

## Die Installation läuft nicht oder bricht ab

**Wie ist der Stand?**

```bash
sudo systemctl status gsm-gateway-firstboot.service
sudo tail -50 /var/log/gsm-gateway/install.log
sudo cat /var/lib/gsm-gateway/install-status
```

**Wurde etwas übersprungen?**

```bash
ls /var/lib/gsm-gateway/steps/
```

Jede `.done`-Datei ist ein erledigter Schritt. Fehlt einer, wurde dort
abgebrochen.

**Fortsetzen**

```bash
sudo systemctl start gsm-gateway-firstboot.service
sudo journalctl -u gsm-gateway-firstboot.service -f
```

**Einen bestimmten Schritt wiederholen**

```bash
sudo rm /var/lib/gsm-gateway/steps/13-asterisk-install.done
sudo /opt/gsm-gateway/install/firstboot-install.sh
```

**„Die Erstinstallation wurde dauerhaft gestoppt"**

Nach fünf Fehlversuchen hört der Pi auf. Ursache in
`/var/log/gsm-gateway/error.log` beheben, dann:

```bash
sudo rm /var/lib/gsm-gateway/setup-abandoned
sudo systemctl start gsm-gateway-firstboot.service
```

**Der Asterisk-Build schlägt fehl**

```bash
sudo tail -60 /var/log/gsm-gateway/asterisk.log
```

Häufige Ursachen:

| Meldung | Ursache und Abhilfe |
|---|---|
| `virtual memory exhausted` | Zu wenig Swap. In `/etc/gsm-gateway/gateway.conf` `GG_BUILD_SWAP_MB="3072"` setzen und den Schritt wiederholen. |
| `No space left on device` | SD-Karte zu klein. Mindestens 16 GB, besser 32 GB. Platz schaffen: `sudo rm -rf /usr/local/src/gsm-gateway`. |
| `SHA-256-Pruefsumme stimmt nicht` | Abgebrochener Download. Einfach erneut versuchen. |
| `GPG-Signatur ist UNGUELTIG` | **Nicht ignorieren.** Netzwerk prüfen; im Zweifel aus einem anderen Netz erneut versuchen. |
| `chan_mobile nicht aktivieren` | `libbluetooth-dev` hat beim `configure` gefehlt: `sudo apt install libbluetooth-dev`, dann den Schritt wiederholen. |
| Abbruch mitten im Build, Pi startet neu | Netzteil zu schwach. `vcgencmd get_throttled` sollte `0x0` liefern. |

Der Build dauert auf einem Pi 3 **1,5 bis 4 Stunden** — Geduld ist kein
Fehler.

---

## Der USB-BT500 wird nicht erkannt

```bash
lsusb | grep -i 0b05
sudo bluetooth-check
```

**Nichts unter `lsusb`:** anderen USB-Anschluss probieren, Adapter neu
einstecken, `dmesg | tail -20` ansehen.

**Sichtbar unter `lsusb`, aber kein `hci`-Gerät:** Es fehlt die Firmware.

```bash
sudo dmesg | grep -i rtl_bt
sudo apt install firmware-realtek
sudo reboot
```

Der ASUS USB-BT500 nutzt einen Realtek RTL8761B und lädt
`rtl_bt/rtl8761b*_fw.bin` aus dem Paket `firmware-realtek`. Fehlt das
Paket, bleibt der Adapter stumm.

**Es wird das interne Bluetooth verwendet:** In
`/etc/gsm-gateway/gateway.conf` steht `GG_BT_ADAPTER="usb"`. Ist der
USB-Adapter eingesteckt, wird er bevorzugt. Danach:

```bash
sudo /opt/gsm-gateway/install/install-bluetooth.sh detect
sudo /opt/gsm-gateway/install/setup-chan-mobile.sh
```

**Bluetooth blockiert:**

```bash
sudo rfkill unblock bluetooth
sudo systemctl restart bluetooth
```

---

## Das iPhone lässt sich nicht koppeln

**Das iPhone taucht bei der Suche nicht auf**

* Der Bluetooth-Bildschirm am iPhone muss **offen** sein — sonst ist das
  Gerät nicht sichtbar.
* Näher an den Pi gehen (unter 2 Meter).
* Andersherum probieren:
  ```bash
  sudo pair-iphone --from-iphone
  ```
  Dann am iPhone in der Liste `gsm-gateway` antippen.

**Das Pairing schlägt fehl**

Alte Reste auf beiden Seiten entfernen:

Am iPhone: Einstellungen → Bluetooth → beim Eintrag `gsm-gateway` auf
das (i) tippen → **„Dieses Gerät ignorieren"**.

Am Pi:

```bash
sudo bluetoothctl remove AA:BB:CC:DD:EE:FF
sudo systemctl restart bluetooth
sudo pair-iphone
```

**Die Sitzung hängt**

`quit` eingeben und Enter drücken. Nach fünf Minuten bricht sie von
selbst ab.

---

## HFP wird nicht erkannt

Die Meldung lautet:

> Das iPhone ist per Bluetooth verbunden, aber der benötigte
> HFP-Telefoniedienst wurde nicht erkannt.

Ohne HFP gibt es keine Telefonie — deshalb wird an dieser Stelle
bewusst abgebrochen.

**1. Geräteklasse prüfen**

iOS bietet HFP nur Geräten an, die sich als Freisprecheinrichtung
ausgeben.

```bash
grep -i class /etc/bluetooth/main.conf
```

Erwartet: `Class = 0x200404`. Falls nicht:

```bash
sudo /opt/gsm-gateway/install/install-bluetooth.sh configure
sudo systemctl restart bluetooth
```

Danach am iPhone „Dieses Gerät ignorieren", am Pi `bluetoothctl remove`,
dann neu koppeln.

**2. Angebotene Dienste ansehen**

```bash
sudo bluetoothctl info AA:BB:CC:DD:EE:FF
```

Gesucht ist eine Zeile mit `0000111f` (Handsfree Audio Gateway).
Steht dort nur `00001112`, bietet das iPhone lediglich das
Headset-Profil an — das genügt nicht.

**3. Direkt per SDP nachsehen**

```bash
sudo /opt/gsm-gateway/lib/sdp-rfcomm.py AA:BB:CC:DD:EE:FF
```

Kommt eine Zahl zurück, ist HFP vorhanden und die Zahl ist der
RFCOMM-Kanal.

**4. iPhone neu starten**

Manche iOS-Versionen geben die Dienste erst nach einem Neustart wieder
frei.

---

## chan_mobile lädt nicht

```bash
sudo asterisk -rx "module show like chan_mobile"
sudo grep -i mobile /var/log/asterisk/messages | tail -20
```

| Meldung im Protokoll | Ursache und Abhilfe |
|---|---|
| `Voice setting must be 0x0060` | Der Adapter meldet ein falsches HCI-Voice-Setting: `sudo gateway-hci-prepare hci1`, danach `sudo systemctl restart asterisk`. |
| `Unable to communicate with adapter` | Die MAC in `/etc/asterisk/chan_mobile.conf` passt nicht zum vorhandenen Adapter. Prüfen mit `sudo bluetooth-check`, korrigieren mit `sudo /opt/gsm-gateway/install/setup-chan-mobile.sh`. |
| `No adapters could be loaded` | Der Abschnitt `[adapter]` fehlt oder hat keine `address`. Gleiche Abhilfe. |
| `Missing required port or address` | Beim Geräteblock fehlt `port=`. `sudo pair-iphone` erneut ausführen. |
| `Unknown adapter ... specified` | Die `adapter=`-Zeile beim Gerät passt nicht zur `id=` beim Adapter. `sudo /opt/gsm-gateway/install/setup-chan-mobile.sh`. |
| Modul fehlt ganz | `sudo /opt/gsm-gateway/install/install-asterisk.sh ensure-chan-mobile` |

Aktuellen Zustand des Adapters ansehen:

```bash
sudo gateway-hci-prepare --show hci1
```

---

## Das iPhone verbindet sich nicht mit Asterisk

```bash
sudo asterisk -rx "mobile show devices"
```

Erwartet wird eine Zeile mit `Connected: Yes` und `State: Free`.

**`Connected: No`**

* Ist Bluetooth am iPhone an und das Gerät in Reichweite?
* Ist das iPhone gerade mit etwas anderem verbunden — zum Beispiel der
  Freisprechanlage im Auto? Ein iPhone hält nur **eine** HFP-Verbindung
  gleichzeitig.
* `chan_mobile` versucht es alle 30 Sekunden erneut. Etwas Geduld.
* Am iPhone: Einstellungen → Bluetooth → `gsm-gateway` antippen, um die
  Verbindung von Hand herzustellen.

**`State: No Service`**

Verbunden, aber die SIM hat gerade keinen Netzempfang. iPhone ans Fenster
legen oder Flugmodus kurz ein- und ausschalten.

**Nach einem Neustart erst nach Minuten verbunden**

Normal. `chan_mobile` startet seinen Verbindungsversuch nach dem Laden
und wiederholt ihn im 30-Sekunden-Takt.

---

## Das Softphone meldet sich nicht an

```bash
sudo asterisk -rx "pjsip show endpoints"
sudo asterisk -rx "pjsip show aors"
```

Prüfen:

1. **Passwort korrekt?** `sudo gateway-credentials`
2. **Richtige Adresse?** Muss die aktuelle IP des Pi sein.
   Hat sich die IP geändert:
   ```bash
   sudo /opt/gsm-gateway/install/setup-sip.sh
   ```
3. **Gleiches Netz?** Aus einem Gäste-WLAN heraus blockiert die Firewall
   den Zugriff — genau dafür ist sie da.
4. **Transport UDP** eingestellt?
5. Live mitlesen:
   ```bash
   sudo asterisk -rvvv
   pjsip set logger on
   ```
   Beenden mit `pjsip set logger off` und `exit`.

**Nach mehreren Fehlversuchen gar keine Reaktion mehr**

fail2ban hat die Adresse gesperrt:

```bash
sudo fail2ban-client status asterisk
sudo fail2ban-client set asterisk unbanip 192.168.1.99
```

---

## Anrufe kommen nicht an

**Eingehend (Test A): Das Softphone klingelt nicht**

```bash
sudo asterisk -rvvv
```

Während des Anrufs sollte etwas wie
`Eingehender GSM-Anruf von ...` erscheinen.

* **Nichts zu sehen:** `chan_mobile` ist nicht verbunden — siehe oben.
* **Zu sehen, aber es klingelt nicht:** Das Softphone ist nicht
  registriert (`pjsip show aors` zeigt keinen Kontakt).
* **Der Anruf landet auf der Mailbox:** Die Mailbox des Mobilfunkanbieters
  greift zu früh. Beim Anbieter die Zeit bis zur Rufumleitung erhöhen
  oder die Mailbox abschalten.

**Ausgehend (Test B): Es passiert nichts**

* Nummer im richtigen Format? `0791234567` oder `+41791234567`.
* Gesperrte Nummer? Mehrwert- und Satellitennummern sind blockiert; im
  Protokoll steht dann `Gesperrtes Ziel`.
* Läuft bereits ein Gespräch? Es ist genau eines gleichzeitig möglich.

---

## Kein Ton oder nur in eine Richtung

Der Verbindungsaufbau funktioniert, aber niemand hört etwas.

**1. SCO-Unterstützung prüfen**

```bash
sudo /opt/gsm-gateway/lib/sco-check.py
```

**2. Konkurrierende Audiodienste**

```bash
systemctl is-active bluealsa pipewire pulseaudio wireplumber
```

Läuft davon etwas, streitet es sich mit `chan_mobile` um HFP:

```bash
sudo /opt/gsm-gateway/install/setup-audio.sh
```

**3. eSCO abschalten (Troubleshooting-Schritt)**

Manche Adapter kommen mit der moderneren eSCO-Variante nicht zurecht:

```bash
echo 'options bluetooth disable_esco=1' | sudo tee /etc/modprobe.d/bluetooth-esco.conf
sudo reboot
```

Bringt das nichts, die Datei wieder löschen.

**4. Nur eine Richtung hörbar**

Meist Lautstärke: Am iPhone während des Gesprächs die Lautstärke prüfen.
In Asterisk lässt sich nachhelfen — in `/etc/asterisk/extensions.conf`
vor dem `Dial`:

```
 same => n,Set(VOLUME(TX)=3)
 same => n,Set(VOLUME(RX)=3)
```

Danach `sudo asterisk -rx "dialplan reload"`.

**5. USB-Stromsparen**

```bash
cat /sys/module/btusb/parameters/enable_autosuspend
```

Erwartet `N`. Sonst:

```bash
sudo /opt/gsm-gateway/install/setup-audio.sh
sudo reboot
```

---

## Gespräche brechen ab

| Ursache | Abhilfe |
|---|---|
| iPhone zu weit weg | Unter 5 Meter, möglichst freie Sicht zum Pi |
| WLAN stört Bluetooth | Netzwerkkabel verwenden; beide nutzen 2,4 GHz |
| USB-Stromsparen | `enable_autosuspend` muss `N` sein (siehe oben) |
| Schwaches Netzteil | `vcgencmd get_throttled` muss `throttled=0x0` liefern |
| iPhone-Akku leer / Stromsparmodus | iPhone ans Ladegerät |
| iPhone verbindet sich mit dem Auto | Nur eine HFP-Verbindung gleichzeitig möglich |

Verlauf ansehen:

```bash
sudo grep -i 'mobile' /var/log/asterisk/messages | tail -40
sudo dmesg | grep -i bluetooth | tail -20
```

---

## Nach einem Neustart geht nichts mehr

**Läuft alles?**

```bash
sudo gateway-test
systemctl status bluetooth asterisk
```

**Asterisk startet nicht**

```bash
sudo journalctl -u asterisk -n 40
```

Häufig ist es ein Tippfehler in einer von Hand geänderten
Konfigurationsdatei. Sicherungen liegen bereit:

```bash
ls /etc/asterisk/backup/
sudo cp /etc/asterisk/backup/<Zeitstempel>/pjsip.conf /etc/asterisk/
sudo systemctl restart asterisk
```

**IP-Adresse hat sich geändert**

```bash
sudo /opt/gsm-gateway/install/setup-sip.sh
sudo /opt/gsm-gateway/install/setup-firewall.sh
```

Dauerhaft lösen: DHCP-Reservierung im Router.

**Der USB-Adapter wurde umgesteckt**

```bash
sudo /opt/gsm-gateway/install/install-bluetooth.sh detect
sudo /opt/gsm-gateway/install/setup-chan-mobile.sh
sudo systemctl restart asterisk
```

---

## Ganz von vorn anfangen

**Nur die Gateway-Konfiguration neu aufbauen** (Asterisk bleibt
installiert, kein neuer Build):

```bash
sudo backup-gateway
sudo rm -f /var/lib/gsm-gateway/setup-complete
sudo rm -f /var/lib/gsm-gateway/steps/1[4-9]-* /var/lib/gsm-gateway/steps/2*
sudo systemctl start gsm-gateway-firstboot.service
```

**Alles entfernen:**

```bash
sudo uninstall-gateway
```

**SD-Karte komplett neu:** Ab Abschnitt 3 der README neu beginnen. Die
Kopplung am iPhone vorher mit „Dieses Gerät ignorieren" entfernen.

---

## Informationen für eine Rückfrage sammeln

```bash
sudo gateway-check   > /tmp/diag.txt 2>&1
sudo bluetooth-check >> /tmp/diag.txt 2>&1
sudo gateway-test --no-color >> /tmp/diag.txt 2>&1
```

`/tmp/diag.txt` enthält danach alles Wesentliche.

> ⚠️ Vor dem Weitergeben durchsehen: Die Datei enthält MAC-Adressen und
> IP-Adressen. Das SIP-Passwort steht **nicht** darin.
