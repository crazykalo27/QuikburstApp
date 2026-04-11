#!/usr/bin/env python3
"""
Connect to ESP32 running encoder_serial_stream.ino over USB serial.

Auto-picks a serial port, 115200 baud. After connect, sends PING to verify the link.

Modes:
  1 — STREAM: PCNT only (pwmAndEncoder-style), 4 in spool
  2 — RAW: compact PCNT lines
  3 — STREAM + ADC: same as 1 plus 12-bit A/B after each sample (ESP32: may disturb PCNT)
  4 — RAW + ADC: compact lines + ADC + trailing tag ADC

Encoder A/B = GPIO 25 & 33. Reflash firmware for STREAM_ADC / RAW_ADC commands.

Requires: pip install pyserial matplotlib

After each run, a timestamped CSV is written next to this script (encoder_raw_*.csv or encoder_stream_*.csv).

Optional: python encoder_stream_client.py --list

If GPIO numbers in your .ino differ, set ENCODER_A_GPIO / ENCODER_B_GPIO below to match.
"""

from __future__ import annotations

import csv
import math
import os
import sys
import time
from datetime import datetime

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("ERROR: pyserial not installed. Run: pip install pyserial")
    sys.exit(1)

try:
    import matplotlib.pyplot as plt
except ImportError:
    plt = None

BAUD = 115200
STREAM_MIN_S = 1
STREAM_MAX_S = 600
PING_TIMEOUT_S = 3.0

_COUNTS_PER_REV = 600 * 4
_SPOOL_CIRCUMF_M = math.pi * 4.0 * 0.0254
METERS_PER_COUNT = _SPOOL_CIRCUMF_M / float(_COUNTS_PER_REV)

# Must match encoder_serial_stream.ino (ENCODER_PIN_A / ENCODER_PIN_B).
ENCODER_A_GPIO = 25
ENCODER_B_GPIO = 33


def print_stream_mode_help() -> None:
    print(
        "\n--- STREAM (pwmAndEncoder-style) ---\n"
        "  • position_m = (PCNT − count_at_arm) × m/count, 4 in spool, 2400 CPR.\n"
        "  • dir = sign(ΔPCNT) per sample.\n"
        "  • With ADC mode: A/B traces = 12-bit; compare swing vs ~0/4095 for clean digital.\n"
    )


def print_raw_tap_help() -> None:
    print(
        "\n--- RAW ---\n"
        "  • Same PCNT fields as STREAM (compact line).\n"
        f"  • Pins A={ENCODER_A_GPIO}, B={ENCODER_B_GPIO}.\n"
        "\n--- Plots ---\n"
        "  position (m) | PCNT count | direction\n"
    )


