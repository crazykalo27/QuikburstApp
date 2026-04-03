"""
VESC Serial Control — Python companion for vescUartTest.ino

Connects to the ESP32 over USB serial and sends commands to the VESC via
the text protocol defined in the .ino file.

Supported commands (interactive prompt or programmatic):
  SET_CURRENT <amps>   — drive motor at given current
  SET_BRAKE <amps>     — apply braking current
  SET_DUTY <duty>      — duty cycle 0.0–1.0
  SET_RPM <erpm>       — target eRPM (RPM × motor poles)
  STOP                 — release motor (current = 0)
  GET_VALUES           — request telemetry snapshot
  GET_FW               — request firmware version
  KEEPALIVE            — send keepalive to VESC
  QUIT / EXIT          — close connection

Usage:
  python vesc_serial_control.py [port] [--baud 115200]
"""

import argparse
import sys
import time
import threading
from typing import Optional

import serial
import serial.tools.list_ports


READY_TIMEOUT_S = 10.0
RESPONSE_TIMEOUT_S = 2.0


# --------------------------------------------------------------------------
# port discovery
# --------------------------------------------------------------------------

def find_serial_port() -> Optional[str]:
    ports = serial.tools.list_ports.comports()
    for p in ports:
        desc = (p.device + " " + str(p.description) + " " + str(p.manufacturer)).lower()
        if any(k in desc for k in ("usb", "serial", "slab", "cp210", "ch340", "ftdi")):
            return p.device
    if ports:
        return ports[0].device
    return None


# --------------------------------------------------------------------------
# reader thread — prints everything the ESP32 sends
# --------------------------------------------------------------------------

class SerialReader:
    def __init__(self, ser: serial.Serial):
        self.ser = ser
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _run(self):
        while not self._stop.is_set():
            try:
                if self.ser.in_waiting:
                    line = self.ser.readline().decode("utf-8", errors="ignore").strip()
                    if line:
                        print(f"  << {line}")
                else:
                    time.sleep(0.02)
            except (serial.SerialException, OSError):
                break


# --------------------------------------------------------------------------
# command sending
# --------------------------------------------------------------------------

def send_command(ser: serial.Serial, cmd: str):
    raw = cmd.strip() + "\n"
    ser.write(raw.encode("utf-8"))
    ser.flush()


def wait_for_ready(ser: serial.Serial, timeout: float = READY_TIMEOUT_S) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if ser.in_waiting:
            line = ser.readline().decode("utf-8", errors="ignore").strip()
            if line:
                print(f"  << {line}")
            if "READY" in line.upper():
                return True
        else:
            time.sleep(0.05)
    return False


# --------------------------------------------------------------------------
# interactive loop
# --------------------------------------------------------------------------

HELP_TEXT = """
Commands:
  SET_CURRENT <amps>   Drive motor at <amps> (float, signed)
  SET_BRAKE <amps>     Brake at <amps>
  SET_DUTY <duty>      Duty cycle 0.0–1.0
  SET_RPM <erpm>       Target eRPM
  STOP                 Release motor
  GET_VALUES           Read VESC telemetry
  GET_FW               Read VESC firmware version
  KEEPALIVE            Send keepalive
  HELP                 Show this help
  QUIT / EXIT          Disconnect
""".strip()


def interactive(ser: serial.Serial):
    reader = SerialReader(ser)
    reader.start()

    print(HELP_TEXT)
    print()

    try:
        while True:
            try:
                raw = input("vesc> ").strip()
            except EOFError:
                break

            if not raw:
                continue

            upper = raw.upper()

            if upper in ("QUIT", "EXIT", "Q"):
                send_command(ser, "STOP")
                time.sleep(0.2)
                break

            if upper == "HELP":
                print(HELP_TEXT)
                continue

            # Normalise user-friendly input → protocol command
            parts = raw.split(None, 1)
            verb = parts[0].upper()

            if verb == "SET_CURRENT" and len(parts) == 2:
                send_command(ser, f"SET_CURRENT,{parts[1]}")
            elif verb == "SET_BRAKE" and len(parts) == 2:
                send_command(ser, f"SET_BRAKE,{parts[1]}")
            elif verb == "SET_DUTY" and len(parts) == 2:
                send_command(ser, f"SET_DUTY,{parts[1]}")
            elif verb == "SET_RPM" and len(parts) == 2:
                send_command(ser, f"SET_RPM,{parts[1]}")
            elif verb in ("STOP", "GET_VALUES", "GET_FW", "KEEPALIVE"):
                send_command(ser, verb)
            else:
                # Pass through verbatim (lets you test raw protocol strings)
                send_command(ser, raw)

            time.sleep(0.15)

    except KeyboardInterrupt:
        print("\nInterrupted — sending STOP")
        send_command(ser, "STOP")
        time.sleep(0.2)
    finally:
        reader.stop()


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="VESC Serial Control")
    parser.add_argument("port", nargs="?", help="Serial port (e.g. COM4 or /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    port = args.port or find_serial_port()

    if not port:
        if sys.platform == "win32":
            port = input("COM port [COM4]: ").strip() or "COM4"
        else:
            port = input("Serial port [/dev/ttyUSB0]: ").strip() or "/dev/ttyUSB0"

    print(f"Connecting to {port} @ {args.baud}...")
    try:
        ser = serial.Serial(port, args.baud, timeout=0.5)
    except serial.SerialException as e:
        print(f"Failed to open {port}: {e}")
        sys.exit(1)

    print("  Waiting for ESP32 (opening port may trigger reset)...")
    if not wait_for_ready(ser):
        print("  (No READY seen — proceeding anyway)")

    time.sleep(0.3)
    while ser.in_waiting:
        ser.readline()

    print()
    interactive(ser)

    ser.close()
    print("Disconnected.")


if __name__ == "__main__":
    main()
