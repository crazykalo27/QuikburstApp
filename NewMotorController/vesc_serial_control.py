"""
VESC control — Python companion for vescUartTest.ino

  • GUI (default): tkinter — USB serial or BLE, all commands, log pane
  • CLI: --cli — terminal mode (same flags as before)

Install:
  pip install pyserial bleak matplotlib

Usage:
  python vesc_serial_control.py              # GUI
  python vesc_serial_control.py --cli [COM4] [--baud 115200]
  python vesc_serial_control.py --cli --ble [--name Quikburst]
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import datetime
import math
import os
import queue
import sys
import time
import threading
import tkinter as tk
from collections import deque
from tkinter import ttk, scrolledtext, messagebox
from typing import Any, Callable, Dict, List, Optional, Tuple

import serial
import serial.tools.list_ports

# Nordic UART Service (must match firmware)
NUS_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_RX_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_TX_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

READY_TIMEOUT_S = 10.0
PING_TIMEOUT_S = 5.0

# Must match vescUartTest.ino VESC_MAX_DUTY (fraction 0–1).
MAX_DUTY = 0.20

# Match vescUartTest.ino: 4" spool → linear m/count; used for CSV spool RPM from encoder velocity/position.
_SPOOL_DIAMETER_IN = 4.0
_SPOOL_CIRCUMFERENCE_M = math.pi * _SPOOL_DIAMETER_IN * 0.0254


def _spool_rpm_from_linear_velocity_mps(v_mps: float) -> float:
    """Spool revolutions per minute from linear tape speed (m/s)."""
    if _SPOOL_CIRCUMFERENCE_M <= 0:
        return 0.0
    return (v_mps / _SPOOL_CIRCUMFERENCE_M) * 60.0


def _spool_rpm_from_position_delta(pos1_m: float, pos0_m: float, t1_s: float, t0_s: float) -> float:
    dt = t1_s - t0_s
    if dt <= 0:
        return 0.0
    return _spool_rpm_from_linear_velocity_mps((pos1_m - pos0_m) / dt)


# Coalesce matplotlib redraws for main TELEM+encoder figure and secondary encoder figure (~25 Hz).
LIVE_PLOTS_REDRAW_MS = 40


def clamp_duty_str(s: str) -> float:
    try:
        v = float(str(s).strip())
    except ValueError:
        return 0.0
    return max(0.0, min(MAX_DUTY, v))


def sanitize_vesc_command_line(line: str) -> str:
    """Clamp SET_DUTY to MAX_DUTY (handles SET_DUTY,0.5 style lines)."""
    s = line.strip()
    if s.upper().startswith("SET_DUTY,"):
        tail = s.split(",", 1)[1] if "," in s else "0"
        d = clamp_duty_str(tail)
        return f"SET_DUTY,{d:.4f}"
    return s


def parse_telem_line(msg: str) -> Optional[Dict[str, Any]]:
    """Parse TELEM from log (optional '<< ' prefix).

    New firmware: TELEM,esp32_ms,rpm,duty,... (12+ fields). Legacy: TELEM,rpm,... (11 fields, no esp32_ms).
    tach/tachAbs/fault and temps are validated on the wire but not returned (CSV omits them).
    """
    s = msg.strip()
    if s.startswith("<< "):
        s = s[3:].strip()
    if not s.upper().startswith("TELEM,"):
        return None
    parts = s.split(",")
    try:
        if len(parts) >= 12:
            esp_ms = int(parts[1])
            for i in (9, 10):
                int(float(parts[i]))
            int(float(parts[11]))
            float(parts[7])
            float(parts[8])
            return {
                "esp_ms": esp_ms,
                "rpm": float(parts[2]),
                "duty": float(parts[3]),
                "vbat": float(parts[4]),
                "i_motor": float(parts[5]),
                "i_in": float(parts[6]),
            }
        if len(parts) >= 11:
            for i in (8, 9):
                int(float(parts[i]))
            int(float(parts[10]))
            float(parts[6])
            float(parts[7])
            return {
                "esp_ms": None,
                "rpm": float(parts[1]),
                "duty": float(parts[2]),
                "vbat": float(parts[3]),
                "i_motor": float(parts[4]),
                "i_in": float(parts[5]),
            }
    except (ValueError, IndexError):
        return None
    return None


def parse_enc_line(msg: str) -> Optional[Dict[str, Any]]:
    """Parse ENC from firmware: ENC,time_ms,count,position_m,velocity_mps (optional '<< ' prefix)."""
    s = msg.strip()
    if s.startswith("<< "):
        s = s[3:].strip()
    if not s.upper().startswith("ENC,"):
        return None
    parts = s.split(",")
    if len(parts) != 5:
        return None
    try:
        return {
            "time_ms": int(parts[1]),
            "count": int(parts[2]),
            "position_m": float(parts[3]),
            "velocity_mps": float(parts[4]),
        }
    except (ValueError, IndexError):
        return None


def is_enc_log_payload(payload: str) -> bool:
    s = payload.strip()
    if s.startswith("<< "):
        s = s[3:].strip()
    return s.upper().startswith("ENC,")


# --------------------------------------------------------------------------
# Serial
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


def list_serial_port_names() -> List[str]:
    return [p.device for p in serial.tools.list_ports.comports()]


def send_serial_line(ser: serial.Serial, cmd: str) -> None:
    ser.write((cmd.strip() + "\n").encode("utf-8"))
    ser.flush()


def wait_for_ready(ser: serial.Serial, timeout: float = READY_TIMEOUT_S, log: Optional[Callable[[str], None]] = None) -> bool:
    log = log or print
    deadline = time.time() + timeout
    while time.time() < deadline:
        if ser.in_waiting:
            line = ser.readline().decode("utf-8", errors="ignore").strip()
            if line:
                log(f"<< {line}")
            if "READY" in line.upper():
                return True
        else:
            time.sleep(0.05)
    return False


class SerialReader(threading.Thread):
    def __init__(self, ser: serial.Serial, line_cb: Callable[[str], None], stop_evt: threading.Event):
        super().__init__(daemon=True)
        self.ser = ser
        self.line_cb = line_cb
        self.stop_evt = stop_evt

    def run(self) -> None:
        while not self.stop_evt.is_set():
            try:
                if self.ser.in_waiting:
                    line = self.ser.readline().decode("utf-8", errors="ignore").strip()
                    if line:
                        self.line_cb(line)
                else:
                    time.sleep(0.02)
            except (serial.SerialException, OSError):
                break


# --------------------------------------------------------------------------
# BLE helpers
# --------------------------------------------------------------------------

def _split_lines(buf: str) -> tuple[List[str], str]:
    lines: List[str] = []
    while True:
        nl = buf.find("\n")
        cr = buf.find("\r")
        if nl < 0 and cr < 0:
            break
        if nl < 0:
            cut = cr
        elif cr < 0:
            cut = nl
        else:
            cut = min(nl, cr)
        line = buf[:cut].strip()
        buf = buf[cut + 1 :]
        if line:
            lines.append(line)
    return lines, buf


async def scan_for_quikburst(
    name: str,
    timeout_s: float,
    log: Callable[[str], None],
) -> Optional[str]:
    from bleak import BleakScanner

    log(f"Scanning {timeout_s:.0f}s for \"{name}\"...")
    finder = getattr(BleakScanner, "find_device_by_name", None)
    if callable(finder):
        dev = await finder(name, timeout=timeout_s)
        if dev:
            log(f"Found: {dev.name!r} @ {dev.address}")
            return dev.address

    devices = await BleakScanner.discover(timeout=timeout_s)
    for d in devices:
        dn = d.name or ""
        if name.lower() in dn.lower() or dn == name:
            log(f"Found: {dn!r} @ {d.address}")
            return d.address

    log("No matching device. Nearby BLE:")
    for d in devices:
        log(f"  {d.address}  name={d.name!r}")
    return None


class BleLineLink:
    def __init__(self) -> None:
        self._buf = ""
        self._queue: asyncio.Queue[str] = asyncio.Queue()

    def on_notify(self, _sender, data: bytearray) -> None:
        self._buf += data.decode("utf-8", errors="ignore")
        lines, self._buf = _split_lines(self._buf)
        for ln in lines:
            self._queue.put_nowait(ln)

    async def get_line(self, timeout: float) -> str:
        return await asyncio.wait_for(self._queue.get(), timeout=timeout)

    async def drain_old(self) -> None:
        while not self._queue.empty():
            try:
                self._queue.get_nowait()
            except Exception:
                break


async def ble_ping_test(client, link: BleLineLink, log: Callable[[str], None]) -> bool:
    await link.drain_old()
    log("Test: sending PING...")
    await client.write_gatt_char(NUS_RX_UUID, b"PING\n", response=False)
    deadline = time.time() + PING_TIMEOUT_S
    while time.time() < deadline:
        try:
            remaining = max(0.1, deadline - time.time())
            line = await link.get_line(timeout=remaining)
            log(f"<< {line}")
            if line.upper().startswith("PONG"):
                log("PING/PONG OK.")
                return True
        except asyncio.TimeoutError:
            break
    log("ERROR: no PONG.")
    return False


# --------------------------------------------------------------------------
# Protocol
# --------------------------------------------------------------------------

HELP_TEXT = """
Commands (USB and BLE):
  PING, SET_CURRENT,<A>, SET_BRAKE,<A>, SET_DUTY,<d> (duty capped at 0.20), SET_RPM,<e>,
  STOP, GET_VALUES, GET_FW, KEEPALIVE, ENC_RESET, ENC_STREAM,<0|1>

