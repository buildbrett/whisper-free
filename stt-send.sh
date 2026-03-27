#!/bin/bash
# Send a command to the Whisper STT daemon via Unix datagram socket.
# Usage: stt-send.sh start|stop
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/.venv/bin/python" -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(sys.argv[1].encode(), '/tmp/whisper_free.sock')
s.close()
" "$1"
