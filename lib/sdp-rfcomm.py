#!/usr/bin/env python3
"""Ermittelt den RFCOMM-Kanal eines Bluetooth-Dienstes per SDP.

Wozu?
-----
chan_mobile braucht in chan_mobile.conf zwingend die Zeile

    port=<RFCOMM-Kanal>

Der Kanal ist geraeteabhaengig und aendert sich zwischen
iPhone-Modellen und iOS-Versionen - er darf also nicht geraten werden.

Frueher hat man ihn mit "sdptool search --bdaddr <MAC> HFAG" ermittelt.
sdptool gehoert zu den veralteten BlueZ-Werkzeugen und fehlt auf
neueren Systemen. Dieses Script spricht das SDP-Protokoll deshalb
direkt ueber einen L2CAP-Socket (PSM 1).

Aufruf:
    sdp-rfcomm.py <MAC> [UUID16]

    UUID16 (hexadezimal, Vorgabe 111f = Handsfree Audio Gateway):
       111f  Handsfree Audio Gateway  (das braucht chan_mobile)
       1112  Headset Audio Gateway    (Notloesung, nur Headset-Profil)

Ausgabe: die Kanalnummer, z.B. "6"
Exit 0 = gefunden, 1 = nicht gefunden / Fehler, 2 = falsche Argumente
"""

import socket
import struct
import sys

SDP_PSM = 1
SDP_SERVICE_SEARCH_ATTR_REQ = 0x06
SDP_SERVICE_SEARCH_ATTR_RSP = 0x07
SDP_ERROR_RSP = 0x01

ATTR_PROTOCOL_DESCRIPTOR_LIST = 0x0004
UUID_RFCOMM = 0x0003

MAX_ATTR_BYTES = 0xFFF


# --- Kodierung -------------------------------------------------------

def de_uuid16(value):
    return struct.pack(">BH", 0x19, value)


def de_uint16(value):
    return struct.pack(">BH", 0x09, value)


def de_sequence(payload):
    return struct.pack(">BB", 0x35, len(payload)) + payload


# --- Dekodierung -----------------------------------------------------

class Element(object):
    """Ein SDP-Datenelement: Typ plus Wert."""

    __slots__ = ("kind", "value")

    def __init__(self, kind, value):
        self.kind = kind
        self.value = value


def read_element(data, offset):
    """Liest ein Datenelement und liefert (Element, neuer Offset)."""
    if offset >= len(data):
        raise ValueError("SDP-Antwort endet unerwartet")

    header = data[offset]
    offset += 1
    kind = header >> 3
    size_index = header & 0x07

    fixed = {0: 1, 1: 2, 2: 4, 3: 8, 4: 16}
    if size_index in fixed:
        size = fixed[size_index]
        if kind == 0:  # nil hat keine Nutzdaten
            size = 0
    elif size_index == 5:
        size = data[offset]
        offset += 1
    elif size_index == 6:
        size = struct.unpack_from(">H", data, offset)[0]
        offset += 2
    elif size_index == 7:
        size = struct.unpack_from(">I", data, offset)[0]
        offset += 4
    else:
        raise ValueError("Unbekannter SDP-Groessenindex %d" % size_index)

    if offset + size > len(data):
        raise ValueError("SDP-Element ragt ueber das Ende der Antwort hinaus")

    chunk = data[offset:offset + size]
    end = offset + size

    if kind in (6, 7):  # Sequenz bzw. Alternative
        items = []
        inner = 0
        while inner < len(chunk):
            element, inner = read_element(chunk, inner)
            items.append(element)
        return Element(kind, items), end

    if kind == 1:  # unsigned int
        return Element(kind, int.from_bytes(chunk, "big")), end
    if kind == 2:  # signed int
        return Element(kind, int.from_bytes(chunk, "big", signed=True)), end
    if kind == 3:  # UUID
        return Element(kind, int.from_bytes(chunk, "big")), end
    if kind == 5:  # bool
        return Element(kind, bool(chunk and chunk[0])), end

    return Element(kind, chunk), end


def find_rfcomm_channel(element):
    """Sucht in der ProtocolDescriptorList nach dem RFCOMM-Kanal.

    Gesucht wird eine Sequenz, die mit der UUID 0x0003 (RFCOMM)
    beginnt und als naechstes eine Zahl - die Kanalnummer - enthaelt.
    """
    if element.kind not in (6, 7):
        return None

    items = element.value
    if items and items[0].kind == 3 and items[0].value == UUID_RFCOMM:
        for item in items[1:]:
            if item.kind == 1:
                return item.value

    for item in items:
        channel = find_rfcomm_channel(item)
        if channel is not None:
            return channel
    return None


# --- SDP-Abfrage -----------------------------------------------------

def query(address, uuid16):
    request_payload = (
        de_sequence(de_uuid16(uuid16))
        + struct.pack(">H", MAX_ATTR_BYTES)
        + de_sequence(de_uint16(ATTR_PROTOCOL_DESCRIPTOR_LIST))
    )

    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    sock.settimeout(15.0)
    try:
        sock.connect((address, SDP_PSM))
    except OSError as exc:
        sock.close()
        raise OSError("Keine SDP-Verbindung zu %s: %s" % (address, exc))

    collected = b""
    continuation = b"\x00"
    transaction = 1
    try:
        while True:
            payload = request_payload + continuation
            header = struct.pack(">BHH", SDP_SERVICE_SEARCH_ATTR_REQ, transaction, len(payload))
            sock.send(header + payload)

            response = sock.recv(4096)
            if len(response) < 5:
                raise OSError("SDP-Antwort zu kurz")

            pdu_id, _, param_len = struct.unpack_from(">BHH", response, 0)
            body = response[5:5 + param_len]

            if pdu_id == SDP_ERROR_RSP:
                code = struct.unpack_from(">H", body, 0)[0] if len(body) >= 2 else 0
                raise OSError("SDP meldet Fehler 0x%04x" % code)
            if pdu_id != SDP_SERVICE_SEARCH_ATTR_RSP:
                raise OSError("Unerwartete SDP-Antwort 0x%02x" % pdu_id)

            byte_count = struct.unpack_from(">H", body, 0)[0]
            collected += body[2:2 + byte_count]

            cont = body[2 + byte_count:]
            if not cont or cont[0] == 0:
                break
            continuation = cont[:1 + cont[0]]
            transaction += 1
    finally:
        sock.close()

    if not collected:
        return None

    element, _ = read_element(collected, 0)
    return find_rfcomm_channel(element)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    address = argv[1].upper()
    uuid16 = int(argv[2], 16) if len(argv) > 2 else 0x111F

    try:
        channel = query(address, uuid16)
    except Exception as exc:
        sys.stderr.write("SDP-Abfrage fehlgeschlagen: %s\n" % exc)
        return 1

    if channel is None:
        sys.stderr.write(
            "Der Dienst 0x%04x wird von %s nicht angeboten.\n" % (uuid16, address)
        )
        return 1

    print(channel)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