Telemetry: the VESC does NOT push TELEM by itself. Each GET_VALUES request returns one TELEM line
(TELEM,esp32_ms,... where esp32_ms is ESP millis when sent — same clock as ENC time_ms). The GUI maps
those device times to a wall timeline (anchor = first sample) so ENC and TELEM align by when they
occurred on the ESP32, not USB receive order. Legacy firmware without esp32_ms still uses host receive time.
Use "Live TELEM poll" (or auto-start after connect) so TELEM and ENC stream together; plots refresh together.

Encoder: firmware streams ENC,time_ms,count,position_m,velocity_mps at 100 Hz over USB and BLE
(same quadrature + 4\" spool geometry as ahaan100/encoder.ino). ENC lines are not copied to the
log (rate). Commands: ENC_RESET (zero), ENC_STREAM,0 | ENC_STREAM,1. CSV position/velocity appear
only on stream=enc rows (TELEM rows leave those columns blank); enable Firmware ENC stream on connect.
Timed CSV: rpm column is spool RPM from ENC linear velocity (same 4\" spool as firmware); near-zero
velocity uses position delta vs host time. TELEM rows repeat the latest ENC spool rpm (VESC eRPM
and fault are not written to CSV). Live plots show VESC eRPM, Vbat, and currents from GET_VALUES
(MOSFET/motor temps are not shown or logged to CSV).

Timed CSV export: with the export checkbox on, any Set current/brake/duty/RPM arms capture.
The Test button always arms CSV for that run (checkbox not required) and sends STOP (zero current),
not SET_DUTY,0 — useful when duty zero still shows sync-rectifier drag. Auto-stop after N>0 s ends
with a CSV; duration 0 + Test still arms CSV until you press STOP (then CSV).

If the motor stops after a few seconds with no auto-stop set, that is usually the VESC
APP / UART timeout — use "Keepalive every (s)" in the GUI or raise the timeout in VESC Tool.
""".strip()


def protocol_line_from_user_input(raw: str) -> str:
    parts = raw.split(None, 1)
    verb = parts[0].upper()
    if verb == "SET_CURRENT" and len(parts) == 2:
        return f"SET_CURRENT,{parts[1]}"
    if verb == "SET_BRAKE" and len(parts) == 2:
        return f"SET_BRAKE,{parts[1]}"
    if verb == "SET_DUTY" and len(parts) == 2:
        d = clamp_duty_str(parts[1])
        return f"SET_DUTY,{d:.4f}"
    if verb == "SET_RPM" and len(parts) == 2:
        return f"SET_RPM,{parts[1]}"
    if verb == "ENC_RESET":
        return "ENC_RESET"
    if verb == "ENC_STREAM" and len(parts) == 2:
        return f"ENC_STREAM,{parts[1].strip()}"
    if verb in ("STOP", "GET_VALUES", "GET_FW", "KEEPALIVE", "PING"):
        return verb
    return raw


# --------------------------------------------------------------------------
# CLI (terminal)
# --------------------------------------------------------------------------

async def interactive_ble_cli(address: str, skip_ping: bool = False) -> None:
    from bleak import BleakClient

    link = BleLineLink()
    print(f"Connecting to {address}...")
    async with BleakClient(address) as client:
        try:
            mtu = await client.exchange_mtu(247)
            print(f"  MTU: {mtu}")
        except Exception:
            pass
        await client.start_notify(NUS_TX_UUID, link.on_notify)
        await asyncio.sleep(0.3)
        if not skip_ping:
            if not await ble_ping_test(client, link, print):
                return
        print()
        print(HELP_TEXT)
        print()
        while True:
            try:
                raw = await asyncio.to_thread(input, "vesc> ")
            except (EOFError, KeyboardInterrupt):
                print("\nDisconnecting — STOP")
                try:
                    await client.write_gatt_char(NUS_RX_UUID, b"STOP\n", response=False)
                except Exception:
                    pass
                break
            raw = raw.strip()
            if not raw:
                continue
            upper = raw.upper()
            if upper in ("QUIT", "EXIT", "Q"):
                try:
                    await client.write_gatt_char(NUS_RX_UUID, b"STOP\n", response=False)
                except Exception:
                    pass
                break
            if upper == "HELP":
                print(HELP_TEXT)
                continue
            line = sanitize_vesc_command_line(protocol_line_from_user_input(raw))
            await client.write_gatt_char(NUS_RX_UUID, (line + "\n").encode("utf-8"), response=False)
            await asyncio.sleep(0.08)
            t_end = time.time() + 2.5
            idle_rounds = 0
            while time.time() < t_end:
                try:
                    resp = await link.get_line(0.2)
                    print(f"  << {resp}")
                    idle_rounds = 0
                except asyncio.TimeoutError:
                    idle_rounds += 1
                    if idle_rounds >= 2:
                        break


def run_ble_mode_cli(name: str, scan_s: float, address: Optional[str], skip_ping: bool) -> None:
    async def _go() -> None:
        addr = address
        if not addr:
            try:
                from bleak import BleakScanner  # noqa: F401
            except ImportError:
                print("BLE requires: pip install bleak")
                sys.exit(1)
            addr = await scan_for_quikburst(name, scan_s, print)
        if not addr:
            sys.exit(1)
        await interactive_ble_cli(addr, skip_ping=skip_ping)

    asyncio.run(_go())


def interactive_serial_cli(ser: serial.Serial) -> None:
    stop = threading.Event()

    def on_line(line: str) -> None:
        print(f"  << {line}")

    reader = SerialReader(ser, on_line, stop)
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
                send_serial_line(ser, "STOP")
                time.sleep(0.2)
                break
            if upper == "HELP":
                print(HELP_TEXT)
                continue
            send_serial_line(ser, sanitize_vesc_command_line(protocol_line_from_user_input(raw)))
            time.sleep(0.15)
    except KeyboardInterrupt:
        print("\nInterrupted — STOP")
        send_serial_line(ser, "STOP")
        time.sleep(0.2)
    finally:
        stop.set()


def serial_ping_test(ser: serial.Serial, log: Callable[[str], None]) -> bool:
    while ser.in_waiting:
        ser.readline()
    log("Test: sending PING...")
    send_serial_line(ser, "PING")
    deadline = time.time() + PING_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            log(f"<< {line}")
        if line.upper().startswith("PONG"):
            log("PING/PONG OK.")
            return True
    log("ERROR: no PONG.")
    return False


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------


class VescControlGui:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("Quikburst VESC Control")
        root.minsize(900, 720)

        self._ui_q: queue.Queue[tuple] = queue.Queue()
        self._ser: Optional[serial.Serial] = None
        self._ser_reader_stop: Optional[threading.Event] = None
        self._ser_reader: Optional[SerialReader] = None

        self._ble_thread: Optional[threading.Thread] = None
        self._ble_cmd_q: queue.Queue = queue.Queue()
        self._ble_running = threading.Event()
        self._ble_ready = threading.Event()
        self.transport = tk.StringVar(value="serial")
        self.status = tk.StringVar(value="Disconnected")
        self.ble_name = tk.StringVar(value="Quikburst")
        self.ble_addr = tk.StringVar(value="")
        self.scan_timeout = tk.DoubleVar(value=12.0)
        self.var_ping = tk.BooleanVar(value=True)
        self.baud = tk.StringVar(value="115200")
        self.var_run_duration_s = tk.DoubleVar(value=5.0)
        self.var_keepalive_s = tk.DoubleVar(value=0.5)
        self.var_export_csv_timed = tk.BooleanVar(value=False)
        self._csv_timed_capture_start: Optional[float] = None
        self._timed_stop_after_id: Optional[str] = None
        self._timed_keepalive_after_id: Optional[str] = None
        self._timed_deadline = 0.0
        self._timed_ka_interval_s = 0.0
        self._timed_run_is_test = False
        # Map ESP32 millis() (ENC time_ms + TELEM esp32_ms) to a wall timeline; reset each session.
        self._session_anchor_wall: Optional[float] = None
        self._session_anchor_esp_ms: Optional[int] = None

        self.var_live_telem = tk.BooleanVar(value=False)
        self.var_auto_live_telem = tk.BooleanVar(value=True)
        self.var_telem_ms = tk.IntVar(value=200)
        self.var_telem_window_s = tk.DoubleVar(value=30.0)
        self._telem_poll_after_id: Optional[str] = None
        # (t_wall, rpm, duty, vbat, i_motor, i_in) — VESC eRPM for live plots only
        self._telem_samples: deque = deque(maxlen=25000)
        self._fig: Any = None
        self._canvas: Any = None
        self._telem_lines: List[Any] = []

        self._enc_samples: deque = deque(maxlen=50000)
        self._fig_enc: Any = None
        self._canvas_enc: Any = None
        self._ln_enc_pos: Any = None
        self._ln_enc_vel: Any = None
        self._enc_axes: Any = None
        self._plots_redraw_after_id: Optional[str] = None
        self.var_enc_stream = tk.BooleanVar(value=True)

        self._build()
        self.root.after(80, self._pump_ui_queue)

    def _build(self) -> None:
        main = ttk.Frame(self.root, padding=8)
        main.pack(fill=tk.BOTH, expand=True)

        outer = ttk.PanedWindow(main, orient=tk.HORIZONTAL)
        outer.pack(fill=tk.BOTH, expand=True)

        left = ttk.Frame(outer)
        outer.add(left, weight=1)
        right = ttk.Frame(outer)
        outer.add(right, weight=1)

        conn = ttk.LabelFrame(left, text="Connection", padding=8)
        conn.pack(fill=tk.X, pady=(0, 8))

        ttk.Radiobutton(conn, text="USB Serial", variable=self.transport, value="serial").grid(row=0, column=0, sticky=tk.W)
        ttk.Radiobutton(conn, text="Bluetooth LE (Quikburst)", variable=self.transport, value="ble").grid(row=0, column=1, sticky=tk.W, padx=(16, 0))

        ser_row = ttk.Frame(conn)
        ser_row.grid(row=1, column=0, columnspan=4, sticky=tk.EW, pady=(8, 0))
        ttk.Label(ser_row, text="Port:").pack(side=tk.LEFT)
        self.port_combo = ttk.Combobox(ser_row, width=14, state="readonly")
        self.port_combo.pack(side=tk.LEFT, padx=(4, 4))
        ttk.Button(ser_row, text="Refresh", command=self._refresh_ports).pack(side=tk.LEFT)
        ttk.Label(ser_row, text="Baud:").pack(side=tk.LEFT, padx=(12, 0))
        ttk.Combobox(ser_row, textvariable=self.baud, width=8, values=("115200", "921600", "57600", "9600")).pack(side=tk.LEFT, padx=(4, 0))

        ble_row = ttk.Frame(conn)
        ble_row.grid(row=2, column=0, columnspan=4, sticky=tk.EW, pady=(6, 0))
        ttk.Label(ble_row, text="BLE name:").pack(side=tk.LEFT)
        ttk.Entry(ble_row, textvariable=self.ble_name, width=18).pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(ble_row, text="Address (optional):").pack(side=tk.LEFT)
        ttk.Entry(ble_row, textvariable=self.ble_addr, width=22).pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(ble_row, text="Scan s:").pack(side=tk.LEFT)
        ttk.Spinbox(ble_row, from_=3, to=60, textvariable=self.scan_timeout, width=5).pack(side=tk.LEFT, padx=(4, 0))

        opt_row = ttk.Frame(conn)
        opt_row.grid(row=3, column=0, columnspan=4, sticky=tk.W, pady=(8, 0))
        ttk.Checkbutton(opt_row, text="PING test after connect", variable=self.var_ping).pack(side=tk.LEFT)

        btn_row = ttk.Frame(conn)
        btn_row.grid(row=4, column=0, columnspan=4, sticky=tk.W, pady=(10, 0))
        self.btn_connect = ttk.Button(btn_row, text="Connect", command=self._on_connect)
        self.btn_connect.pack(side=tk.LEFT, padx=(0, 8))
        self.btn_disconnect = ttk.Button(btn_row, text="Disconnect", command=self._on_disconnect, state=tk.DISABLED)
        self.btn_disconnect.pack(side=tk.LEFT)

        ttk.Label(conn, textvariable=self.status, foreground="#0a5").grid(row=5, column=0, columnspan=4, sticky=tk.W, pady=(8, 0))

        cmd_fr = ttk.LabelFrame(left, text="Commands (same protocol as firmware)", padding=8)
        cmd_fr.pack(fill=tk.X, pady=(0, 8))

        self.cmd_widgets: List[tk.Widget] = []

        time_fr = ttk.LabelFrame(
            cmd_fr,
            text="Timed motor output (Set current / brake / duty / RPM, Test, matching raw motor lines)",
            padding=6,
        )
        time_fr.grid(row=0, column=0, columnspan=4, sticky=tk.EW, pady=(0, 8))
        ttk.Label(time_fr, text="Auto-stop after (s), 0 = until STOP:").grid(row=0, column=0, sticky=tk.W)
        sb_dur = ttk.Spinbox(time_fr, from_=0, to=600, increment=1, textvariable=self.var_run_duration_s, width=8)
        sb_dur.grid(row=0, column=1, padx=(4, 20), sticky=tk.W)
        ttk.Label(time_fr, text="Keepalive every (s), 0 = off:").grid(row=0, column=2, sticky=tk.W)
        sb_ka = ttk.Spinbox(time_fr, from_=0, to=30, increment=0.5, textvariable=self.var_keepalive_s, width=8)
        sb_ka.grid(row=0, column=3, padx=(4, 0), sticky=tk.W)
        ttk.Label(
            time_fr,
            text="Short runouts are usually VESC APP/UART timeout — keepalive 0.5–2s helps. Cap is host + firmware.",
            font=("TkDefaultFont", 8),
            foreground="#444",
        ).grid(row=1, column=0, columnspan=4, sticky=tk.W, pady=(6, 0))
        ttk.Checkbutton(
            time_fr,
            text="Export TELEM + encoder to CSV (motor commands + Test; N>0 s → auto STOP+CSV; N=0 → CSV on STOP)",
            variable=self.var_export_csv_timed,
        ).grid(row=2, column=0, columnspan=4, sticky=tk.W, pady=(8, 0))

        def row_param(r: int, label: str, var: tk.StringVar, btn_text: str, proto_prefix: str) -> None:
            ttk.Label(cmd_fr, text=label).grid(row=r, column=0, sticky=tk.W, pady=2)
            e = ttk.Entry(cmd_fr, textvariable=var, width=14)
            e.grid(row=r, column=1, sticky=tk.W, padx=(4, 8), pady=2)
            b = ttk.Button(
                cmd_fr,
                text=btn_text,
                command=lambda p=proto_prefix, v=var: self._send_motor_param(p, v.get()),
            )
            b.grid(row=r, column=2, sticky=tk.W, pady=2)
            self.cmd_widgets.extend([e, b])

        self.var_cur = tk.StringVar(value="0")
        self.var_brk = tk.StringVar(value="0")
        self.var_duty = tk.StringVar(value="0")
        self.var_rpm = tk.StringVar(value="0")

        self.cmd_widgets.extend([sb_dur, sb_ka])

        row_param(3, "Current (A)", self.var_cur, "Set current", "SET_CURRENT")
        row_param(4, "Brake (A)", self.var_brk, "Set brake", "SET_BRAKE")
        row_param(5, f"Duty (0–{MAX_DUTY:.2f} max)", self.var_duty, "Set duty", "SET_DUTY")
        row_param(6, "eRPM", self.var_rpm, "Set RPM", "SET_RPM")

        quick = ttk.Frame(cmd_fr)
        quick.grid(row=7, column=0, columnspan=3, sticky=tk.W, pady=(10, 0))
        b_stop = ttk.Button(quick, text="STOP", command=lambda: self._send_wire("STOP"))
        b_stop.pack(side=tk.LEFT, padx=(0, 6))
        self.cmd_widgets.append(b_stop)
        btn_test = ttk.Button(quick, text="Test", command=self._on_test_freewheel_record)
        btn_test.pack(side=tk.LEFT, padx=(0, 6))
        self.cmd_widgets.append(btn_test)
        for text, wire in (
            ("GET_VALUES", "GET_VALUES"),
            ("GET_FW", "GET_FW"),
            ("KEEPALIVE", "KEEPALIVE"),
            ("PING", "PING"),
        ):
            b = ttk.Button(quick, text=text, command=lambda w=wire: self._send_wire(w))
            b.pack(side=tk.LEFT, padx=(0, 6))
            self.cmd_widgets.append(b)
        ttk.Button(quick, text="Help", command=lambda: messagebox.showinfo("Commands", HELP_TEXT)).pack(side=tk.LEFT, padx=(12, 0))

        raw_fr = ttk.Frame(cmd_fr)
        raw_fr.grid(row=8, column=0, columnspan=3, sticky=tk.EW, pady=(10, 0))
        ttk.Label(raw_fr, text="Raw line:").pack(side=tk.LEFT)
        self.raw_entry = ttk.Entry(raw_fr, width=40)
        self.raw_entry.pack(side=tk.LEFT, padx=(4, 8), fill=tk.X, expand=True)
        self.btn_send_raw = ttk.Button(raw_fr, text="Send", command=self._send_raw)
        self.btn_send_raw.pack(side=tk.LEFT)
        self.cmd_widgets.extend([self.raw_entry, self.btn_send_raw])

        log_fr = ttk.LabelFrame(left, text="Log", padding=4)
        log_fr.pack(fill=tk.BOTH, expand=True)
        self.log_text = scrolledtext.ScrolledText(log_fr, height=12, state=tk.DISABLED, wrap=tk.WORD, font=("Consolas", 9))
        self.log_text.pack(fill=tk.BOTH, expand=True)
        ttk.Button(log_fr, text="Clear log", command=self._clear_log).pack(anchor=tk.E, pady=(4, 0))

        telem_row = ttk.LabelFrame(
            right,
            text="Live TELEM + plots (GET_VALUES poll; refreshed together with encoder graphs)",
            padding=6,
        )
        telem_row.pack(fill=tk.X, pady=(0, 8))
        ttk.Checkbutton(
            telem_row,
            text="Live poll",
            variable=self.var_live_telem,
            command=self._on_live_telem_toggle,
        ).pack(side=tk.LEFT)
        ttk.Label(telem_row, text="every (ms):").pack(side=tk.LEFT, padx=(8, 0))
        sb_telem_ms = ttk.Spinbox(telem_row, from_=50, to=5000, increment=50, textvariable=self.var_telem_ms, width=6)
        sb_telem_ms.pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(telem_row, text="X-axis window (s):").pack(side=tk.LEFT)
        sb_telem_win = ttk.Spinbox(telem_row, from_=5, to=600, increment=5, textvariable=self.var_telem_window_s, width=6)
        sb_telem_win.pack(side=tk.LEFT, padx=(4, 12))
        ttk.Button(telem_row, text="Apply window", command=self._apply_graph_windows).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(telem_row, text="Clear graph data", command=self._clear_telem_data).pack(side=tk.LEFT)
        self.cmd_widgets.extend([sb_telem_ms, sb_telem_win])
        ttk.Checkbutton(
            telem_row,
            text="Auto-start live poll after connect",
            variable=self.var_auto_live_telem,
        ).pack(side=tk.LEFT, padx=(12, 0))

        enc_row = ttk.LabelFrame(
            right,
            text="Encoder (linear m — same as ahaan100/encoder.ino; pushed ~100 Hz, not shown in log)",
            padding=6,
        )
        enc_row.pack(fill=tk.X, pady=(0, 8))
        ttk.Button(enc_row, text="ENC zero", command=lambda: self._send_line("ENC_RESET")).pack(side=tk.LEFT)
        ttk.Checkbutton(
            enc_row,
            text="Firmware ENC stream",
            variable=self.var_enc_stream,
            command=self._on_enc_stream_toggle,
        ).pack(side=tk.LEFT, padx=(12, 0))
        ttk.Button(enc_row, text="Clear encoder graph", command=self._clear_enc_data).pack(side=tk.LEFT, padx=(12, 0))

        graph_fr = ttk.LabelFrame(
            right,
            text="TELEM + encoder position vs time (encoder on top; same window)",
            padding=4,
        )
        graph_fr.pack(fill=tk.BOTH, expand=True)
        self._graph_inner = ttk.Frame(graph_fr)
        self._graph_inner.pack(fill=tk.BOTH, expand=True)
        self._build_telem_matplotlib(self._graph_inner)

        enc_graph_fr = ttk.LabelFrame(right, text="Encoder position / velocity vs time (same window as TELEM)", padding=4)
        enc_graph_fr.pack(fill=tk.BOTH, expand=True)
        self._enc_graph_inner = ttk.Frame(enc_graph_fr)
        self._enc_graph_inner.pack(fill=tk.BOTH, expand=True)
        self._build_enc_matplotlib(self._enc_graph_inner)

        self._refresh_ports()
        self._set_commands_enabled(False)

    def _refresh_ports(self) -> None:
        ports = list_serial_port_names()
        self.port_combo["values"] = ports
        if ports:
            guess = find_serial_port()
            self.port_combo.set(guess if guess in ports else ports[0])
        else:
            self.port_combo.set("")

    def _log(self, msg: str) -> None:
        self._ui_q.put(("log", msg))

    def _set_status(self, s: str) -> None:
        self._ui_q.put(("status", s))

    def _append_log_safe(self, msg: str) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.insert(tk.END, msg + "\n")
        self.log_text.see(tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _clear_log(self) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _build_telem_matplotlib(self, parent: ttk.Frame) -> None:
        try:
            from matplotlib.figure import Figure
            from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
        except ImportError:
            ttk.Label(
                parent,
                text="Install matplotlib for the live graph:\n  pip install matplotlib",
                justify=tk.CENTER,
            ).pack(expand=True)
            return

        self._fig = Figure(figsize=(5.5, 6.8), constrained_layout=True)
        ax0 = self._fig.add_subplot(4, 1, 1)
        ax1 = self._fig.add_subplot(4, 1, 2, sharex=ax0)
        ax2 = self._fig.add_subplot(4, 1, 3, sharex=ax0)
        ax3 = self._fig.add_subplot(4, 1, 4, sharex=ax0)
        ax0.set_ylabel("Pos (m)")
        ax1.set_ylabel("RPM")
        ax2.set_ylabel("Vbat")
        ax3.set_ylabel("A")
        ax3.set_xlabel("Time in window (s)")
        (self._ln_telem_enc_pos,) = ax0.plot([], [], color="tab:green", lw=1.2)
        (self._ln_rpm,) = ax1.plot([], [], color="tab:blue", lw=1)
        (self._ln_v,) = ax2.plot([], [], "g-", lw=1)
        (self._ln_im,) = ax3.plot([], [], "r-", lw=1, label="I motor")
        (self._ln_iin,) = ax3.plot([], [], "m-", lw=1, label="I in")
        ax3.legend(loc="upper right", fontsize=7)
        self._telem_axes = (ax0, ax1, ax2, ax3)

        self._canvas = FigureCanvasTkAgg(self._fig, master=parent)
        self._canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)

    def _build_enc_matplotlib(self, parent: ttk.Frame) -> None:
        try:
            from matplotlib.figure import Figure
            from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
        except ImportError:
            ttk.Label(
                parent,
                text="Install matplotlib for encoder plots:\n  pip install matplotlib",
                justify=tk.CENTER,
            ).pack(expand=True)
            return

        self._fig_enc = Figure(figsize=(5.5, 3.2), constrained_layout=True)
        axp = self._fig_enc.add_subplot(2, 1, 1)
        axv = self._fig_enc.add_subplot(2, 1, 2, sharex=axp)
        axp.set_ylabel("Position (m)")
        axv.set_ylabel("Velocity (m/s)")
        axv.set_xlabel("Time in window (s)")
        (self._ln_enc_pos,) = axp.plot([], [], color="tab:blue", lw=1)
        (self._ln_enc_vel,) = axv.plot([], [], color="tab:purple", lw=1)
        self._enc_axes = (axp, axv)

        self._canvas_enc = FigureCanvasTkAgg(self._fig_enc, master=parent)
        self._canvas_enc.get_tk_widget().pack(fill=tk.BOTH, expand=True)

    def _apply_graph_windows(self) -> None:
        self._redraw_telem_plot()
        self._redraw_enc_plot()

    def _clear_telem_data(self) -> None:
        self._telem_samples.clear()
        self._redraw_telem_plot()
        self._redraw_enc_plot()

    def _schedule_live_plots_redraw(self) -> None:
        if self._plots_redraw_after_id is not None:
            return
        self._plots_redraw_after_id = self.root.after(LIVE_PLOTS_REDRAW_MS, self._live_plots_redraw_tick)

    def _live_plots_redraw_tick(self) -> None:
        self._plots_redraw_after_id = None
        self._redraw_telem_plot()
        self._redraw_enc_plot()

    def _reset_device_time_anchor(self) -> None:
        self._session_anchor_wall = None
        self._session_anchor_esp_ms = None

    def _wall_from_esp_millis(self, esp_ms: int) -> float:
        """Convert ESP32 millis to a wall clock — anchor first seen sample to time.time(), then add delta."""
        e = int(esp_ms) & 0xFFFFFFFF
        if self._session_anchor_wall is None:
            self._session_anchor_wall = time.time()
            self._session_anchor_esp_ms = e
            return self._session_anchor_wall
        a = int(self._session_anchor_esp_ms) & 0xFFFFFFFF
        delta = (e - a) & 0xFFFFFFFF
        if delta >= 0x80000000:
            delta -= 0x100000000
        return float(self._session_anchor_wall) + delta / 1000.0

    def _feed_telem_from_log_line(self, payload: str) -> None:
        d = parse_telem_line(payload)
        if d is None:
            return
        esp = d.get("esp_ms")
        tw = self._wall_from_esp_millis(int(esp)) if esp is not None else time.time()
        self._telem_samples.append(
            (
                tw,
                d["rpm"],
                d["duty"],
                d["vbat"],
                d["i_motor"],
                d["i_in"],
            )
        )
        self._schedule_live_plots_redraw()

    def _redraw_telem_plot(self) -> None:
        if self._fig is None or self._canvas is None or not hasattr(self, "_ln_rpm"):
            return
        try:
            tw = max(1.0, float(self.var_telem_window_s.get()))
        except (tk.TclError, ValueError):
            tw = 30.0
        t_end = time.time()
        t_start = t_end - tw
        xs: List[float] = []
        rpm_l: List[float] = []
        v_l: List[float] = []
        im_l: List[float] = []
        iin_l: List[float] = []
        for row in self._telem_samples:
            t_wall, rpm, _duty, vb, imo, i_i = row[:6]
            if t_wall < t_start:
                continue
            xs.append(t_wall - t_start)
            rpm_l.append(rpm)
            v_l.append(vb)
            im_l.append(imo)
            iin_l.append(i_i)

        enc_x: List[float] = []
        enc_pos: List[float] = []
        for row in self._enc_samples:
            t_wall = row[0]
            if t_wall < t_start:
                continue
            enc_x.append(t_wall - t_start)
            enc_pos.append(row[1])

        if hasattr(self, "_ln_telem_enc_pos"):
            self._ln_telem_enc_pos.set_data(enc_x, enc_pos)

        self._ln_rpm.set_data(xs, rpm_l)
        self._ln_v.set_data(xs, v_l)
        self._ln_im.set_data(xs, im_l)
        self._ln_iin.set_data(xs, iin_l)

        self._telem_axes[0].set_xlim(0.0, tw)
        has_telem = bool(xs)
        has_enc = bool(enc_x)
        if has_telem or has_enc:
            for ax in self._telem_axes:
                ax.relim()
                ax.autoscale_view(scalex=False)
            self._telem_axes[0].set_xlim(0.0, tw)
        self._canvas.draw_idle()

    def _clear_enc_data(self) -> None:
        self._enc_samples.clear()
        self._redraw_telem_plot()
        self._redraw_enc_plot()

    @staticmethod
    def _timed_captures_dir() -> str:
        return os.path.join(os.path.dirname(os.path.abspath(__file__)), "timed_captures")

    def _flush_pending_log_lines_to_samples(self) -> None:
        """Move ('log',) items from the UI queue into TELEM/ENC deques (main thread only).

        Inbound lines are queued for the log pane; ENC is skipped in the text log but must still
        be fed here. If we export CSV before the periodic pump runs, rows can sit in the queue and
        never reach _enc_samples — this removes that gap (common on timed auto-stop).
        """
        deferred: List[Tuple[str, Any]] = []
        try:
            while True:
                item = self._ui_q.get_nowait()
                if item[0] == "log":
                    payload = item[1]
                    if not is_enc_log_payload(payload):
                        self._append_log_safe(payload)
                    self._feed_telem_from_log_line(payload)
                    self._feed_enc_from_log_line(payload)
                else:
                    deferred.append(item)
        except queue.Empty:
            pass
        for item in deferred:
            self._ui_q.put(item)

    def _export_timed_run_csv(self, t_end: float, reason: str) -> None:
        """Write TELEM + ENC rows between capture start and t_end (timestamps = ESP32-based wall mapping when available)."""
        self._flush_pending_log_lines_to_samples()
        t_end = max(t_end, time.time())
        t0 = self._csv_timed_capture_start
        if t0 is None:
            if reason == "timed_stop":
                self._log(
                    "CSV export skipped: no capture window was armed (timed run ended). "
                    "Use Test for always-on CSV, or enable Export + a motor command."
                )
            return
        self._csv_timed_capture_start = None

        rows_out: List[Tuple[float, Dict[str, Any]]] = []
        for row in self._telem_samples:
            tw = row[0]
            if not (t0 <= tw <= t_end):
                continue
            _erpm, duty, vb, imo, i_i = row[1:6]
            rows_out.append(
                (
                    tw,
                    {
                        "host_unix_s": tw,
                        "t_rel_s": tw - t0,
                        "stream": "telem",
                        "rpm": "",
                        "duty": duty,
                        "vbat": vb,
                        "i_motor": imo,
                        "i_in": i_i,
                        "enc_millis": "",
                        "enc_count": "",
                        "position_m": "",
                        "velocity_mps": "",
                    },
                )
            )
        for row in self._enc_samples:
            tw = row[0]
            if not (t0 <= tw <= t_end):
                continue
            pos_m, vel_mps, count, enc_ms = row[1], row[2], row[3], row[4]
            rows_out.append(
                (
                    tw,
                    {
                        "host_unix_s": tw,
                        "t_rel_s": tw - t0,
                        "stream": "enc",
                        "rpm": 0.0,
                        "duty": "",
                        "vbat": "",
                        "i_motor": "",
                        "i_in": "",
                        "enc_millis": enc_ms,
                        "enc_count": count,
                        "position_m": pos_m,
                        "velocity_mps": vel_mps,
                    },
                )
            )

        rows_out.sort(key=lambda x: x[0])
        enc_rows = [(tw, d) for tw, d in rows_out if d.get("stream") == "enc"]
        prev_tw: Optional[float] = None
        prev_pos: Optional[float] = None
        for tw, d in enc_rows:
            pos_m = float(d["position_m"])
            vel_mps = float(d["velocity_mps"])
            rpm_spool = _spool_rpm_from_linear_velocity_mps(vel_mps)
            if abs(vel_mps) < 1e-5 and prev_tw is not None and prev_pos is not None:
                rpm_spool = _spool_rpm_from_position_delta(pos_m, prev_pos, tw, prev_tw)
            d["rpm"] = rpm_spool
            prev_tw, prev_pos = tw, pos_m

        last_enc_rpm: Optional[float] = None
        for tw, d in rows_out:
            if d.get("stream") == "enc":
                last_enc_rpm = float(d["rpm"])
            elif d.get("stream") == "telem" and last_enc_rpm is not None:
                d["rpm"] = last_enc_rpm
        n_telem = sum(1 for _tw, d in rows_out if d.get("stream") == "telem")
        n_enc = sum(1 for _tw, d in rows_out if d.get("stream") == "enc")
        out_dir = self._timed_captures_dir()
        os.makedirs(out_dir, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_reason = "".join(c if c.isalnum() or c in "-_" else "_" for c in reason)[:40]
        path = os.path.join(out_dir, f"timed_run_{stamp}_{safe_reason}.csv")
        fieldnames = [
            "host_unix_s",
            "t_rel_s",
            "stream",
            "rpm",
            "duty",
            "vbat",
            "i_motor",
            "i_in",
            "enc_millis",
            "enc_count",
            "position_m",
            "velocity_mps",
        ]
        try:
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=fieldnames)
                w.writeheader()
                for _tw, d in rows_out:
                    w.writerow(d)
        except OSError as e:
            self._log(f"CSV export failed: {e}")
            return

        n = len(rows_out)
        self._log(f"CSV export ({reason}): {n} rows ({n_telem} telem + {n_enc} enc) → {path}")
        if n_telem > 0 and n_enc == 0:
            self._log(
                "(CSV: no enc rows in window — turn on Firmware ENC stream, keep Live TELEM poll on; "
                "position_m is only on stream=enc rows.)"
            )
        elif n_enc > 0:
            self._log(
                "(CSV: rpm = spool RPM from ENC velocity / 4 in circumference; TELEM rows use last ENC rpm.)"
            )

    def _feed_enc_from_log_line(self, payload: str) -> None:
        d = parse_enc_line(payload)
        if d is None:
            return
        tw = self._wall_from_esp_millis(int(d["time_ms"]))
        self._enc_samples.append(
            (
                tw,
                d["position_m"],
                d["velocity_mps"],
                d["count"],
                d["time_ms"],
            )
        )
        self._schedule_live_plots_redraw()

    def _redraw_enc_plot(self) -> None:
        if self._fig_enc is None or self._canvas_enc is None or self._ln_enc_pos is None:
            return
        try:
            tw = max(1.0, float(self.var_telem_window_s.get()))
        except (tk.TclError, ValueError):
            tw = 30.0
        t_end = time.time()
        t_start = t_end - tw
        xs: List[float] = []
        pos_l: List[float] = []
        vel_l: List[float] = []
        for row in self._enc_samples:
            t_wall, pos_m, vel_mps = row[:3]
            if t_wall < t_start:
                continue
            xs.append(t_wall - t_start)
            pos_l.append(pos_m)
            vel_l.append(vel_mps)

        self._ln_enc_pos.set_data(xs, pos_l)
        self._ln_enc_vel.set_data(xs, vel_l)

        assert self._enc_axes is not None
        self._enc_axes[0].set_xlim(0.0, tw)
        if xs:
            for ax in self._enc_axes:
                ax.relim()
                ax.autoscale_view(scalex=False)
            self._enc_axes[0].set_xlim(0.0, tw)
        self._canvas_enc.draw_idle()

    def _on_enc_stream_toggle(self) -> None:
        if not self._is_connected():
            return
        self._sync_enc_stream_to_firmware()

    def _sync_enc_stream_to_firmware(self) -> None:
        if not self._is_connected():
            return
        on = 1 if self.var_enc_stream.get() else 0
        self._send_line(f"ENC_STREAM,{on}")

    def _is_connected(self) -> bool:
        return self._ser is not None or (
            self._ble_thread is not None
            and self._ble_thread.is_alive()
            and self._ble_ready.is_set()
        )

    def _stop_telem_polling(self) -> None:
        if self._telem_poll_after_id is not None:
            try:
                self.root.after_cancel(self._telem_poll_after_id)
            except Exception:
                pass
            self._telem_poll_after_id = None

    def _telem_poll_tick(self) -> None:
        self._telem_poll_after_id = None
        if not self.var_live_telem.get():
            return
        if not self._is_connected():
            self.var_live_telem.set(False)
            return
        self._send_line("GET_VALUES")
        try:
            ms = max(50, int(self.var_telem_ms.get()))
        except (tk.TclError, ValueError):
            ms = 200
        self._telem_poll_after_id = self.root.after(ms, self._telem_poll_tick)

    def _start_telem_polling(self) -> None:
        self._stop_telem_polling()
        if not self._is_connected():
            self.var_live_telem.set(False)
            messagebox.showinfo("Live TELEM", "Connect to the ESP32 first.")
            return
        self._telem_poll_tick()

    def _on_live_telem_toggle(self) -> None:
        if self.var_live_telem.get():
            self._start_telem_polling()
        else:
            self._stop_telem_polling()

    def _try_auto_start_live_telem(self) -> None:
        if not self.var_auto_live_telem.get():
            return
        if not self._is_connected():
            return
        self.var_live_telem.set(True)
        self._start_telem_polling()
        self._log("(Auto-started live TELEM poll — use with ENC stream for combined live plots + CSV)")

    def _pump_ui_queue(self) -> None:
        try:
            while True:
                kind, payload = self._ui_q.get_nowait()
                if kind == "log":
                    if not is_enc_log_payload(payload):
                        self._append_log_safe(payload)
                    self._feed_telem_from_log_line(payload)
                    self._feed_enc_from_log_line(payload)
                elif kind == "status":
                    self.status.set(payload)
                elif kind == "connected":
                    self._reset_device_time_anchor()
                    self._apply_connected_state(True)
                elif kind == "post_connect_enc":
                    self._sync_enc_stream_to_firmware()
                    self.root.after(350, self._try_auto_start_live_telem)
                elif kind == "disconnected":
                    self._reset_device_time_anchor()
                    self._csv_timed_capture_start = None
                    self._cancel_timed_run()
                    self._stop_telem_polling()
                    self.var_live_telem.set(False)
                    if self._plots_redraw_after_id is not None:
                        try:
                            self.root.after_cancel(self._plots_redraw_after_id)
                        except Exception:
                            pass
                        self._plots_redraw_after_id = None
                    self.status.set("Disconnected")
                    self._apply_connected_state(False)
                elif kind == "errorbox":
                    messagebox.showerror("Error", payload)
        except queue.Empty:
            pass
        self.root.after(80, self._pump_ui_queue)

    def _apply_connected_state(self, connected: bool) -> None:
        self.btn_connect.configure(state=tk.DISABLED if connected else tk.NORMAL)
        self.btn_disconnect.configure(state=tk.NORMAL if connected else tk.DISABLED)
        self._set_commands_enabled(connected)

    def _set_commands_enabled(self, en: bool) -> None:
        state = tk.NORMAL if en else tk.DISABLED
        for w in self.cmd_widgets:
            try:
                if isinstance(w, (ttk.Entry, ttk.Spinbox)):
                    w.configure(state=state if en else tk.DISABLED)
                elif isinstance(w, ttk.Button):
                    w.configure(state=state)
            except tk.TclError:
                pass

    def _cancel_timed_run(self) -> None:
        if self._timed_stop_after_id is not None:
            try:
                self.root.after_cancel(self._timed_stop_after_id)
            except Exception:
                pass
            self._timed_stop_after_id = None
        if self._timed_keepalive_after_id is not None:
            try:
                self.root.after_cancel(self._timed_keepalive_after_id)
            except Exception:
                pass
            self._timed_keepalive_after_id = None
        self._timed_deadline = 0.0
        self._timed_ka_interval_s = 0.0
        self._timed_run_is_test = False

    def _schedule_timed_run(self, duration_s: float, keepalive_interval_s: float) -> None:
        self._cancel_timed_run()
        if duration_s <= 0:
            return
        self._timed_deadline = time.time() + duration_s
        self._timed_ka_interval_s = max(0.0, keepalive_interval_s)
        dur_ms = int(max(0.05, duration_s) * 1000)
        self._timed_stop_after_id = self.root.after(dur_ms, self._timed_run_fire_stop)
        if self._timed_ka_interval_s > 0:
            ka_ms = max(200, int(self._timed_ka_interval_s * 1000))
            self._timed_keepalive_after_id = self.root.after(ka_ms, self._timed_run_keepalive_tick)
            self._log(
                f"(Timed: STOP in {duration_s:.1f}s; KEEPALIVE every {self._timed_ka_interval_s:.1f}s)"
            )
        else:
            self._log(f"(Timed: STOP in {duration_s:.1f}s; no keepalive)")

    def _timed_run_fire_stop(self) -> None:
        self._timed_stop_after_id = None
        if self._timed_keepalive_after_id is not None:
            try:
                self.root.after_cancel(self._timed_keepalive_after_id)
            except Exception:
                pass
            self._timed_keepalive_after_id = None
        self._timed_deadline = 0.0
        self._timed_ka_interval_s = 0.0
        t_end = time.time()
        reason = "test_stop" if self._timed_run_is_test else "timed_stop"
        self._timed_run_is_test = False
        self._export_timed_run_csv(t_end, reason)
        self._send_line("STOP")
        self._log("(Timed run: sent STOP)")

    def _timed_run_keepalive_tick(self) -> None:
        self._timed_keepalive_after_id = None
        if self._timed_deadline <= 0 or time.time() >= self._timed_deadline:
            return
        self._send_line("KEEPALIVE")
        if time.time() < self._timed_deadline and self._timed_ka_interval_s > 0:
            ka_ms = max(200, int(self._timed_ka_interval_s * 1000))
            self._timed_keepalive_after_id = self.root.after(ka_ms, self._timed_run_keepalive_tick)

    @staticmethod
    def _line_starts_motor_set(line: str) -> bool:
        u = line.strip().upper()
        return (
            u.startswith("SET_CURRENT,")
            or u.startswith("SET_BRAKE,")
            or u.startswith("SET_DUTY,")
            or u.startswith("SET_RPM,")
        )

    def _maybe_arm_timed_run(self, *, force_csv: bool = False, from_test: bool = False) -> None:
        try:
            dur = float(self.var_run_duration_s.get())
        except (tk.TclError, ValueError):
            dur = 0.0
        try:
            ka = float(self.var_keepalive_s.get())
        except (tk.TclError, ValueError):
            ka = 0.0
        if self.var_export_csv_timed.get() or force_csv:
            self._csv_timed_capture_start = time.time()
        else:
            self._csv_timed_capture_start = None
        if dur > 0:
            self._schedule_timed_run(dur, max(0.0, ka))
        else:
            self._cancel_timed_run()
        # After schedule (its internal cancel must not wipe this): mark Test runs for CSV filename/reason.
        self._timed_run_is_test = bool(from_test and dur > 0)

    def _on_test_freewheel_record(self) -> None:
        """Timed CSV/keepalive like motor sets, but command STOP (0 A) instead of SET_DUTY,0."""
        if not self._is_connected():
            messagebox.showwarning("Not connected", "Connect over USB or BLE first.")
            return
        self._maybe_arm_timed_run(force_csv=True, from_test=True)
        self._send_line("STOP")
        self._log(
            "(Test: STOP + CSV always armed for this run (Export checkbox not required); "
            "enable Live TELEM poll for VESC rows in the file)"
        )

    def _send_motor_param(self, prefix: str, value: str) -> None:
        val = value.strip()
        if prefix == "SET_DUTY":
            val = f"{clamp_duty_str(val):.4f}"
        line = f"{prefix},{val}"
        self._maybe_arm_timed_run()
        self._send_line(line)

    def _on_connect(self) -> None:
        self.btn_connect.configure(state=tk.DISABLED)
        if self.transport.get() == "serial":

            def run_serial() -> None:
                try:
                    self._thread_serial_connect()
                except Exception as e:
                    self._ui_q.put(("log", f"USB connect thread error: {e}"))
                    self._set_status("Disconnected")
                    self._ui_q.put(("disconnected", None))

            threading.Thread(target=run_serial, daemon=True).start()
        else:
            threading.Thread(target=self._thread_ble_connect, daemon=True).start()

    def _thread_serial_connect(self) -> None:
        port = self.port_combo.get().strip()
        if not port:
            self._ui_q.put(("errorbox", "Select a serial port."))
            self._ui_q.put(("disconnected", None))
            return
        try:
            baud = int(self.baud.get())
        except ValueError:
            self._ui_q.put(("errorbox", "Invalid baud rate."))
            self._ui_q.put(("disconnected", None))
            return
        self._set_status("Connecting (USB)...")
        ser: Optional[serial.Serial] = None
        try:
            ser = serial.Serial(port, baud, timeout=0.5)
        except serial.SerialException as e:
            self._ui_q.put(("log", f"Open failed: {e}"))
            self._set_status("Disconnected")
            self._ui_q.put(("errorbox", str(e)))
            self._ui_q.put(("disconnected", None))
            return

        try:
            self._log(f"Opened {port} @ {baud}")
            self._log("Waiting for READY...")
            if not wait_for_ready(ser, READY_TIMEOUT_S, log=lambda m: self._log(m)):
                self._log("(No READY — continuing)")
            time.sleep(0.2)
            while ser.in_waiting:
                ser.readline()
            if self.var_ping.get():
                serial_ping_test(ser, log=lambda m: self._log(m))

            stop = threading.Event()

            def on_line(line: str) -> None:
                self._log(f"<< {line}")

            self._ser = ser
            self._ser_reader_stop = stop
            self._ser_reader = SerialReader(ser, on_line, stop)
            self._ser_reader.start()
            ser = None
            self._set_status(f"Connected: {port}")
            self._ui_q.put(("connected", None))
            self._ui_q.put(("post_connect_enc", None))
        except Exception as e:
            self._ui_q.put(("log", f"USB connect failed: {e}"))
            self._ui_q.put(("errorbox", str(e)))
            if self._ser_reader_stop is not None:
                self._ser_reader_stop.set()
            self._ser_reader = None
            self._ser_reader_stop = None
            if self._ser is not None:
                try:
                    self._ser.close()
                except Exception:
                    pass
                self._ser = None
            if ser is not None:
                try:
                    ser.close()
                except Exception:
                    pass
            self._set_status("Disconnected")
            self._ui_q.put(("disconnected", None))

    def _thread_ble_connect(self) -> None:
        try:
            import bleak  # noqa: F401
        except ImportError:
            self._ui_q.put(("errorbox", "Install bleak: pip install bleak"))
            self._set_status("Disconnected")
            self._ui_q.put(("disconnected", None))
            return

        name = self.ble_name.get().strip() or "Quikburst"
        addr_manual = self.ble_addr.get().strip()
        scan_s = float(self.scan_timeout.get())

        def run_async() -> None:
            asyncio.run(self._ble_async_main(name, addr_manual, scan_s))

        self._ble_ready.clear()
        self._set_status("BLE: scanning / connecting...")
        self._ble_thread = threading.Thread(target=run_async, daemon=True)
        self._ble_thread.start()

    async def _ble_async_main(self, name: str, addr_manual: str, scan_s: float) -> None:
        from bleak import BleakClient

        def log(msg: str) -> None:
            self._log(msg)

        addr = addr_manual or None
        if not addr:
            try:
                addr = await scan_for_quikburst(name, scan_s, log=log)
            except Exception as e:
                self._log(f"Scan error: {e}")
                self._ui_q.put(("errorbox", str(e)))
                self._set_status("Disconnected")
                self._ui_q.put(("disconnected", None))
                return
        if not addr:
            self._set_status("Disconnected")
            self._ui_q.put(("disconnected", None))
            return

        link = BleLineLink()
        had_ble_session = False

        async def pump_rx() -> None:
            while self._ble_running.is_set():
                try:
                    ln = await link.get_line(0.35)
                    self._log(f"<< {ln}")
                except asyncio.TimeoutError:
                    continue
                except Exception:
                    break

        try:
            async with BleakClient(addr, timeout=20.0) as client:
                try:
                    await client.exchange_mtu(247)
                except Exception:
                    pass

                await client.start_notify(NUS_TX_UUID, link.on_notify)
                await asyncio.sleep(0.25)

                if self.var_ping.get():
                    if not await ble_ping_test(client, link, log=log):
                        self._set_status("Disconnected")
                        self._ui_q.put(("disconnected", None))
                        return

                had_ble_session = True
                self._ble_running.set()
                pump = asyncio.create_task(pump_rx())
                self._set_status(f"Connected BLE: {addr}")
                self._ble_ready.set()
                self._ui_q.put(("connected", None))
                self._ui_q.put(("post_connect_enc", None))

                try:
                    while True:
                        def pull_cmd():
                            try:
                                return self._ble_cmd_q.get(timeout=0.15)
                            except queue.Empty:
                                return None

                        item = await asyncio.to_thread(pull_cmd)
                        if item is None:
                            continue
                        if item[0] == "close":
                            self._ble_running.clear()
                            try:
                                await client.write_gatt_char(NUS_RX_UUID, b"STOP\n", response=False)
                            except Exception:
                                pass
                            break
                        if item[0] == "write":
                            try:
                                await client.write_gatt_char(NUS_RX_UUID, item[1], response=False)
                            except Exception as e:
                                self._log(f"BLE write error: {e}")
                finally:
                    pump.cancel()
                    try:
                        await pump
                    except asyncio.CancelledError:
                        pass
                    try:
                        await client.stop_notify(NUS_TX_UUID)
                    except Exception:
                        pass

        except Exception as e:
            self._log(f"BLE error: {e}")
            self._ui_q.put(("errorbox", str(e)))
        finally:
            if had_ble_session:
                await asyncio.sleep(0.5)
                self._log("BLE session ended — wait ~1s for Quikburst to advertise, then Connect again.")
            self._ble_ready.clear()
            self._ble_running.clear()
            self._ui_q.put(("disconnected", None))
            self._set_status("Disconnected")

    def _on_disconnect(self) -> None:
        self._reset_device_time_anchor()
        self._csv_timed_capture_start = None
        self._cancel_timed_run()
        self._stop_telem_polling()
        self.var_live_telem.set(False)
        if self._ser is not None:
            if self._ser_reader_stop:
                self._ser_reader_stop.set()
            try:
                send_serial_line(self._ser, "STOP")
            except Exception:
                pass
            try:
                self._ser.close()
            except Exception:
                pass
            self._ser = None
            self._ser_reader = None
            self._ser_reader_stop = None
            self._apply_connected_state(False)
            self._set_status("Disconnected")
            self._log("USB disconnected.")
            return

        if self._ble_thread and self._ble_thread.is_alive():
            self._ble_ready.clear()
            self._ble_cmd_q.put(("close",))
            self._log("BLE disconnect requested...")
        self._apply_connected_state(False)

    def _send_wire(self, line: str) -> None:
        if line.strip().upper() == "STOP":
            self._export_timed_run_csv(time.time(), "manual_stop")
            self._cancel_timed_run()
        self._send_line(line)

    def _send_raw(self) -> None:
        raw = self.raw_entry.get().strip()
        if not raw:
            return
        line = sanitize_vesc_command_line(protocol_line_from_user_input(raw))
        if line.strip().upper() == "STOP":
            self._export_timed_run_csv(time.time(), "manual_stop")
            self._cancel_timed_run()
            self._send_line("STOP")
            return
        if self._line_starts_motor_set(line):
            self._maybe_arm_timed_run()
        self._send_line(line)

    def _send_line(self, line: str) -> None:
        line = sanitize_vesc_command_line(line.strip())
        wire = line + "\n"
        if self._ser is not None:
            try:
                self._ser.write(wire.encode("utf-8"))
                self._ser.flush()
                self._log(f">> {line.strip()}")
            except Exception as e:
                self._log(f"Send error: {e}")
            return
        if self._ble_thread and self._ble_thread.is_alive() and self._ble_ready.is_set():
            self._ble_cmd_q.put(("write", wire.encode("utf-8")))
            self._log(f">> {line.strip()}")
            return
        messagebox.showwarning("Not connected", "Connect over USB or BLE first.")


def run_gui() -> None:
    root = tk.Tk()
    VescControlGui(root)
    root.mainloop()


def main() -> None:
    parser = argparse.ArgumentParser(description="Quikburst VESC control — GUI (default) or CLI")
    parser.add_argument("--cli", action="store_true", help="Terminal mode instead of GUI")
    parser.add_argument("port", nargs="?", help="[CLI] Serial port, e.g. COM4")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--ble", action="store_true", help="[CLI] Bluetooth LE")
    parser.add_argument("--name", type=str, default="Quikburst")
    parser.add_argument("--scan", type=float, default=12.0)
    parser.add_argument("--address", type=str, default=None)
    parser.add_argument("--no-ping-test", action="store_true")
    args = parser.parse_args()

    if not args.cli:
        run_gui()
        return

    if args.ble:
        run_ble_mode_cli(args.name, args.scan, args.address, args.no_ping_test)
        print("Disconnected.")
        return

    port = args.port or find_serial_port()
    if not port:
        port = input("COM port [COM4]: ").strip() or "COM4" if sys.platform == "win32" else input("Serial: ").strip() or "/dev/ttyUSB0"
    print(f"Connecting to {port}...")
    try:
        ser = serial.Serial(port, args.baud, timeout=0.5)
    except serial.SerialException as e:
        print(e)
        sys.exit(1)
    print("Waiting for READY...")
    if not wait_for_ready(ser, log=print):
        print("(No READY — continuing)")
    time.sleep(0.3)
    while ser.in_waiting:
        ser.readline()
    if not args.no_ping_test:
        serial_ping_test(ser, log=print)
    interactive_serial_cli(ser)
    ser.close()


if __name__ == "__main__":
    main()
