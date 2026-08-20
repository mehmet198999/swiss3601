WireGuard - vorbereitet, aber bewusst NICHT aktiviert
=====================================================

Dieses Verzeichnis ist der vorgesehene Platz fuer die spaetere
WireGuard-Konfiguration (/etc/gsm-gateway/wireguard/).

Warum ist hier noch nichts eingerichtet?
----------------------------------------
Erst muss die lokale Telefonie funktionieren:

    iPhone  ->  Bluetooth HFP  ->  chan_mobile  ->  Asterisk  ->  SIP 1001

Solange dieser Weg nicht stabil laeuft, wuerde ein VPN die Fehlersuche
nur unnoetig verkomplizieren.

Warum WireGuard und keine Portweiterleitung?
--------------------------------------------
Eine Portweiterleitung auf 5060 macht das Gateway weltweit erreichbar.
SIP-Ports werden im Internet permanent automatisiert abgeklopft. Ein
uebernommenes Gateway telefoniert auf Kosten der Schweizer SIM-Karte -
das kann sehr schnell sehr teuer werden.

Mit WireGuard ist der Pi von aussen unsichtbar. Nur wer den passenden
Schluessel hat, kommt ueberhaupt bis zum SIP-Port.

Geplanter Aufbau
----------------
    Freund in der Tuerkei
        |
        |  WireGuard (UDP, verschluesselt)
        v
    Router zu Hause  ->  Raspberry Pi (Asterisk)
        |
        v
    iPhone  ->  Schweizer Mobilfunknetz

Spaetere Schritte (bewusst noch nicht automatisiert)
----------------------------------------------------
 1. sudo apt install wireguard
 2. Schluesselpaar auf dem Pi erzeugen:
        wg genkey | tee privatekey | wg pubkey > publickey
 3. Schluesselpaar auf dem Geraet des Freundes erzeugen
 4. /etc/wireguard/wg0.conf auf dem Pi anlegen, z.B. Netz 10.9.0.0/24
 5. Im Router genau EINEN UDP-Port auf den Pi weiterleiten
    (WireGuard-Port, NICHT 5060)
 6. In /etc/gsm-gateway/gateway.conf das VPN-Netz ergaenzen:
        GG_LAN_NETWORKS="192.168.0.0/16 10.9.0.0/24"
 7. sudo /opt/gsm-gateway/install/setup-sip.sh
    sudo /opt/gsm-gateway/install/setup-firewall.sh
 8. Im SIP-Client des Freundes als Server die WireGuard-Adresse des Pi
    eintragen (z.B. 10.9.0.1), nicht die oeffentliche IP.

Erst nach Schritt 6/7 darf SIP das VPN-Netz akzeptieren. Vorher wuerde
die ACL in pjsip.conf die Verbindung ohnehin ablehnen.
