#!/usr/bin/env python3
"""Prueft, ob der Kernel SCO-Sockets unterstuetzt.

Ueber SCO laeuft bei chan_mobile die eigentliche Sprachverbindung
(Bluetooth Synchronous Connection Oriented link). Fehlt die
Unterstuetzung, kommt zwar eine Verbindung zum iPhone zustande, es ist
aber kein Ton zu hoeren.

Exit 0 = SCO verfuegbar, Exit 1 = nicht verfuegbar.
"""

import socket
import sys


def main():
    proto = getattr(socket, "BTPROTO_SCO", 2)
    try:
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, proto)
    except AttributeError:
        print("Python kennt AF_BLUETOOTH nicht")
        return 1
    except OSError as exc:
        print("SCO-Socket nicht moeglich: %s" % exc)
        return 1
    sock.close()
    print("SCO-Sockets werden unterstuetzt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
