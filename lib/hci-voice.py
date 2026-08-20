#!/usr/bin/env python3
"""HCI Voice Setting lesen und schreiben.

Warum das noetig ist
--------------------
chan_mobile prueft beim Laden das "Voice Setting" jedes Adapters und
lehnt ihn komplett ab, wenn es nicht 0x0060 ist:

    "Skipping adapter %s. Voice setting must be 0x0060"

0x0060 bedeutet: lineare Kodierung, 2er-Komplement, 16 Bit, CVSD.
Das ist der Standardwert nach der Bluetooth-Spezifikation, manche
Adapter bzw. Treiber melden aber etwas anderes.

Frueher hat man das mit "hciconfig hciX voice 0x0060" gesetzt.
hciconfig gehoert zu den veralteten BlueZ-Werkzeugen und fehlt auf
neueren Systemen. Dieses Script spricht deshalb direkt mit dem
HCI-Socket des Kernels.

Aufruf:
    hci-voice.py show  <hciX>          Wert anzeigen
    hci-voice.py set   <hciX> [0x0060] Wert setzen und pruefen

Exit-Codes:
    0  alles in Ordnung
    1  Fehler (Adapter fehlt, keine Rechte, Wert nicht setzbar)
    2  falsche Argumente
"""

import socket
import struct
import sys

HCI_FILTER = 2
HCI_COMMAND_PKT = 0x01
HCI_EVENT_PKT = 0x04
EVT_CMD_COMPLETE = 0x0E

OGF_HOST_CTL = 0x03
OCF_READ_VOICE_SETTING = 0x0025
OCF_WRITE_VOICE_SETTING = 0x0026

DEFAULT_VOICE_SETTING = 0x0060


def opcode(ogf, ocf):
    return (ogf << 10) | ocf


def dev_id_of(name):
    """'hci1' -> 1"""
    text = name.strip()
    if text.startswith("hci"):
        text = text[3:]
    if not text.isdigit():
        raise ValueError("Kein gueltiger HCI-Name: %s" % name)
    return int(text)


def open_hci(dev_id):
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    sock.settimeout(3.0)
    try:
        sock.bind((dev_id,))
    except TypeError:
        # Neuere Python-Versionen erwarten (dev_id, channel).
        sock.bind((dev_id, 0))
    return sock


def set_filter(sock, op):
    flt = bytearray(14)
    struct.pack_into("<I", flt, 0, 1 << HCI_EVENT_PKT)
    struct.pack_into("<I", flt, 4, 1 << EVT_CMD_COMPLETE)
    struct.pack_into("<I", flt, 8, 0)
    struct.pack_into("<H", flt, 12, op)
    sock.setsockopt(socket.SOL_HCI, HCI_FILTER, bytes(flt))


def send_command(sock, op, params=b""):
    packet = struct.pack("<BHB", HCI_COMMAND_PKT, op, len(params)) + params
    sock.send(packet)


def read_command_complete(sock, op):
    """Wartet auf das Command-Complete-Event zum gesendeten Kommando."""
    while True:
        data = sock.recv(260)
        if len(data) < 7:
            continue
        if data[0] != HCI_EVENT_PKT or data[1] != EVT_CMD_COMPLETE:
            continue
        event_opcode = struct.unpack_from("<H", data, 4)[0]
        if event_opcode != op:
            continue
        # data[6] ist der Status, danach folgen die Rueckgabewerte.
        return data[6], data[7:]


def read_voice_setting(dev_id):
    op = opcode(OGF_HOST_CTL, OCF_READ_VOICE_SETTING)
    sock = open_hci(dev_id)
    try:
        set_filter(sock, op)
        send_command(sock, op)
        status, payload = read_command_complete(sock, op)
        if status != 0:
            raise OSError("HCI Read_Voice_Setting meldet Status 0x%02x" % status)
        if len(payload) < 2:
            raise OSError("HCI Read_Voice_Setting lieferte zu wenig Daten")
        return struct.unpack_from("<H", payload, 0)[0]
    finally:
        sock.close()


def write_voice_setting(dev_id, value):
    op = opcode(OGF_HOST_CTL, OCF_WRITE_VOICE_SETTING)
    sock = open_hci(dev_id)
    try:
        set_filter(sock, op)
        send_command(sock, op, struct.pack("<H", value))
        status, _ = read_command_complete(sock, op)
        if status != 0:
            raise OSError("HCI Write_Voice_Setting meldet Status 0x%02x" % status)
    finally:
        sock.close()


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2

    action = argv[1]
    try:
        dev_id = dev_id_of(argv[2])
    except ValueError as exc:
        sys.stderr.write("%s\n" % exc)
        return 2

    if action == "show":
        try:
            value = read_voice_setting(dev_id)
        except Exception as exc:
            sys.stderr.write("Voice Setting nicht lesbar: %s\n" % exc)
            return 1
        print("0x%04x" % value)
        return 0 if value == DEFAULT_VOICE_SETTING else 1

    if action == "set":
        wanted = DEFAULT_VOICE_SETTING
        if len(argv) > 3:
            wanted = int(argv[3], 0)
        try:
            current = read_voice_setting(dev_id)
        except Exception as exc:
            sys.stderr.write("Voice Setting nicht lesbar: %s\n" % exc)
            return 1
        if current == wanted:
            print("0x%04x (unveraendert)" % current)
            return 0
        try:
            write_voice_setting(dev_id, wanted)
            current = read_voice_setting(dev_id)
        except Exception as exc:
            sys.stderr.write("Voice Setting nicht setzbar: %s\n" % exc)
            return 1
        if current != wanted:
            sys.stderr.write(
                "Voice Setting blieb bei 0x%04x statt 0x%04x\n" % (current, wanted)
            )
            return 1
        print("0x%04x (gesetzt)" % current)
        return 0

    sys.stderr.write("Unbekannte Aktion: %s\n" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
