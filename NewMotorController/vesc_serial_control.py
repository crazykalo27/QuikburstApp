"""
VESC control — Python companion for vescUartTest.ino

  • GUI (default): tkinter — Bluetooth LE (Quikburst / NUS), all commands, log pane
  • CLI: --cli — terminal mode over BLE

Install:
  pip install bleak matplotlib

Usage:
  python vesc_serial_control.py              # GUI
  python vesc_serial_control.py --cli [--name Quikburst] [--scan 12] [--address MAC]
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

# Nordic UART Service (must match firmware)
NUS_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_RX_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
NUS_TX_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

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


# Coalesce matplotlib redraws (~60 Hz max; redraw also scheduled on each new sample).
LIVE_PLOTS_REDRAW_MS = 16


def _u32_diff_ms(a: int, b: int) -> int:
    """Signed (a - b) in milliseconds for uint32 device millis."""
    da = int(a) & 0xFFFFFFFF
    db = int(b) & 0xFFFFFFFF
    d = (da - db) & 0xFFFFFFFF
    if d >= 0x80000000:
        d -= 0x100000000
    return int(d)


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


def signed_telem_motor_current(imo: float, duty: float, rpm: float) -> float:
    """Best-effort signed motor current for plots/CSV.

    VESC often reports a true signed avg motor current; keep that when already negative.
    Some UART paths report magnitude only (always ≥ 0); then use duty, else RPM, to match
    reverse drive (e.g. SET_CURRENT,-1 with negative duty).
    """
    if imo < 0.0:
        return imo
    a = abs(float(imo))
    if a < 1e-9:
        return 0.0
    if abs(float(duty)) > 1e-5:
        return math.copysign(a, float(duty))
    if abs(float(rpm)) >= 1.0:
        return math.copysign(a, float(rpm))
    return float(imo)


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
Commands (BLE):
  PING, SET_CURRENT,<A>, SET_BRAKE[,<A>] (omit A for firmware default brake current), SET_DUTY,<d> (duty capped at 0.20),
  STOP, GET_VALUES, GET_FW, KEEPALIVE,
  ENC_RESET, ENC_STREAM,<0|1>[,<ms>], TELEM_STREAM,<0|1>[,<ms>]

Telemetry: TELEM is now FIRMWARE-STREAMED. TELEM_STREAM,1,<ms> tells the ESP32 to emit one TELEM line
every <ms> ms without being asked — each sample costs one BLE notify instead of a polled request/response
round-trip, so the practical floor drops from ~100 ms to ~25–30 ms on macOS (one connection event +
VESC UART). GET_VALUES is still supported as a one-shot on-demand read. The "Firmware TELEM stream"
checkbox + ms spinbox drives TELEM_STREAM,<on>,<ms>; auto-starts on connect by default.

Encoder: firmware streams ENC,time_ms,count,position_m,velocity_mps at a configurable rate
(ENC_STREAM,<on>[,<ms>], default 25 ms / 40 Hz). At a 15 ms BLE connection interval the link has
only ~67 notify slots/s total, so when TELEM + ENC are both on use similar intervals (defaults align).
ENC_RESET zeros count. When not exporting CSV, OK,ENC_RESET
clears live encoder plot memory so the next run reads near zero on the graph. CSV position/velocity
appear only on stream=enc rows (TELEM rows leave those columns blank); enable Firmware ENC stream on connect.
Timed CSV: device_ms is ESP32 millis() for that row (TELEM esp32_ms or ENC time_ms); t_rel_s is
seconds on that same clock from capture start so TELEM and ENC align. host_unix_s is mapped
synthetic wall time for plotting continuity.
Timed CSV: rpm column is spool RPM from ENC linear velocity (same 4\" spool as firmware); near-zero
velocity uses position delta vs host time. TELEM rows repeat the latest ENC spool rpm (VESC eRPM
and fault are not written to CSV). Live plots show VESC eRPM, Vbat, and currents from GET_VALUES
(MOSFET/motor temps are not shown or logged to CSV).

Timed CSV export: with the export checkbox on, any Set current/brake/duty arms capture.
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
    if verb == "SET_BRAKE":
        if len(parts) == 2:
            return f"SET_BRAKE,{parts[1].strip()}"
        return "SET_BRAKE"
    if verb == "SET_DUTY" and len(parts) == 2:
        d = clamp_duty_str(parts[1])
        return f"SET_DUTY,{d:.4f}"
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


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------


class VescControlGui:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("Quikburst VESC Control")
        root.minsize(900, 720)

        self._ui_q: queue.Queue[tuple] = queue.Queue()

        self._ble_thread: Optional[threading.Thread] = None
        self._ble_cmd_q: queue.Queue = queue.Queue()
        self._ble_running = threading.Event()
        self._ble_ready = threading.Event()
        self.status = tk.StringVar(value="Disconnected")
        self.ble_name = tk.StringVar(value="Quikburst")
        self.ble_addr = tk.StringVar(value="")
        self.scan_timeout = tk.DoubleVar(value=12.0)
        self.var_ping = tk.BooleanVar(value=True)
        self.var_run_duration_s = tk.DoubleVar(value=5.0)
        self.var_keepalive_s = tk.DoubleVar(value=0.5)
        self.var_export_csv_timed = tk.BooleanVar(value=False)
        # Default on: resample the capture onto a uniform device_ms grid in the
        # CSV so every row is exactly 'grid ms' apart regardless of BLE/VESC
        # jitter. Grid step is var_csv_grid_ms, independent of TELEM poll; set
        # it higher than poll ms to downsample (e.g. streams at 25 ms, CSV grid
        # at 50 ms). Live graphs keep
        # using the raw samples since device_ms is accurate there.
        self.var_csv_fixed_grid = tk.BooleanVar(value=True)
        self.var_csv_grid_ms = tk.IntVar(value=50)
        self._csv_timed_capture_start: Optional[float] = None
        self._csv_device_ms_start: Optional[int] = None
        self._timed_stop_after_id: Optional[str] = None
        self._timed_keepalive_after_id: Optional[str] = None
        self._timed_deadline = 0.0
        self._timed_ka_interval_s = 0.0
        self._timed_run_is_test = False
        # Wall-clock anchor + duration for the live "TEST / RUN  3.2 / 10 s" readout.
        self._timed_start_wall: Optional[float] = None
        self._timed_total_s: float = 0.0
        self.var_run_status_str = tk.StringVar(value="Idle")
        # Map ESP32 millis() (ENC time_ms + TELEM esp32_ms) to a wall timeline; reset each session.
        self._session_anchor_wall: Optional[float] = None
        self._session_anchor_esp_ms: Optional[int] = None

        self.var_live_telem = tk.BooleanVar(value=False)
        self.var_auto_live_telem = tk.BooleanVar(value=True)
        # Firmware-pushed TELEM interval (ms). Sent to the ESP32 as TELEM_STREAM,1,<ms>. Each sample
        # costs one BLE notify instead of a polled request/response, so we default well under the
        # old ~100 ms RTT floor. Floor is ~15 ms on macOS (BLE connection interval) + ~10 ms VESC UART.
        self.var_telem_ms = tk.IntVar(value=25)
        # Firmware ENC stream interval (ms), sent as ENC_STREAM,1,<ms>. Match TELEM cadence (e.g. 25 ms)
        # when both streams are on so they don't fight for BLE notify slots.
        self.var_enc_ms = tk.IntVar(value=25)
        self.var_telem_rate_str = tk.StringVar(value="Actual: — Hz")
        self.var_enc_rate_str = tk.StringVar(value="ENC: — Hz")
        self.var_telem_window_s = tk.DoubleVar(value=30.0)
        # Debounce traces on the interval spinboxes so dragging the arrow doesn't flood the wire.
        self._telem_ms_apply_after_id: Optional[str] = None
        self._enc_ms_apply_after_id: Optional[str] = None
        self.var_telem_ms.trace_add("write", self._on_telem_ms_changed)
        self.var_enc_ms.trace_add("write", self._on_enc_ms_changed)
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

        # Default-off: the text pane was the single biggest UI-side cost at high
        # poll rates. Indicators below replace the visual feedback.
        self.var_verbose_log = tk.BooleanVar(value=False)
        # key -> (canvas, oval_id); ready is stateful, others pulse.
        self._indicators: Dict[str, Tuple[tk.Canvas, int]] = {}
        self._indicator_clear_after: Dict[str, Optional[str]] = {}
        self._ready_last_wall: Optional[float] = None
        self._error_last_msg: Optional[str] = None

        self._build()
        self.root.after(20, self._pump_ui_queue)
        self.root.after(500, self._update_telem_rate_display)
        self.root.after(1000, self._tick_ready_indicator)
        self.root.after(250, self._tick_run_status)

    def _update_telem_rate_display(self) -> None:
        """Derive TELEM + ENC Hz from device_ms deltas over the last ~2 s so the user can see the link's real cadence."""
        try:
            now_wall = time.time()
            window_s = 2.0

            def _rate_str(device_ms_vals: List[int], label: str, active: bool) -> str:
                if len(device_ms_vals) >= 2:
                    device_ms_vals.sort()
                    span_ms = _u32_diff_ms(device_ms_vals[-1], device_ms_vals[0])
                    n_intervals = len(device_ms_vals) - 1
                    if span_ms > 0 and n_intervals > 0:
                        mean_ms = span_ms / n_intervals
                        hz = 1000.0 / mean_ms if mean_ms > 0 else 0.0
                        return f"{label}: {hz:5.1f} Hz ({mean_ms:4.0f} ms)"
                if active:
                    return f"{label}: waiting…"
                return f"{label}: — Hz"

            telem_vals: List[int] = []
            for row in self._telem_samples:
                tw = row[0]
                esp_ms = row[1]
                if esp_ms is None:
                    continue
                if tw >= now_wall - window_s:
                    telem_vals.append(int(esp_ms))
            telem_active = self.var_live_telem.get() and self._is_connected()
            self.var_telem_rate_str.set(_rate_str(telem_vals, "Actual", telem_active))

            enc_vals: List[int] = []
            for row in self._enc_samples:
                tw = row[0]
                enc_ms = row[4]
                if tw >= now_wall - window_s:
                    enc_vals.append(int(enc_ms))
            enc_active = self.var_enc_stream.get() and self._is_connected()
            self.var_enc_rate_str.set(_rate_str(enc_vals, "ENC", enc_active))
        finally:
            self.root.after(500, self._update_telem_rate_display)

    def _build(self) -> None:
        main = ttk.Frame(self.root, padding=8)
        main.pack(fill=tk.BOTH, expand=True)

        outer = ttk.PanedWindow(main, orient=tk.HORIZONTAL)
        outer.pack(fill=tk.BOTH, expand=True)

        left = ttk.Frame(outer)
        outer.add(left, weight=1)
        right = ttk.Frame(outer)
        outer.add(right, weight=1)

        conn = ttk.LabelFrame(left, text="Connection (Bluetooth LE)", padding=8)
        conn.pack(fill=tk.X, pady=(0, 8))

        ble_row = ttk.Frame(conn)
        ble_row.grid(row=0, column=0, columnspan=4, sticky=tk.EW)
        ttk.Label(ble_row, text="BLE name:").pack(side=tk.LEFT)
        ttk.Entry(ble_row, textvariable=self.ble_name, width=18).pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(ble_row, text="Address (optional):").pack(side=tk.LEFT)
        ttk.Entry(ble_row, textvariable=self.ble_addr, width=22).pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(ble_row, text="Scan s:").pack(side=tk.LEFT)
        ttk.Spinbox(ble_row, from_=3, to=60, textvariable=self.scan_timeout, width=5).pack(side=tk.LEFT, padx=(4, 0))

        opt_row = ttk.Frame(conn)
        opt_row.grid(row=1, column=0, columnspan=4, sticky=tk.W, pady=(8, 0))
        ttk.Checkbutton(opt_row, text="PING test after connect", variable=self.var_ping).pack(side=tk.LEFT)

        btn_row = ttk.Frame(conn)
        btn_row.grid(row=2, column=0, columnspan=4, sticky=tk.W, pady=(10, 0))
        self.btn_connect = ttk.Button(btn_row, text="Connect", command=self._on_connect)
        self.btn_connect.pack(side=tk.LEFT, padx=(0, 8))
        self.btn_disconnect = ttk.Button(btn_row, text="Disconnect", command=self._on_disconnect, state=tk.DISABLED)
        self.btn_disconnect.pack(side=tk.LEFT)

        ttk.Label(conn, textvariable=self.status, foreground="#0a5").grid(row=3, column=0, columnspan=4, sticky=tk.W, pady=(8, 0))

        cmd_fr = ttk.LabelFrame(left, text="Commands (same protocol as firmware)", padding=8)
        cmd_fr.pack(fill=tk.X, pady=(0, 8))

        self.cmd_widgets: List[tk.Widget] = []

        time_fr = ttk.LabelFrame(
            cmd_fr,
            text="Timed motor output (Set current / brake / duty, Test, matching raw motor lines)",
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
        self.var_brake = tk.StringVar(value="120")
        self.var_duty = tk.StringVar(value="0")

        self.cmd_widgets.extend([sb_dur, sb_ka])

        row_param(3, "Current (A)", self.var_cur, "Set current", "SET_CURRENT")
        row_param(4, "Brake current (A)", self.var_brake, "Set brake", "SET_BRAKE")
        row_param(5, f"Duty (0–{MAX_DUTY:.2f} max)", self.var_duty, "Set duty", "SET_DUTY")

        quick = ttk.Frame(cmd_fr)
        quick.grid(row=6, column=0, columnspan=3, sticky=tk.W, pady=(10, 0))
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
        raw_fr.grid(row=7, column=0, columnspan=3, sticky=tk.EW, pady=(10, 0))
        ttk.Label(raw_fr, text="Raw line:").pack(side=tk.LEFT)
        self.raw_entry = ttk.Entry(raw_fr, width=40)
        self.raw_entry.pack(side=tk.LEFT, padx=(4, 8), fill=tk.X, expand=True)
        self.btn_send_raw = ttk.Button(raw_fr, text="Send", command=self._send_raw)
        self.btn_send_raw.pack(side=tk.LEFT)
        self.cmd_widgets.extend([self.raw_entry, self.btn_send_raw])

        self._build_indicator_strip(left)

        log_fr = ttk.LabelFrame(left, text="Log (quiet by default — TELEM / ENC / OK / READY suppressed)", padding=4)
        log_fr.pack(fill=tk.BOTH, expand=True)
        self.log_text = scrolledtext.ScrolledText(log_fr, height=12, state=tk.DISABLED, wrap=tk.WORD, font=("Consolas", 9))
        self.log_text.pack(fill=tk.BOTH, expand=True)
        log_ctl = ttk.Frame(log_fr)
        log_ctl.pack(fill=tk.X, pady=(4, 0))
        ttk.Checkbutton(
            log_ctl,
            text="Verbose log (show every TELEM/ENC/OK; hurts rate at <50 ms)",
            variable=self.var_verbose_log,
        ).pack(side=tk.LEFT)
        ttk.Button(log_ctl, text="Clear log", command=self._clear_log).pack(side=tk.RIGHT)

        streams_fr = ttk.LabelFrame(
            right,
            text="Live streams + plots (TELEM poll + ENC stream share the graph below)",
            padding=6,
        )
        streams_fr.pack(fill=tk.X, pady=(0, 8))

        telem_row = ttk.Frame(streams_fr)
        telem_row.pack(fill=tk.X)
        ttk.Checkbutton(
            telem_row,
            text="Firmware TELEM stream",
            variable=self.var_live_telem,
            command=self._on_live_telem_toggle,
        ).pack(side=tk.LEFT)
        ttk.Label(telem_row, text="every (ms):").pack(side=tk.LEFT, padx=(8, 0))
        sb_telem_ms = ttk.Spinbox(telem_row, from_=5, to=5000, increment=5, textvariable=self.var_telem_ms, width=6)
        sb_telem_ms.pack(side=tk.LEFT, padx=(4, 8))
        ttk.Label(telem_row, textvariable=self.var_telem_rate_str, foreground="#06c", width=22).pack(side=tk.LEFT, padx=(0, 12))
        ttk.Checkbutton(
            telem_row,
            text="Auto-start after connect",
            variable=self.var_auto_live_telem,
        ).pack(side=tk.LEFT)
        self.cmd_widgets.append(sb_telem_ms)

        enc_row = ttk.Frame(streams_fr)
        enc_row.pack(fill=tk.X, pady=(6, 0))
        ttk.Checkbutton(
            enc_row,
            text="Firmware ENC stream",
            variable=self.var_enc_stream,
            command=self._on_enc_stream_toggle,
        ).pack(side=tk.LEFT)
        ttk.Label(enc_row, text="every (ms):").pack(side=tk.LEFT, padx=(8, 0))
        sb_enc_ms = ttk.Spinbox(enc_row, from_=1, to=1000, increment=1, textvariable=self.var_enc_ms, width=6)
        sb_enc_ms.pack(side=tk.LEFT, padx=(4, 8))
        self.cmd_widgets.append(sb_enc_ms)
        ttk.Label(enc_row, textvariable=self.var_enc_rate_str, foreground="#093", width=22).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(enc_row, text="ENC zero", command=lambda: self._send_line("ENC_RESET")).pack(side=tk.LEFT, padx=(4, 0))
        ttk.Separator(enc_row, orient=tk.VERTICAL).pack(side=tk.LEFT, fill=tk.Y, padx=12)
        ttk.Label(enc_row, text="Graph window (s):").pack(side=tk.LEFT)
        sb_telem_win = ttk.Spinbox(enc_row, from_=5, to=600, increment=5, textvariable=self.var_telem_window_s, width=6)
        sb_telem_win.pack(side=tk.LEFT, padx=(4, 8))
        ttk.Button(enc_row, text="Apply", command=self._apply_graph_windows).pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(enc_row, text="Clear graph", command=self._clear_telem_data).pack(side=tk.LEFT)
        self.cmd_widgets.append(sb_telem_win)

        # CSV export cadence lives with the live-stream settings so the live poll
        # rate and the exported-grid rate are tuned side by side (they're independent).
        csv_row = ttk.Frame(streams_fr)
        csv_row.pack(fill=tk.X, pady=(6, 0))
        ttk.Checkbutton(
            csv_row,
            text="CSV on uniform time grid (nearest TELEM/ENC per row; immune to BLE/VESC jitter)",
            variable=self.var_csv_fixed_grid,
        ).pack(side=tk.LEFT)
        ttk.Label(csv_row, text="   CSV row every (ms):").pack(side=tk.LEFT)
        sb_csv_ms = ttk.Spinbox(csv_row, from_=5, to=10000, increment=5, textvariable=self.var_csv_grid_ms, width=6)
        sb_csv_ms.pack(side=tk.LEFT, padx=(4, 0))
        self.cmd_widgets.append(sb_csv_ms)

        graph_fr = ttk.LabelFrame(
            right,
            text="TELEM + encoder position vs time (encoder on top; same window)",
            padding=4,
        )
        graph_fr.pack(fill=tk.BOTH, expand=True)
        self._graph_inner = ttk.Frame(graph_fr)
        self._graph_inner.pack(fill=tk.BOTH, expand=True)
        self._build_telem_matplotlib(self._graph_inner)

        self._set_commands_enabled(False)

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

    # --- Status indicators -------------------------------------------------
    # Small colored dots that replace scrolling log feedback: at fast polling,
    # Tk text-widget appends were the main UI-side bottleneck. Indicators cost
    # one canvas color change per event.
    _IND_OFF = "#333"
    _IND_OUTLINE = "#555"
    _IND_SPECS = [
        ("ready", "Ready",    "#2a9f2a"),
        ("motor", "Motor OK", "#2680c2"),
        ("stop",  "Stop",     "#e08a00"),
        ("error", "Error",    "#c22222"),
    ]

    def _build_indicator_strip(self, parent: ttk.Frame) -> None:
        bar = ttk.LabelFrame(parent, text="Link status (click Error to clear)", padding=4)
        bar.pack(fill=tk.X, pady=(0, 6))
        row = ttk.Frame(bar)
        row.pack(fill=tk.X)
        bg = row.cget("background") if "background" in row.keys() else None
        for key, label, _ in self._IND_SPECS:
            c = tk.Canvas(row, width=14, height=14, highlightthickness=0,
                          bd=0, bg=bg or "#eeeeee")
            oid = c.create_oval(2, 2, 12, 12, fill=self._IND_OFF, outline=self._IND_OUTLINE)
            c.pack(side=tk.LEFT, padx=(0, 2))
            ttk.Label(row, text=label).pack(side=tk.LEFT, padx=(0, 12))
            self._indicators[key] = (c, oid)
            self._indicator_clear_after[key] = None
        self._indicators["error"][0].bind("<Button-1>", lambda _e: self._clear_error_indicator())
        # Live run readout ("TEST 3.2 / 10 s" etc.) — refreshed by _tick_run_status.
        ttk.Label(
            row,
            textvariable=self.var_run_status_str,
            foreground="#06c",
            font=("TkDefaultFont", 9, "bold"),
        ).pack(side=tk.RIGHT, padx=(12, 4))
        ttk.Label(row, text="Run:").pack(side=tk.RIGHT)

    def _set_indicator(self, key: str, on: bool) -> None:
        ind = self._indicators.get(key)
        if not ind:
            return
        canvas, oid = ind
        color = dict((k, c) for k, _, c in self._IND_SPECS).get(key, "#888") if on else self._IND_OFF
        try:
            canvas.itemconfigure(oid, fill=color)
        except tk.TclError:
            pass

    def _pulse_indicator(self, key: str, ms: int) -> None:
        self._set_indicator(key, True)
        prev = self._indicator_clear_after.get(key)
        if prev is not None:
            try:
                self.root.after_cancel(prev)
            except Exception:
                pass
        self._indicator_clear_after[key] = self.root.after(
            ms, lambda k=key: self._pulse_indicator_clear(k)
        )

    def _pulse_indicator_clear(self, key: str) -> None:
        self._indicator_clear_after[key] = None
        # Ready uses its own heartbeat tick; leave it alone here.
        if key != "ready":
            self._set_indicator(key, False)

    def _clear_error_indicator(self) -> None:
        self._error_last_msg = None
        self._set_indicator("error", False)

    def _tick_run_status(self) -> None:
        """Update the 'Run: TEST/RUN  elapsed / total s' readout in the link-status strip."""
        try:
            start = self._timed_start_wall
            total = self._timed_total_s
            if start is not None and total > 0:
                elapsed = max(0.0, min(time.time() - start, total))
                kind = "TEST" if self._timed_run_is_test else "RUN"
                self.var_run_status_str.set(f"{kind}  {elapsed:4.1f} / {total:.1f} s")
            else:
                self.var_run_status_str.set("Idle")
        finally:
            self.root.after(250, self._tick_run_status)

    def _tick_ready_indicator(self) -> None:
        """Ready is lit when we've seen a [READY] heartbeat in the last ~7 s (firmware emits every 5 s)."""
        try:
            ok = (
                self._is_connected()
                and self._ready_last_wall is not None
                and (time.time() - self._ready_last_wall) <= 7.0
            )
            self._set_indicator("ready", ok)
        finally:
            self.root.after(1000, self._tick_ready_indicator)

    @staticmethod
    def _payload_core(payload: str) -> str:
        """Strip the '>> ' / '<< ' direction prefix used in log formatting."""
        s = payload.strip()
        if s.startswith("<< ") or s.startswith(">> "):
            s = s[3:].strip()
        return s

    def _is_quiet_log_line(self, payload: str) -> bool:
        """Lines suppressed from the text pane when Verbose log is off."""
        s = self._payload_core(payload).upper()
        if not s:
            return False
        if s.startswith("TELEM,") or s.startswith("ENC,"):
            return True
        if s.startswith("OK,") or s == "OK":
            return True
        if s == "[READY]":
            return True
        return False

    def _drive_indicators_from_payload(self, payload: str) -> None:
        """Map inbound firmware lines to indicator pulses. Only acts on '<<' receives."""
        s = payload.strip()
        if not s.startswith("<< "):
            return
        core = s[3:].strip()
        up = core.upper()
        if up == "[READY]" or up == "OK,BT_CONNECTED":
            self._ready_last_wall = time.time()
            self._set_indicator("ready", True)
            return
        if up.startswith("ERROR,"):
            self._error_last_msg = core
            self._set_indicator("error", True)
            return
        if up == "OK,STOP":
            self._pulse_indicator("stop", 800)
            return
        if (
            up.startswith("OK,SET_CURRENT")
            or up.startswith("OK,SET_DUTY")
            or up.startswith("OK,SET_BRAKE")
            or up == "OK,KEEPALIVE"
            or up.startswith("OK,ENC_")
        ):
            self._pulse_indicator("motor", 350)
            return

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

        self._fig = Figure(figsize=(5.5, 8.5), constrained_layout=True)
        ax0 = self._fig.add_subplot(5, 1, 1)
        ax1 = self._fig.add_subplot(5, 1, 2, sharex=ax0)
        ax2 = self._fig.add_subplot(5, 1, 3, sharex=ax0)
        ax3 = self._fig.add_subplot(5, 1, 4, sharex=ax0)
        ax4 = self._fig.add_subplot(5, 1, 5, sharex=ax0)
        ax0.set_ylabel("Pos (m)")
        ax1.set_ylabel("Vel (m/s)")
        ax2.set_ylabel("RPM")
        ax3.set_ylabel("Vbat")
        ax4.set_ylabel("A")
        ax4.set_xlabel("Time in window (s)")
        (self._ln_telem_enc_pos,) = ax0.plot([], [], color="tab:green", lw=1.2)
        (self._ln_enc_vel,) = ax1.plot([], [], color="tab:purple", lw=1)
        (self._ln_rpm,) = ax2.plot([], [], color="tab:blue", lw=1)
        (self._ln_v,) = ax3.plot([], [], "g-", lw=1)
        (self._ln_im,) = ax4.plot([], [], "r-", lw=1, label="I motor")
        (self._ln_iin,) = ax4.plot([], [], "m-", lw=1, label="I in")
        ax4.axhline(0.0, color="0.65", lw=0.7, zorder=0)
        ax4.legend(loc="upper right", fontsize=7)
        self._telem_axes = (ax0, ax1, ax2, ax3, ax4)
        self._ln_enc_pos = self._ln_telem_enc_pos

        self._canvas = FigureCanvasTkAgg(self._fig, master=parent)
        self._canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)

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

    def _estimate_device_ms_at_host_wall(self, host_wall: float) -> Optional[int]:
        """Best-effort ESP32 millis at a host unix instant (same linear map as sample timestamps)."""
        aw = self._session_anchor_wall
        ae = self._session_anchor_esp_ms
        if aw is None or ae is None:
            return None
        dt_ms = int((float(host_wall) - float(aw)) * 1000.0)
        return (int(ae) + dt_ms) & 0xFFFFFFFF

    def _plot_time_end(self) -> float:
        """Right edge of rolling plot window: follow latest mapped sample so TELEM/ENC share the same time base."""
        t_end = time.time()
        for row in self._telem_samples:
            tw = row[0]
            if tw > t_end:
                t_end = tw
        for row in self._enc_samples:
            tw = row[0]
            if tw > t_end:
                t_end = tw
        return t_end

    def _feed_telem_from_log_line(self, payload: str) -> None:
        d = parse_telem_line(payload)
        if d is None:
            return
        esp = d.get("esp_ms")
        tw = self._wall_from_esp_millis(int(esp)) if esp is not None else time.time()
        imo = signed_telem_motor_current(d["i_motor"], d["duty"], d["rpm"])
        self._telem_samples.append(
            (
                tw,
                esp,
                d["rpm"],
                d["duty"],
                d["vbat"],
                imo,
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
        t_end = self._plot_time_end()
        t_start = t_end - tw
        xs: List[float] = []
        rpm_l: List[float] = []
        v_l: List[float] = []
        im_l: List[float] = []
        iin_l: List[float] = []
        for row in self._telem_samples:
            t_wall, _esp_ms, rpm, _duty, vb, imo, i_i = row[:7]
            if t_wall < t_start:
                continue
            xs.append(t_wall - t_start)
            rpm_l.append(rpm)
            v_l.append(vb)
            im_l.append(imo)
            iin_l.append(i_i)

        enc_x: List[float] = []
        enc_pos: List[float] = []
        enc_vel: List[float] = []
        for row in self._enc_samples:
            t_wall = row[0]
            if t_wall < t_start:
                continue
            enc_x.append(t_wall - t_start)
            enc_pos.append(row[1])
            enc_vel.append(row[2])

        if hasattr(self, "_ln_telem_enc_pos"):
            self._ln_telem_enc_pos.set_data(enc_x, enc_pos)
        if self._ln_enc_vel is not None:
            self._ln_enc_vel.set_data(enc_x, enc_vel)

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
                    self._drive_indicators_from_payload(payload)
                    show = not is_enc_log_payload(payload)
                    if show and not self.var_verbose_log.get() and self._is_quiet_log_line(payload):
                        show = False
                    if show:
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
        """Write ONE row per TELEM sample (slowest stream) with the nearest-in-device-time ENC values attached.

        Each row is a time-aligned snapshot on the ESP32 millis() clock: TELEM provides the timestamp
        (device_ms, t_rel_s) and the encoder fields are filled from the nearest ENC sample within
        ENC_PAIR_TOL_MS. If there is no TELEM at all in the window, we fall back to one row per ENC
        sample so the CSV is not empty.
        """
        ENC_PAIR_TOL_MS = 50  # ENC default ~25 ms; anything further is probably a gap, leave blank.

        self._flush_pending_log_lines_to_samples()
        t_end = max(t_end, time.time())
        t0_wall = self._csv_timed_capture_start
        dev_start = self._csv_device_ms_start
        if t0_wall is None:
            if reason == "timed_stop":
                self._log(
                    "CSV export skipped: no capture window was armed (timed run ended). "
                    "Use Test for always-on CSV, or enable Export + a motor command."
                )
            return
        self._csv_timed_capture_start = None
        self._csv_device_ms_start = None

        dev_end = self._estimate_device_ms_at_host_wall(t_end)
        use_dev = dev_start is not None and dev_end is not None

        def _in_window_telem(tw: float, esp_ms: Optional[int]) -> bool:
            if use_dev and esp_ms is not None:
                e = int(esp_ms)
                return _u32_diff_ms(e, dev_start) >= 0 and _u32_diff_ms(dev_end, e) >= 0
            return t0_wall <= tw <= t_end

        def _in_window_enc(tw: float, enc_ms: int) -> bool:
            if use_dev:
                e = int(enc_ms)
                return _u32_diff_ms(e, dev_start) >= 0 and _u32_diff_ms(dev_end, e) >= 0
            return t0_wall <= tw <= t_end

        # Collect and sort ENC by device_ms for nearest-neighbor pairing.
        # Also precompute spool RPM per ENC sample (velocity-based; fall back to position delta when idle).
        enc_sorted: List[Tuple[int, float, int, float, float, float]] = []
        for row in self._enc_samples:
            tw = row[0]
            pos_m, vel_mps, count, enc_ms = row[1], row[2], row[3], row[4]
            if not _in_window_enc(tw, int(enc_ms)):
                continue
            enc_sorted.append((int(enc_ms), tw, int(count), float(pos_m), float(vel_mps), 0.0))
        enc_sorted.sort(key=lambda r: r[0])

        prev_tw: Optional[float] = None
        prev_pos: Optional[float] = None
        prev_count: Optional[int] = None
        for i, (e_ms, tw, count, pos_m, vel_mps, _rpm) in enumerate(enc_sorted):
            if prev_count is not None and count < prev_count - 10:
                prev_tw, prev_pos = None, None  # ENC_RESET discontinuity
            prev_count = count
            rpm_spool = _spool_rpm_from_linear_velocity_mps(vel_mps)
            if abs(vel_mps) < 1e-5 and prev_tw is not None and prev_pos is not None:
                rpm_spool = _spool_rpm_from_position_delta(pos_m, prev_pos, tw, prev_tw)
            enc_sorted[i] = (e_ms, tw, count, pos_m, vel_mps, rpm_spool)
            prev_tw, prev_pos = tw, pos_m

        # Nearest ENC neighbor by device_ms using monotonic two-pointer walk (TELEM is ordered in time).
        def _pair_enc_for(device_ms: int, start_idx: int) -> Tuple[Optional[int], int]:
            """Return (enc_index_or_None, next_search_start)."""
            if not enc_sorted:
                return None, start_idx
            i = start_idx
            n = len(enc_sorted)
            # Advance while next sample is still <= device_ms.
            while i + 1 < n and _u32_diff_ms(enc_sorted[i + 1][0], device_ms) <= 0:
                i += 1
            # i is candidate 1 (<= device_ms), i+1 is candidate 2 (> device_ms) if exists.
            best = i
            best_abs = abs(_u32_diff_ms(enc_sorted[i][0], device_ms))
            if i + 1 < n:
                d2 = abs(_u32_diff_ms(enc_sorted[i + 1][0], device_ms))
                if d2 < best_abs:
                    best = i + 1
                    best_abs = d2
            if best_abs > ENC_PAIR_TOL_MS:
                return None, i
            return best, i

        fieldnames = [
            "host_unix_s",
            "device_ms",
            "t_rel_s",
            "duty",
            "vbat",
            "i_motor",
            "i_in",
            "rpm_vesc",
            "rpm_spool",
            "position_m",
            "velocity_mps",
            "enc_count",
            "enc_device_ms",
        ]

        rows_out: List[Dict[str, Any]] = []

        telem_in_window: List[Tuple[float, Optional[int], float, float, float, float, float]] = []
        for row in self._telem_samples:
            tw, esp_ms, rpm, duty, vb, imo, i_i = row[:7]
            if not _in_window_telem(tw, esp_ms):
                continue
            telem_in_window.append((tw, esp_ms, rpm, duty, vb, imo, i_i))
        telem_in_window.sort(key=lambda r: (int(r[1]) if r[1] is not None else -1, r[0]))

        try:
            grid_ms = max(5, int(self.var_csv_grid_ms.get()))
        except (tk.TclError, ValueError):
            grid_ms = 50
        use_grid = (
            bool(self.var_csv_fixed_grid.get())
            and use_dev
            and dev_start is not None
            and dev_end is not None
            and (bool(telem_in_window) or bool(enc_sorted))
        )

        n_paired = 0
        n_telem = 0
        n_enc_rows = 0
        enc_search_i = 0
        mode = "telem"

        if use_grid:
            # Uniform device_ms grid: every row is exactly grid_ms apart regardless
            # of BLE/VESC jitter. Each grid point takes the nearest TELEM and the
            # nearest ENC (independent tolerances). Live plots keep using the raw
            # samples since device_ms is accurate there.
            import bisect
            # Worst-case nearest-neighbor distance between an asynchronous TELEM stream
            # (cadence = poll_ms) and the uniform export grid (cadence = grid_ms) is
            # ~(grid_ms + poll_ms) / 2, and *doubles* across one missed poll. Pick
            # tolerance = grid_ms + poll_ms (covers one dropped beat), with a 2*grid_ms
            # floor so slow polls against a dense grid also get forgiven.
            try:
                poll_ms = max(5, int(self.var_telem_ms.get()))
            except Exception:
                poll_ms = 100
            TELEM_TOL_MS = max(grid_ms + poll_ms, 2 * grid_ms, 120)
            ENC_TOL_MS = max(ENC_PAIR_TOL_MS, grid_ms // 2)
            mode = "grid"

            telem_pairs: List[Tuple[int, Tuple[float, Optional[int], float, float, float, float, float]]] = sorted(
                ((int(r[1]), r) for r in telem_in_window if r[1] is not None),
                key=lambda x: x[0],
            )
            telem_keys = [p[0] for p in telem_pairs]
            enc_keys = [r[0] for r in enc_sorted]

            def _nearest(keys: List[int], target: int) -> Tuple[Optional[int], int]:
                """Return (index, abs_ms_diff) of nearest key; index is None for empty list."""
                if not keys:
                    return None, 0
                j = bisect.bisect_left(keys, target)
                best_idx = None
                best_d = -1
                for k in (j - 1, j):
                    if 0 <= k < len(keys):
                        d = abs(keys[k] - target)
                        if best_idx is None or d < best_d:
                            best_idx = k
                            best_d = d
                return best_idx, best_d if best_d >= 0 else 0

            span_ms = max(0, _u32_diff_ms(int(dev_end), int(dev_start)))
            # Safety: cap row count so a runaway clock / huge window can't generate millions of rows.
            MAX_ROWS = 200_000
            n_steps = min(MAX_ROWS, span_ms // grid_ms + 1) if span_ms > 0 else 1

            for i in range(int(n_steps) + 1):
                g_delta = i * grid_ms
                if g_delta > span_ms:
                    break
                g = (int(dev_start) + g_delta) & 0xFFFFFFFF
                t_rel = g_delta / 1000.0

                t_idx, t_d = _nearest(telem_keys, g)
                if t_idx is not None and t_d <= TELEM_TOL_MS:
                    _, (_tw_t, _e_t, rpm_v, duty_v, vbat_v, imo_v, iin_v) = telem_pairs[t_idx]
                else:
                    rpm_v = duty_v = vbat_v = imo_v = iin_v = ""

                e_idx, e_d = _nearest(enc_keys, g)
                if e_idx is not None and e_d <= ENC_TOL_MS:
                    e_ms, _e_tw, e_count, e_pos, e_vel, e_rpm_spool = enc_sorted[e_idx]
                    rows_out.append({
                        "host_unix_s": self._wall_from_esp_millis(g),
                        "device_ms": int(g),
                        "t_rel_s": t_rel,
                        "duty": duty_v,
                        "vbat": vbat_v,
                        "i_motor": imo_v,
                        "i_in": iin_v,
                        "rpm_vesc": rpm_v,
                        "rpm_spool": e_rpm_spool,
                        "position_m": e_pos,
                        "velocity_mps": e_vel,
                        "enc_count": e_count,
                        "enc_device_ms": e_ms,
                    })
                    n_paired += 1
                else:
                    rows_out.append({
                        "host_unix_s": self._wall_from_esp_millis(g),
                        "device_ms": int(g),
                        "t_rel_s": t_rel,
                        "duty": duty_v,
                        "vbat": vbat_v,
                        "i_motor": imo_v,
                        "i_in": iin_v,
                        "rpm_vesc": rpm_v,
                        "rpm_spool": "",
                        "position_m": "",
                        "velocity_mps": "",
                        "enc_count": "",
                        "enc_device_ms": "",
                    })
            n_telem = len(telem_in_window)
            n_enc_rows = len(enc_sorted)
        elif telem_in_window:
            for tw, esp_ms, rpm, duty, vb, imo, i_i in telem_in_window:
                if use_dev and esp_ms is not None and dev_start is not None:
                    device_ms = int(esp_ms)
                    t_rel = _u32_diff_ms(device_ms, dev_start) / 1000.0
                else:
                    device_ms = int(esp_ms) if esp_ms is not None else ""
                    t_rel = tw - t0_wall

                enc_idx: Optional[int] = None
                if isinstance(device_ms, int):
                    enc_idx, enc_search_i = _pair_enc_for(device_ms, enc_search_i)

                if enc_idx is not None:
                    e_ms, e_tw, e_count, e_pos, e_vel, e_rpm_spool = enc_sorted[enc_idx]
                    rows_out.append({
                        "host_unix_s": tw,
                        "device_ms": device_ms,
                        "t_rel_s": t_rel,
                        "duty": duty,
                        "vbat": vb,
                        "i_motor": imo,
                        "i_in": i_i,
                        "rpm_vesc": rpm,
                        "rpm_spool": e_rpm_spool,
                        "position_m": e_pos,
                        "velocity_mps": e_vel,
                        "enc_count": e_count,
                        "enc_device_ms": e_ms,
                    })
                    n_paired += 1
                else:
                    rows_out.append({
                        "host_unix_s": tw,
                        "device_ms": device_ms,
                        "t_rel_s": t_rel,
                        "duty": duty,
                        "vbat": vb,
                        "i_motor": imo,
                        "i_in": i_i,
                        "rpm_vesc": rpm,
                        "rpm_spool": "",
                        "position_m": "",
                        "velocity_mps": "",
                        "enc_count": "",
                        "enc_device_ms": "",
                    })
            n_telem = len(telem_in_window)
            n_enc_rows = 0
        else:
            for e_ms, e_tw, e_count, e_pos, e_vel, e_rpm_spool in enc_sorted:
                if use_dev and dev_start is not None:
                    t_rel = _u32_diff_ms(e_ms, dev_start) / 1000.0
                else:
                    t_rel = e_tw - t0_wall
                rows_out.append({
                    "host_unix_s": e_tw,
                    "device_ms": e_ms,
                    "t_rel_s": t_rel,
                    "duty": "",
                    "vbat": "",
                    "i_motor": "",
                    "i_in": "",
                    "rpm_vesc": "",
                    "rpm_spool": e_rpm_spool,
                    "position_m": e_pos,
                    "velocity_mps": e_vel,
                    "enc_count": e_count,
                    "enc_device_ms": e_ms,
                })
            n_telem = 0
            n_enc_rows = len(enc_sorted)

        out_dir = self._timed_captures_dir()
        os.makedirs(out_dir, exist_ok=True)
        # Filename stamp = wall-clock moment we're actually writing the CSV. Millisecond
        # precision so two back-to-back exports can't collide / overwrite each other.
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
        safe_reason = "".join(c if c.isalnum() or c in "-_" else "_" for c in reason)[:40]
        path = os.path.join(out_dir, f"timed_run_{stamp}_{safe_reason}.csv")
        try:
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=fieldnames)
                w.writeheader()
                for d in rows_out:
                    w.writerow(d)
        except OSError as e:
            self._log(f"CSV export failed: {e}")
            return

        n = len(rows_out)
        if mode == "grid":
            telem_rows_with_data = sum(1 for d in rows_out if d.get("rpm_vesc") not in ("", None))
            self._log(
                f"CSV export ({reason}, uniform grid {grid_ms} ms): {n} rows "
                f"(TELEM filled {telem_rows_with_data}/{n} @ ≤{TELEM_TOL_MS} ms tol; "
                f"ENC paired {n_paired}/{n} @ ≤{ENC_TOL_MS} ms; "
                f"{n_telem} raw TELEM, {n_enc_rows} raw ENC available) → {path}"
            )
        elif n_telem > 0:
            self._log(
                f"CSV export ({reason}): {n} aligned rows "
                f"(TELEM cadence; {n_paired}/{n_telem} paired w/ ENC ≤{ENC_PAIR_TOL_MS}ms) → {path}"
            )
        elif n_enc_rows > 0:
            self._log(
                f"CSV export ({reason}): {n} rows (ENC only — Firmware TELEM stream was off) → {path}"
            )
        else:
            self._log(f"CSV export ({reason}): no samples in window → {path}")

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
        # Encoder position + velocity live on the main figure now (rows 1 + 2);
        # _redraw_telem_plot refreshes them. Kept as a no-op so existing callers still work.
        return

    def _on_enc_stream_toggle(self) -> None:
        if not self._is_connected():
            return
        self._sync_enc_stream_to_firmware()

    def _clamp_stream_ms(self, var: tk.IntVar, lo: int, hi: int, fallback: int) -> int:
        try:
            ms = int(var.get())
        except (tk.TclError, ValueError):
            ms = fallback
        return max(lo, min(hi, ms))

    def _sync_enc_stream_to_firmware(self) -> None:
        if not self._is_connected():
            return
        on = 1 if self.var_enc_stream.get() else 0
        ms = self._clamp_stream_ms(self.var_enc_ms, 1, 1000, 25)
        self._send_line(f"ENC_STREAM,{on},{ms}")

    def _is_connected(self) -> bool:
        return (
            self._ble_thread is not None
            and self._ble_thread.is_alive()
            and self._ble_ready.is_set()
        )

    def _apply_telem_stream(self, on: bool) -> None:
        """Push TELEM_STREAM,<on>,<ms> to firmware. No host-side scheduler — the ESP32
        now pushes TELEM without being asked, so the only timing we control is the interval."""
        if not self._is_connected():
            if on:
                self.var_live_telem.set(False)
                messagebox.showinfo("TELEM stream", "Connect to the ESP32 first.")
            return
        ms = self._clamp_stream_ms(self.var_telem_ms, 5, 5000, 25)
        flag = 1 if on else 0
        self._send_line(f"TELEM_STREAM,{flag},{ms}")

    def _on_live_telem_toggle(self) -> None:
        self._apply_telem_stream(self.var_live_telem.get())

    def _on_telem_ms_changed(self, *_args) -> None:
        # Debounce: spinboxes fire a write for every keystroke / arrow click. Coalesce into one
        # command ~250 ms after the last change so we don't flood the BLE wire with TELEM_STREAM lines.
        if self._telem_ms_apply_after_id is not None:
            try:
                self.root.after_cancel(self._telem_ms_apply_after_id)
            except Exception:
                pass
        self._telem_ms_apply_after_id = self.root.after(
            250, self._apply_telem_ms_after_debounce
        )

    def _apply_telem_ms_after_debounce(self) -> None:
        self._telem_ms_apply_after_id = None
        if self._is_connected() and self.var_live_telem.get():
            self._apply_telem_stream(True)

    def _on_enc_ms_changed(self, *_args) -> None:
        if self._enc_ms_apply_after_id is not None:
            try:
                self.root.after_cancel(self._enc_ms_apply_after_id)
            except Exception:
                pass
        self._enc_ms_apply_after_id = self.root.after(
            250, self._apply_enc_ms_after_debounce
        )

    def _apply_enc_ms_after_debounce(self) -> None:
        self._enc_ms_apply_after_id = None
        if self._is_connected() and self.var_enc_stream.get():
            self._sync_enc_stream_to_firmware()

    def _try_auto_start_live_telem(self) -> None:
        if not self.var_auto_live_telem.get():
            return
        if not self._is_connected():
            return
        self.var_live_telem.set(True)
        self._apply_telem_stream(True)
        self._log("(Auto-started firmware TELEM stream — runs on the ESP32; see 'Actual Hz' for the real link rate.)")

    def _pump_ui_queue(self) -> None:
        try:
            while True:
                kind, payload = self._ui_q.get_nowait()
                if kind == "log":
                    self._drive_indicators_from_payload(payload)
                    # ENC is always skipped (rate). In non-verbose mode also
                    # skip TELEM/OK/[READY] — indicators cover them and the
                    # text widget was the largest UI-side cost at fast polling.
                    show = not is_enc_log_payload(payload)
                    if show and not self.var_verbose_log.get() and self._is_quiet_log_line(payload):
                        show = False
                    if show:
                        self._append_log_safe(payload)
                    self._feed_telem_from_log_line(payload)
                    self._feed_enc_from_log_line(payload)
                    # Fresh plot after hardware zero — only when not holding samples for an active CSV window.
                    if (
                        self._csv_timed_capture_start is None
                        and payload.strip().upper().startswith("OK,ENC_RESET")
                    ):
                        self._clear_enc_data()
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
                    self._csv_device_ms_start = None
                    self._cancel_timed_run()
                    # No scheduler to cancel anymore: TELEM stream lives on the ESP32.
                    # Dropping BLE stops the link; just reflect state in the UI.
                    self.var_live_telem.set(False)
                    self._ready_last_wall = None
                    for k in ("ready", "motor", "stop", "error"):
                        self._set_indicator(k, False)
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
        self.root.after(20, self._pump_ui_queue)

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
        self._timed_start_wall = None
        self._timed_total_s = 0.0

    def _schedule_timed_run(self, duration_s: float, keepalive_interval_s: float) -> None:
        self._cancel_timed_run()
        if duration_s <= 0:
            return
        self._timed_deadline = time.time() + duration_s
        self._timed_start_wall = time.time()
        self._timed_total_s = float(duration_s)
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
        self._timed_start_wall = None
        self._timed_total_s = 0.0
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
            or u == "SET_BRAKE"
            or u.startswith("SET_BRAKE,")
            or u.startswith("SET_DUTY,")
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
            self._csv_device_ms_start = self._estimate_device_ms_at_host_wall(time.time())
        else:
            self._csv_timed_capture_start = None
            self._csv_device_ms_start = None
        if dur > 0:
            self._schedule_timed_run(dur, max(0.0, ka))
        else:
            self._cancel_timed_run()
        # After schedule (its internal cancel must not wipe this): mark Test runs for CSV filename/reason.
        self._timed_run_is_test = bool(from_test and dur > 0)

    def _on_test_freewheel_record(self) -> None:
        """Timed CSV/keepalive like motor sets, but command STOP (0 A) instead of SET_DUTY,0."""
        if not self._is_connected():
            messagebox.showwarning("Not connected", "Connect over Bluetooth first.")
            return
        self._maybe_arm_timed_run(force_csv=True, from_test=True)
        self._send_line("STOP")
        self._log(
            "(Test: STOP + CSV always armed for this run (Export checkbox not required); "
            "enable Firmware TELEM stream for VESC rows in the file)"
        )

    def _send_motor_param(self, prefix: str, value: str) -> None:
        val = value.strip()
        if prefix == "SET_DUTY":
            val = f"{clamp_duty_str(val):.4f}"
            line = f"{prefix},{val}"
        elif prefix == "SET_BRAKE":
            line = "SET_BRAKE" if not val else f"SET_BRAKE,{val}"
        else:
            line = f"{prefix},{val}"
        self._maybe_arm_timed_run()
        self._send_line(line)

    def _on_connect(self) -> None:
        self.btn_connect.configure(state=tk.DISABLED)
        threading.Thread(target=self._thread_ble_connect, daemon=True).start()

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
                    ln = await link.get_line(0.05)
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
        # Politely tell the firmware to stop streaming before we drop the link so the ESP32 doesn't
        # keep pushing notifies that nobody reads. Ignored if the write queue is already torn down.
        if self._is_connected():
            try:
                self._apply_telem_stream(False)
            except Exception:
                pass
        self._reset_device_time_anchor()
        self._csv_timed_capture_start = None
        self._csv_device_ms_start = None
        self._cancel_timed_run()
        self.var_live_telem.set(False)
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
        if self._ble_thread and self._ble_thread.is_alive() and self._ble_ready.is_set():
            self._ble_cmd_q.put(("write", wire.encode("utf-8")))
            self._log(f">> {line.strip()}")
            return
        messagebox.showwarning("Not connected", "Connect over Bluetooth first.")


def run_gui() -> None:
    root = tk.Tk()
    VescControlGui(root)
    root.mainloop()


def main() -> None:
    parser = argparse.ArgumentParser(description="Quikburst VESC control — GUI (default) or BLE CLI")
    parser.add_argument("--cli", action="store_true", help="Terminal mode over Bluetooth LE")
    parser.add_argument("--name", type=str, default="Quikburst")
    parser.add_argument("--scan", type=float, default=12.0)
    parser.add_argument("--address", type=str, default=None)
    parser.add_argument("--no-ping-test", action="store_true")
    args = parser.parse_args()

    if not args.cli:
        run_gui()
        return

    run_ble_mode_cli(args.name, args.scan, args.address, args.no_ping_test)
    print("Disconnected.")


if __name__ == "__main__":
    main()