def _script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def write_csv_raw(
    t_us: list[int],
    pcnt: list[int],
    d_pcnt: list[int],
    dpos_m: list[float],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> str:
    path = os.path.join(
        _script_dir(),
        f"encoder_raw_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
    )
    t0 = t_us[0]
    has_adc = len(adc_a) == len(t_us) and any(a >= 0 for a in adc_a)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        header = [
            "time_s",
            "t_us",
            "pcnt_count",
            "d_pcnt",
            "dpos_m",
            "position_m",
            "dir_m1_0_p1",
        ]
        if has_adc:
            header += ["adc_a", "adc_b"]
        w.writerow(header)
        for i in range(len(t_us)):
            ts = (t_us[i] - t0) * 1e-6
            row = [
                f"{ts:.6f}",
                t_us[i],
                pcnt[i],
                d_pcnt[i],
                f"{dpos_m[i]:.8f}",
                f"{pos_m[i]:.8f}",
                dir_l[i],
            ]
            if has_adc:
                row += [adc_a[i], adc_b[i]]
            w.writerow(row)
    print(f"\n  CSV saved: {path}  ({len(t_us)} rows)")
    return path


def print_raw_numeric_summary(
    t_us: list[int],
    pcnt: list[int],
    pos_m: list[float],
    adc_a: list[int],
    adc_b: list[int],
) -> None:
    if len(pcnt) < 2:
        return
    t0, t1 = t_us[0], t_us[-1]
    span_s = (t1 - t0) * 1e-6
    d_counts = pcnt[-1] - pcnt[0]
    d_m = pos_m[-1] - pos_m[0]
    extra = ""
    if len(adc_a) == len(t_us) and any(a >= 0 for a in adc_a):
        extra = f"  ADC A range: {min(adc_a)} … {max(adc_a)}   B: {min(adc_b)} … {max(adc_b)}\n"
    print(
        "\n--- RAW summary ---\n"
        f"  Span: {span_s:.2f} s\n"
        f"  PCNT Δ: {d_counts:+d} counts  →  {d_m * 1000:.2f} mm (from position_m)\n"
        f"{extra}"
    )


def write_csv_stream(
    t_us: list[int],
    pcnt: list[int],
    d_pcnt: list[int],
    dpos_pcnt: list[float],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> str:
    path = os.path.join(
        _script_dir(),
        f"encoder_stream_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
    )
    t0 = t_us[0]
    has_adc = len(adc_a) == len(t_us) and any(a >= 0 for a in adc_a)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        header = [
            "time_s",
            "t_us",
            "pcnt_count",
            "d_pcnt",
            "dpos_m",
            "position_m",
            "dir_m1_0_p1",
        ]
        if has_adc:
            header += ["adc_a", "adc_b"]
        w.writerow(header)
        for i in range(len(t_us)):
            ts = (t_us[i] - t0) * 1e-6
            row = [
                f"{ts:.6f}",
                t_us[i],
                pcnt[i],
                d_pcnt[i],
                f"{dpos_pcnt[i]:.8f}",
                f"{pos_m[i]:.8f}",
                dir_l[i],
            ]
            if has_adc:
                row += [adc_a[i], adc_b[i]]
            w.writerow(row)
    print(f"\n  CSV saved: {path}  ({len(t_us)} rows)")
    return path


def list_ports() -> None:
    ports = serial.tools.list_ports.comports()
    if not ports:
        print("No serial ports found.")
        return
    for p in ports:
        extra = f" — {p.description}" if p.description else ""
        print(f"  {p.device}{extra}")


def _port_sort_key(p: serial.tools.list_ports.ListPortInfo) -> tuple:
    dev = p.device
    if dev.startswith("/dev/tty.") and "/cu." not in dev:
        return (1, dev)
    return (0, dev)


def find_serial_port() -> str | None:
    ports = list(serial.tools.list_ports.comports())
    if not ports:
        return None
    ports.sort(key=_port_sort_key)

    def score(p: serial.tools.list_ports.ListPortInfo) -> int:
        blob = f"{p.device} {p.description or ''} {p.manufacturer or ''}".lower()
        keys = ("usb", "serial", "slab", "cp210", "ch340", "ch341", "ftdi", "uart")
        return sum(1 for k in keys if k in blob)

    ranked = sorted(ports, key=lambda p: (-score(p), _port_sort_key(p)))
    return ranked[0].device


def prompt_seconds() -> int:
    while True:
        raw = input(f"Run for how many seconds? ({STREAM_MIN_S}-{STREAM_MAX_S}): ").strip()
        try:
            n = int(raw)
        except ValueError:
            print("  Enter an integer.")
            continue
        if n < STREAM_MIN_S or n > STREAM_MAX_S:
            print(f"  Must be between {STREAM_MIN_S} and {STREAM_MAX_S}.")
            continue
        return n


def prompt_mode() -> str:
    while True:
        print("\nMode:")
        print("  1 — STREAM: PCNT only")
        print("  2 — RAW: PCNT compact")
        print("  3 — STREAM + ADC (diagnostic; firmware STREAM_ADC)")
        print("  4 — RAW + ADC (firmware RAW_ADC)")
        raw = input("Choose 1–4: ").strip()
        if raw in ("1", "2", "3", "4"):
            return raw
        print("  Type 1, 2, 3, or 4.")


def send_line(ser: serial.Serial, line: str) -> None:
    ser.write((line.strip() + "\n").encode("utf-8"))
    ser.flush()


def verify_link(ser: serial.Serial) -> bool:
    ser.reset_input_buffer()
    time.sleep(0.1)
    send_line(ser, "PING")
    deadline = time.time() + PING_TIMEOUT_S
    buf = ""
    while time.time() < deadline:
        chunk = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        if not chunk:
            continue
        buf += chunk
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if line == "PONG":
                print("  Link OK (PONG)")
                return True
            if line.startswith("[READY]"):
                continue
    print("ERROR: No PONG — wrong port, baud, or firmware not running encoder_serial_stream.ino")
    return False


def _append_stream_sample(
    line: str,
    t_us: list[int],
    pcnt: list[int],
    d_pcnt: list[int],
    dpos_pcnt: list[float],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> None:
    if not line.startswith("DATA,"):
        return
    parts = line[5:].split(",")
    try:
        if len(parts) >= 9 and parts[6].strip() == "PCNT":
            t_us.append(int(parts[0]))
            pcnt.append(int(parts[1]))
            d_pcnt.append(int(parts[2]))
            dpos_pcnt.append(float(parts[3]))
            pos_m.append(float(parts[4]))
            dir_l.append(int(parts[5]))
            adc_a.append(int(parts[7]))
            adc_b.append(int(parts[8]))
        elif len(parts) >= 7 and parts[6].strip() == "PCNT":
            t_us.append(int(parts[0]))
            pcnt.append(int(parts[1]))
            d_pcnt.append(int(parts[2]))
            dpos_pcnt.append(float(parts[3]))
            pos_m.append(float(parts[4]))
            dir_l.append(int(parts[5]))
            adc_a.append(-1)
            adc_b.append(-1)
        elif len(parts) >= 11:
            t_us.append(int(parts[0]))
            c = int(parts[1])
            pcnt.append(c)
            d_pcnt.append(int(parts[2]))
            dpos_pcnt.append(float(parts[3]))
            pos_m.append(float(parts[7]))
            dir_l.append(int(parts[8]))
            adc_a.append(int(parts[9]))
            adc_b.append(int(parts[10]))
        elif len(parts) >= 6:
            t_us.append(int(parts[0]))
            c = int(parts[1])
            pcnt.append(c)
            d_pcnt.append(int(parts[2]))
            dpos_pcnt.append(float(parts[3]))
            adc_a.append(int(parts[4]))
            adc_b.append(int(parts[5]))
            c0 = pcnt[0]
            pos_m.append((c - c0) * METERS_PER_COUNT)
            dp = int(parts[2])
            dir_l.append(1 if dp > 0 else (-1 if dp < 0 else 0))
    except (ValueError, IndexError):
        pass


def _append_raw_sample(
    line: str,
    t_us: list[int],
    pcnt: list[int],
    d_pcnt: list[int],
    dpos_m: list[float],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> None:
    if not line.startswith("RAW,"):
        return
    p = line[4:].split(",")
    try:
        if len(p) >= 9 and p[8].strip() == "ADC":
            t_us.append(int(p[0]))
            pcnt.append(int(p[1]))
            d_pcnt.append(int(p[2]))
            dpos_m.append(float(p[3]))
            pos_m.append(float(p[4]))
            dir_l.append(int(p[5]))
            adc_a.append(int(p[6]))
            adc_b.append(int(p[7]))
        elif len(p) >= 8:
            t_us.append(int(p[0]))
            c = int(p[1])
            prev = pcnt[-1] if pcnt else None
            pcnt.append(c)
            dpc = (c - prev) if prev is not None else 0
            d_pcnt.append(dpc)
            dpos_m.append(float(dpc) * METERS_PER_COUNT)
            pos_m.append(float(p[4]))
            dir_l.append(int(p[5]))
            adc_a.append(int(p[6]))
            adc_b.append(int(p[7]))
        elif len(p) >= 6:
            t_us.append(int(p[0]))
            c = int(p[1])
            pcnt.append(c)
            d_pcnt.append(int(p[2]))
            dpos_m.append(float(p[3]))
            pos_m.append(float(p[4]))
            dir_l.append(int(p[5]))
            adc_a.append(-1)
            adc_b.append(-1)
        elif len(p) >= 4:
            t_us.append(int(p[0]))
            c = int(p[1])
            prev = pcnt[-1] if pcnt else None
            pcnt.append(c)
            dpc = (c - prev) if prev is not None else 0
            d_pcnt.append(dpc)
            dpos_m.append(float(dpc) * METERS_PER_COUNT)
            adc_a.append(int(p[2]))
            adc_b.append(int(p[3]))
            c0 = pcnt[0]
            pos_m.append((c - c0) * METERS_PER_COUNT)
            dir_l.append(1 if dpc > 0 else (-1 if dpc < 0 else 0))
    except (ValueError, IndexError):
        pass


def plot_encoder_stream(
    t_us: list[int],
    pcnt: list[int],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> None:
    if plt is None:
        print("Install matplotlib for plots: pip install matplotlib")
        return
    if len(t_us) < 2 or len(pcnt) < 2:
        print("Not enough samples to plot.")
        return

    print_stream_mode_help()

    t0 = t_us[0]
    time_s = [(t - t0) * 1e-6 for t in t_us]
    c0 = pcnt[0]
    position_check = [(c - c0) * METERS_PER_COUNT for c in pcnt]

    fig1 = plt.figure("Stream — linear position (PCNT)", figsize=(10, 4.5))
    ax1 = fig1.add_subplot(111)
    if len(pos_m) == len(t_us):
        ax1.plot(time_s, pos_m, color="C1", linewidth=1.0, label="position_m (firmware)")
    ax1.plot(
        time_s,
        position_check,
        color="C0",
        linewidth=0.7,
        alpha=0.65,
        linestyle="--",
        label="(pcnt−pcnt₀)×m/count",
    )
    ax1.set_ylabel("position (m)")
    ax1.set_xlabel("time (s)")
    ax1.set_title("Cable travel — pwmAndEncoder: (count − count_at_arm) × m/count")
    ax1.legend(loc="upper left", fontsize=8)
    ax1.grid(True, alpha=0.35)
    fig1.tight_layout()

    fig2 = plt.figure("Stream — PCNT + direction", figsize=(10, 4.5))
    ax2 = fig2.add_subplot(111)
    ax2.plot(time_s, pcnt, color="C0", linewidth=0.85, label="PCNT count")
    ax2.set_ylabel("counts")
    ax2.set_xlabel("time (s)")
    ax2.legend(loc="upper left", fontsize=8)
    ax2.grid(True, alpha=0.35)
    ax2b = ax2.twinx()
    if len(dir_l) == len(t_us):
        ax2b.step(time_s, dir_l, where="post", color="gray", linewidth=0.6, alpha=0.9)
        ax2b.set_ylabel("dir (−1/0/+1)")
        ax2b.set_yticks([-1, 0, 1])
    fig2.tight_layout()

    has_adc = (
        len(adc_a) == len(t_us)
        and len(adc_b) == len(t_us)
        and any(x >= 0 for x in adc_a)
    )
    if has_adc:
        fig3 = plt.figure("Stream — ADC (legacy log)", figsize=(10, 4.5))
        ax3 = fig3.add_subplot(111)
        ax3.plot(time_s, adc_a, color="C2", linewidth=0.8, label=f"A GPIO{ENCODER_A_GPIO}")
        ax3.plot(time_s, adc_b, color="C3", linewidth=0.8, label=f"B GPIO{ENCODER_B_GPIO}")
        ax3.set_ylabel("ADC (12-bit)")
        ax3.set_xlabel("time (s)")
        ax3.set_ylim(-50, 4200)
        ax3.legend(loc="upper right", fontsize=8)
        ax3.grid(True, alpha=0.35)
        fig3.tight_layout()

    plt.show()


def plot_raw_tap(
    t_us: list[int],
    pcnt: list[int],
    pos_m: list[float],
    dir_l: list[int],
    adc_a: list[int],
    adc_b: list[int],
) -> None:
    if plt is None:
        print("Install matplotlib for plots: pip install matplotlib")
        return
    if len(t_us) < 2:
        print("Not enough RAW samples to plot (serial silent or parse errors).")
        return

    print_raw_tap_help()

    t0 = t_us[0]
    time_s = [(t - t0) * 1e-6 for t in t_us]

    has_adc = len(adc_a) == len(t_us) and any(x >= 0 for x in adc_a)
    nrows = 4 if has_adc else 2
    fig, axes = plt.subplots(nrows, 1, sharex=True, figsize=(10, 2.8 * nrows), constrained_layout=True)
    fig.suptitle(
        f"RAW — GPIO A={ENCODER_A_GPIO}, B={ENCODER_B_GPIO} (PCNT)",
        fontsize=11,
    )

    axes[0].plot(time_s, pos_m, color="C1", linewidth=1.0)
    axes[0].set_ylabel("pos (m)")
    axes[0].set_title("Linear position (4 in spool)")
    axes[0].grid(True, alpha=0.35)

    axes[1].plot(time_s, pcnt, color="C0", linewidth=0.85)
    axes[1].set_ylabel("PCNT")
    axes[1].set_xlabel("time (s)" if not has_adc else "")
    axes[1].grid(True, alpha=0.35)
    if len(dir_l) == len(time_s):
        axb = axes[1].twinx()
        axb.step(time_s, dir_l, where="post", color="gray", linewidth=0.5, alpha=0.85)
        axb.set_ylabel("dir")
        axb.set_yticks([-1, 0, 1])

    if has_adc:
        axes[2].plot(time_s, adc_a, color="C2", linewidth=0.85)
        axes[2].set_ylabel("ADC A")
        axes[2].set_ylim(-50, 4200)
        axes[2].grid(True, alpha=0.35)
        axes[3].plot(time_s, adc_b, color="C3", linewidth=0.85)
        axes[3].set_ylabel("ADC B")
        axes[3].set_xlabel("time (s)")
        axes[3].set_ylim(-50, 4200)
        axes[3].grid(True, alpha=0.35)

    plt.show()


def run_stream(
    ser: serial.Serial, duration_s: int, *, include_adc: bool = False
) -> tuple[
    int,
    list[int],
    list[int],
    list[int],
    list[float],
    list[float],
    list[int],
    list[int],
    list[int],
]:
    t_us: list[int] = []
    pcnt: list[int] = []
    d_pcnt: list[int] = []
    dpos_pcnt: list[float] = []
    pos_m: list[float] = []
    dir_l: list[int] = []
    adc_a: list[int] = []
    adc_b: list[int] = []

    ser.reset_input_buffer()
    time.sleep(0.05)

    cmd = f"STREAM_ADC,{duration_s}" if include_adc else f"STREAM,{duration_s}"
    send_line(ser, cmd)

    deadline = time.time() + duration_s + 15.0
    buf = ""
    n_data = 0

    while time.time() < deadline:
        chunk = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        if not chunk:
            continue
        buf += chunk
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue

            if not line.startswith("DATA,") and not line.startswith("READY"):
                print(line)

            if line.startswith("READY"):
                continue
            if line.startswith("ERROR,"):
                return 1, t_us, pcnt, d_pcnt, dpos_pcnt, pos_m, dir_l, adc_a, adc_b
            if line.startswith("STOPPED"):
                return 1, t_us, pcnt, d_pcnt, dpos_pcnt, pos_m, dir_l, adc_a, adc_b

            if line.startswith("DATA,"):
                n_data += 1
                _append_stream_sample(
                    line,
                    t_us,
                    pcnt,
                    d_pcnt,
                    dpos_pcnt,
                    pos_m,
                    dir_l,
                    adc_a,
                    adc_b,
                )
                if n_data % 100 == 0:
                    print(f"  ... {n_data} samples", end="\r")

            if line.startswith("END,"):
                print(f"\nStream finished: {line} ({n_data} DATA lines)")
                return 0, t_us, pcnt, d_pcnt, dpos_pcnt, pos_m, dir_l, adc_a, adc_b

    print("ERROR: timeout waiting for END")
    return 1, t_us, pcnt, d_pcnt, dpos_pcnt, pos_m, dir_l, adc_a, adc_b


def run_raw_tap(
    ser: serial.Serial, duration_s: int, *, include_adc: bool = False
) -> tuple[
    int,
    list[int],
    list[int],
    list[int],
    list[float],
    list[float],
    list[int],
    list[int],
    list[int],
]:
    t_us: list[int] = []
    pcnt: list[int] = []
    d_pcnt: list[int] = []
    dpos_m: list[float] = []
    pos_m: list[float] = []
    dir_l: list[int] = []
    adc_a: list[int] = []
    adc_b: list[int] = []

    ser.reset_input_buffer()
    time.sleep(0.05)

    cmd = f"RAW_ADC,{duration_s}" if include_adc else f"RAW,{duration_s}"
    send_line(ser, cmd)

    deadline = time.time() + duration_s + 15.0
    buf = ""
    n_raw = 0

    while time.time() < deadline:
        chunk = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        if not chunk:
            continue
        buf += chunk
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line:
                continue

            if not line.startswith("RAW,") and not line.startswith("READY_RAW"):
                print(line)

            if line.startswith("READY_RAW"):
                continue
            if line.startswith("ERROR,"):
                return 1, t_us, pcnt, d_pcnt, dpos_m, pos_m, dir_l, adc_a, adc_b
            if line.startswith("STOPPED"):
                return 1, t_us, pcnt, d_pcnt, dpos_m, pos_m, dir_l, adc_a, adc_b

            if line.startswith("RAW,"):
                n_raw += 1
                _append_raw_sample(
                    line,
                    t_us,
                    pcnt,
                    d_pcnt,
                    dpos_m,
                    pos_m,
                    dir_l,
                    adc_a,
                    adc_b,
                )
                if n_raw % 100 == 0:
                    print(f"  ... {n_raw} RAW lines", end="\r")

            if line.startswith("END,"):
                print(f"\nRAW finished: {line} ({n_raw} RAW lines)")
                return 0, t_us, pcnt, d_pcnt, dpos_m, pos_m, dir_l, adc_a, adc_b

    print("ERROR: timeout waiting for END")
    return 1, t_us, pcnt, d_pcnt, dpos_m, pos_m, dir_l, adc_a, adc_b


def open_serial(device: str) -> serial.Serial:
    kwargs = {"baudrate": BAUD, "timeout": 0.2}
    if sys.platform != "win32":
        kwargs["exclusive"] = True
    try:
        return serial.Serial(device, **kwargs)
    except TypeError:
        kwargs.pop("exclusive", None)
        return serial.Serial(device, **kwargs)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ("--list", "-l"):
        list_ports()
        return 0
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        print("Optional: --list   print serial ports\n")
        return 0

    port = find_serial_port()
    if not port:
        print("ERROR: No serial port found. Connect the ESP32 USB cable and try again.")
        print("Use --list to see ports.")
        return 1

    print(f"Using port {port} at {BAUD} baud")
    mode = prompt_mode()
    seconds = prompt_seconds()

    try:
        ser = open_serial(port)
    except serial.SerialException as e:
        print(f"ERROR: could not open {port}: {e}")
        return 1

    with ser:
        time.sleep(0.2)
        if not verify_link(ser):
            return 1

        if mode in ("1", "3"):
            (
                code,
                t_us,
                pcnt,
                d_pcnt,
                dpos_pcnt,
                pos_m,
                dir_l,
                adc_sa,
                adc_sb,
            ) = run_stream(ser, seconds, include_adc=(mode == "3"))
            if len(t_us) >= 2:
                n = len(t_us)
                if (
                    len(pcnt) == n
                    and len(d_pcnt) == n
                    and len(dpos_pcnt) == n
                    and len(pos_m) == n
                    and len(dir_l) == n
                    and len(adc_sa) == n
                    and len(adc_sb) == n
                ):
                    write_csv_stream(
                        t_us,
                        pcnt,
                        d_pcnt,
                        dpos_pcnt,
                        pos_m,
                        dir_l,
                        adc_sa,
                        adc_sb,
                    )
                plot_encoder_stream(t_us, pcnt, pos_m, dir_l, adc_sa, adc_sb)
            return code

        (
            code,
            t_us,
            pcnt,
            d_pcnt,
            dpos_m,
            pos_m,
            dir_l,
            adc_ra,
            adc_rb,
        ) = run_raw_tap(ser, seconds, include_adc=(mode == "4"))
        if len(t_us) >= 2:
            write_csv_raw(
                t_us, pcnt, d_pcnt, dpos_m, pos_m, dir_l, adc_ra, adc_rb
            )
            print_raw_numeric_summary(t_us, pcnt, pos_m, adc_ra, adc_rb)
            plot_raw_tap(t_us, pcnt, pos_m, dir_l, adc_ra, adc_rb)
        elif code == 0:
            print("No RAW lines parsed — check firmware RAW / RAW_ADC (reflash).")
        return code


if __name__ == "__main__":
    sys.exit(main())
