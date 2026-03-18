"""
Motor + Encoder + Current visualization (Serial)

Combines:
  - Command flow from working/CONTROL.py (DRILL,<sec>,<pwm>,<dir> → GO)
  - Data collection/parsing from AhaanEncoder/newEncoderVis.py
  - Serial instead of BLE
  - Matplotlib graphs for position, velocity, acceleration, current

Protocol: DRILL,<seconds>,<pwm>,<F|B> → READY → GO → RUNNING → DONE → DATA... → END
DATA format: DATA,index,time_ms,position_m,velocity_mps,accel_mps2,current_A

Usage:
  python motor_encoder_current_vis.py [port] [duration] [pwm] [direction]
  python motor_encoder_current_vis.py  (interactive)
"""

import argparse
import re
import sys
import time
from datetime import datetime
from typing import List, Optional, Tuple

import matplotlib.pyplot as plt
import numpy as np
import serial


# ============================================================================
# CONFIGURATION (from CONTROL.py / newEncoderVis)
# ============================================================================

READY_TIMEOUT_S   = 5.0
RUNNING_TIMEOUT_S = 5.0
DATA_TIMEOUT_S    = 120.0

PRE_DRILL_SEC  = 1
POST_DRILL_SEC = 1

# Safety limits
PWM_MAX = 25
DURATION_MIN = 1
DURATION_MAX = 10
DURATION_MAX_CURRENT = 20


# ============================================================================
# DATA COLLECTOR (from newEncoderVis DrillDataCollector, adapted for Serial + current)
# ============================================================================

class DrillDataCollector:
    """Collects and parses Serial lines from ESP32. DATA format includes current."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.indices       = []
        self.times_ms      = []
        self.positions_m   = []
        self.velocities    = []
        self.accelerations = []
        self.currents      = []
        self.errors        = []
        self.cmd_duty_pcts = []
        self.dir_signs     = []

        self.ready_event   = False
        self.running_event = False
        self.done_event    = False
        self.end_event     = False
        self.error_msg     = None

        self.data_count   = 0
        self.parse_errors = 0

    def process_line(self, line: str):
        """Parse a single line from ESP32."""

        if line.startswith("READY,"):
            print(f"  [ESP32] READY — {line}")
            self.ready_event = True
            return

        if line == "RUNNING":
            print(f"  [ESP32] RUNNING")
            self.running_event = True
            return

        if line == "DONE":
            print(f"  [ESP32] DONE")
            self.done_event = True
            return

        if line.startswith("DATA,"):
            self._parse_data_line(line)
            return

        if line == "END":
            print(f"  [ESP32] END — received {self.data_count} data points")
            self.end_event = True
            return

        if line == "ABORTED":
            self.error_msg = "Drill aborted by ESP32"
            self.end_event = True
            return

        if line.startswith("ERROR,"):
            reason = line.split(",", 1)[1]
            self.error_msg = f"ESP32 error: {reason}"
            print(f"  [ESP32] ERROR: {reason}")
            self.end_event = True
            return

        print(f"  [ESP32] {line}")

    def _parse_data_line(self, line: str):
        """Parse: DATA,index,time_ms,position_m,velocity_mps,accel_mps2,current_A[,error_A,cmd_duty_pct,dir_sign]"""
        parts = line.split(",")
        if len(parts) < 7:
            self.parse_errors += 1
            return

        try:
            idx   = int(parts[1])
            t_ms  = int(parts[2])
            pos   = float(parts[3])
            vel   = float(parts[4])
            acc   = float(parts[5])
            cur   = float(parts[6])
            err_a = float(parts[7]) if len(parts) > 7 else 0.0
            cmd_d = float(parts[8]) if len(parts) > 8 else 0.0
            dsgn  = int(parts[9]) if len(parts) > 9 else 0
        except ValueError:
            self.parse_errors += 1
            return

        self.indices.append(idx)
        self.times_ms.append(t_ms)
        self.positions_m.append(pos)
        self.velocities.append(vel)
        self.accelerations.append(acc)
        self.currents.append(cur)
        self.errors.append(err_a)
        self.cmd_duty_pcts.append(cmd_d)
        self.dir_signs.append(dsgn)
        self.data_count += 1

        if self.data_count % 100 == 0:
            print(f"    ... received {self.data_count} samples", end="\r")

    def to_numpy(self):
        """Convert to numpy arrays (from newEncoderVis)."""
        return {
            "index":        np.array(self.indices, dtype=np.int32),
            "time_ms":      np.array(self.times_ms, dtype=np.int32),
            "time_s":       np.array(self.times_ms, dtype=np.float64) / 1000.0,
            "position_m":   np.array(self.positions_m, dtype=np.float64),
            "velocity_mps": np.array(self.velocities, dtype=np.float64),
            "accel_mps2":   np.array(self.accelerations, dtype=np.float64),
            "current_A":    np.array(self.currents, dtype=np.float64),
            "error_A":      np.array(self.errors, dtype=np.float64),
            "cmd_duty_pct": np.array(self.cmd_duty_pcts, dtype=np.float64),
            "dir_sign":     np.array(self.dir_signs, dtype=np.int8),
        }


# ============================================================================
# SAFETY VALIDATION
# ============================================================================

def parse_int_safe(s: str, default: int = 0) -> Optional[int]:
    """Parse int; return default if empty, None if invalid."""
    s = s.strip()
    if not s:
        return default
    try:
        return int(s)
    except ValueError:
        return None


def validate_drill_params(duration: int, pwm_duty: int, direction: str) -> Optional[str]:
    """Return None if valid, else error message. (0 values are treated as 'skip'.)"""
    if duration == 0 or pwm_duty == 0:
        return None
    if duration < DURATION_MIN or duration > DURATION_MAX:
        return f"Duration must be {DURATION_MIN}-{DURATION_MAX} sec"
    if pwm_duty < 0 or pwm_duty > PWM_MAX:
        return f"PWM must be 0-{PWM_MAX}%"
    if direction not in ("F", "B"):
        return "Direction must be F or B"
    return None


def parse_float_safe(s: str, default: float = 0.0) -> Optional[float]:
    """Parse float; return default if empty, None if invalid."""
    s = s.strip()
    if not s:
        return default
    try:
        return float(s)
    except ValueError:
        return None


def validate_current_params(duration: int, current_a: float, kp: float, ki: float, kd: float, direction: str) -> Optional[str]:
    if duration == 0 or current_a == 0.0:
        return None
    if duration < 0 or duration > DURATION_MAX_CURRENT:
        return f"Duration must be 0-{DURATION_MAX_CURRENT} sec"
    if current_a < 0:
        return "Current must be >= 0"
    if direction not in ("F", "B"):
        return "Direction must be F or B"
    # Gains can be any float for now (supporting WIP controller)
    if any(np.isnan(x) for x in (kp, ki, kd, current_a)):
        return "Invalid numeric value"
    return None


# ============================================================================
# SERIAL PORT FINDER
# ============================================================================

def find_serial_port() -> Optional[str]:
    """Try to find ESP32 serial port."""
    try:
        import serial.tools.list_ports
        ports = serial.tools.list_ports.comports()
        for p in ports:
            if "usb" in p.device.lower() or "serial" in p.device.lower() or "SLAB" in str(p):
                return p.device
        if ports:
            return ports[0].device
    except Exception:
        pass
    return None


# ============================================================================
# DRILL EXECUTION (from CONTROL.py run_drill, Serial instead of BLE)
# ============================================================================

def run_drill(ser: serial.Serial, duration_s: int, pwm_duty: int, direction: str) -> Optional[dict]:
    """Run a drill, return parsed data dict or None on failure."""
    collector = DrillDataCollector()

    drill_cmd = f"DRILL,{duration_s},{pwm_duty},{direction}\n"
    print(f"Sending: DRILL,{duration_s},{pwm_duty},{direction}")

    ser.reset_input_buffer()
    ser.write(drill_cmd.encode("utf-8"))
    ser.flush()

    # Wait for READY
    deadline = time.time() + READY_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.ready_event:
                break
    if not collector.ready_event:
        print("ERROR: Timeout waiting for READY")
        return None

    # Send GO
    print("Sending: GO")
    ser.write(b"GO\n")
    ser.flush()

    # Wait for RUNNING
    deadline = time.time() + RUNNING_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.running_event:
                break
    if not collector.running_event:
        print("ERROR: Timeout waiting for RUNNING")
        return None

    # Wait for DONE (1s pre + duration + 1s post)
    total_s = PRE_DRILL_SEC + duration_s + POST_DRILL_SEC
    print(f"\nDrill in progress ({total_s}s total: 1s pre, {duration_s}s motor, 1s post)...")
    deadline = time.time() + total_s + 5.0
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.done_event:
                break
    if not collector.done_event:
        print("ERROR: Timeout waiting for DONE")
        return None

    # Receive DATA stream until END
    print("Receiving data...")
    deadline = time.time() + DATA_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.end_event:
                break
        if collector.error_msg:
            break

    if collector.error_msg:
        print(f"\nERROR: {collector.error_msg}")
        return None

    if collector.data_count == 0:
        print("ERROR: No data received")
        return None

    return collector.to_numpy()


def run_current_control(
    ser: serial.Serial,
    duration_s: int,
    current_a: float,
    kp: float,
    ki: float,
    kd: float,
    direction: str,
) -> Optional[dict]:
    """Run current-control mode (support only), return parsed data dict or None on failure."""
    collector = DrillDataCollector()

    cmd = f"CURRENT,{duration_s},{current_a:.3f},{kp:.3f},{ki:.3f},{kd:.3f},{direction}\n"
    print(f"Sending: {cmd.strip()}")

    ser.reset_input_buffer()
    ser.write(cmd.encode("utf-8"))
    ser.flush()

    # Wait for READY
    deadline = time.time() + READY_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.ready_event:
                break
    if not collector.ready_event:
        print("ERROR: Timeout waiting for READY")
        return None

    print("Sending: GO")
    ser.write(b"GO\n")
    ser.flush()

    # Wait for RUNNING
    deadline = time.time() + RUNNING_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.running_event:
                break
    if not collector.running_event:
        print("ERROR: Timeout waiting for RUNNING")
        return None

    total_s = PRE_DRILL_SEC + duration_s + POST_DRILL_SEC
    print(f"\nControl in progress ({total_s}s total: 1s pre, {duration_s}s control, 1s post)...")
    deadline = time.time() + total_s + 5.0
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.done_event:
                break
    if not collector.done_event:
        print("ERROR: Timeout waiting for DONE")
        return None

    print("Receiving data...")
    deadline = time.time() + DATA_TIMEOUT_S
    while time.time() < deadline:
        line = ser.readline().decode("utf-8", errors="ignore").strip()
        if line:
            collector.process_line(line)
            if collector.end_event:
                break
        if collector.error_msg:
            break

    if collector.error_msg:
        print(f"\nERROR: {collector.error_msg}")
        return None

    if collector.data_count == 0:
        print("ERROR: No data received")
        return None

    return collector.to_numpy()


# ============================================================================
# SUMMARY + CSV (from newEncoderVis / CONTROL.py — exact)
# ============================================================================

DEFAULT_SUPPLY_V = 12.0  # For power estimate; adjust if different


def print_summary(data: dict, duration_s: int):
    """Print drill kinematics summary (from newEncoderVis)."""
    pos = data["position_m"]
    vel = data["velocity_mps"]
    acc = data["accel_mps2"]
    cur = data["current_A"]
    t   = data["time_s"]

    # Average current during motor-on phase
    drill_start = PRE_DRILL_SEC
    drill_end = PRE_DRILL_SEC + duration_s
    mask = (t >= drill_start) & (t <= drill_end)
    avg_current = np.mean(np.abs(cur[mask])) if np.any(mask) else 0.0
    est_power = avg_current * DEFAULT_SUPPLY_V

    print(f"\n  Duration:       {t[-1]:.3f} s")
    print(f"  Samples:        {len(t)}")
    print(f"  Sample rate:    {len(t) / t[-1]:.1f} Hz" if t[-1] > 0 else "")
    print(f"  Total distance: {np.max(np.abs(pos)):.4f} m ({np.max(np.abs(pos)) / 0.0254:.2f} in)")
    print(f"  Peak velocity:  {np.max(np.abs(vel)):.3f} m/s ({np.max(np.abs(vel)) * 2.237:.2f} mph)")
    print(f"  Peak accel:     {np.max(acc):.2f} m/s²")
    print(f"  Peak decel:     {np.min(acc):.2f} m/s²")
    print(f"  Peak current:   {np.max(np.abs(cur)):.3f} A")
    print(f"  Avg current:    {avg_current:.3f} A (during drill)")
    print(f"  Est. power:     {est_power:.2f} W (at {DEFAULT_SUPPLY_V}V)")


def save_csv(data: dict, filepath: str):
    """Save drill data to CSV (from newEncoderVis, with current column)."""
    n = len(data["index"])
    header = "index,time_ms,time_s,position_m,velocity_mps,accel_mps2,current_A,error_A,cmd_duty_pct,dir_sign"

    rows = np.column_stack([
        data["index"],
        data["time_ms"],
        data["time_s"],
        data["position_m"],
        data["velocity_mps"],
        data["accel_mps2"],
        data["current_A"],
        data["error_A"],
        data["cmd_duty_pct"],
        data["dir_sign"],
    ])

    np.savetxt(
        filepath,
        rows,
        delimiter=",",
        header=header,
        comments="",
        fmt=["%d", "%d", "%.4f", "%.6f", "%.5f", "%.4f", "%.4f", "%.4f", "%.2f", "%d"]
    )
    print(f"\n  Saved: {filepath} ({n} rows)")


# ============================================================================
# GRAPHS (same style as encoder data — position, velocity, accel, current)
# ============================================================================

def plot_results(data: dict, duration_s: int, pwm_duty: int, direction: str):
    """Subplots: position, velocity, acceleration, current, error, cmd duty (1s pre, run, 1s post)."""
    t   = data["time_s"]
    pos = data["position_m"]
    vel = data["velocity_mps"]
    acc = data["accel_mps2"]
    cur = data["current_A"]
    err = data.get("error_A", np.zeros_like(t))
    cmd = data.get("cmd_duty_pct", np.zeros_like(t))
    dsgn = data.get("dir_sign", np.zeros_like(t))

    # Average current during motor-on phase (for power consumption)
    drill_start = PRE_DRILL_SEC
    drill_end = PRE_DRILL_SEC + duration_s
    mask = (t >= drill_start) & (t <= drill_end)
    avg_current_drill = np.mean(np.abs(cur[mask])) if np.any(mask) else 0.0

    fig, axes = plt.subplots(6, 1, sharex=True, figsize=(10, 13))
    fig.suptitle(f"Drill: {duration_s}s, PWM={pwm_duty}%, {direction} (1s pre/post)")

    for ax in axes:
        ax.axvspan(drill_start, drill_end, alpha=0.15, color="gray", label="motor on")
        ax.grid(True, alpha=0.3)

    axes[0].plot(t, pos, "b-", linewidth=1.5)
    axes[0].set_ylabel("Position (m)")
    axes[0].set_title("Position")

    axes[1].plot(t, vel, "g-", linewidth=1.5)
    axes[1].set_ylabel("Velocity (m/s)")
    axes[1].set_title("Velocity")

    axes[2].plot(t, acc, "m-", linewidth=1.5)
    axes[2].set_ylabel("Acceleration (m/s²)")
    axes[2].set_title("Acceleration")

    axes[3].plot(t, cur, "r-", linewidth=1.5, label="Current")
    axes[3].axhline(avg_current_drill, color="orange", linestyle="--", linewidth=1.5,
                    label=f"Avg (drill): {avg_current_drill:.3f} A")
    axes[3].set_ylabel("Current (A)")
    axes[3].set_title("Current (1s baseline before/after)")
    axes[3].legend(loc="upper right", fontsize=8)

    axes[4].plot(t, err, "k-", linewidth=1.2)
    axes[4].set_ylabel("Error (A)")
    axes[4].set_title("Current error (setpoint - measured)")

    axes[5].plot(t, cmd, "c-", linewidth=1.2)
    axes[5].set_ylabel("Cmd duty (%)")
    axes[5].set_xlabel("Time (s)")
    axes[5].set_title("Commanded duty (clamped)")

    plt.tight_layout()
    plt.show()


# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Motor + Encoder + Current (Serial)"
    )
    parser.add_argument("port", nargs="?", help="Serial port")
    parser.add_argument("duration", nargs="?", type=int, help=f"Duration {DURATION_MIN}-{DURATION_MAX} sec")
    parser.add_argument("pwm", nargs="?", type=int, help=f"PWM 0-{PWM_MAX}")
    parser.add_argument("direction", nargs="?", choices=["F", "B", "f", "b"], help="F or B")
    parser.add_argument("--no-plot", action="store_true", help="Skip plotting")
    parser.add_argument("--save", type=str, help="Save CSV path")
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    port = args.port or find_serial_port()

    mode = "DRILL"
    current_a = 0.0
    kp = ki = kd = 0.0

    if args.duration is None or args.pwm is None or args.direction is None:
        # Interactive mode: ask for port first (before duration)
        if sys.platform == "win32":
            default = port or "COM4"
            port = input(f"COM port [{default}]: ").strip() or default
        else:
            default = port or "/dev/cu.usbserial-0001"
            port = input(f"Serial port [{default}]: ").strip() or default

        if not port:
            print("No port specified.")
            sys.exit(1)

        print(f"Using port: {port}")
        while True:
            m = (input("Mode (D=drill / C=current control) [D]: ").strip().upper() or "D")[:1]
            mode = "CURRENT" if m == "C" else "DRILL"

            if mode == "DRILL":
                d = parse_int_safe(input(f"Duration ({DURATION_MIN}-{DURATION_MAX} sec) [0=skip]: "), 0)
                p = parse_int_safe(input(f"PWM (0-{PWM_MAX}) [0=skip]: "), 0)
                dir_in = (input("Direction (F/B) [F]: ").strip().upper() or "F")[:1]
                if d is None or p is None:
                    print("Invalid input. Enter numbers only.")
                    continue
                err = validate_drill_params(d, p, dir_in)
                if err:
                    print(f"  {err}")
                    continue
                duration, pwm_duty, direction = d, p, dir_in if dir_in in ("F", "B") else "F"
                if duration == 0 or pwm_duty == 0:
                    print("Skipped (duration=0 or pwm=0).")
                    continue
                break

            # CURRENT control (support only)
            d = parse_int_safe(input(f"Duration ({DURATION_MIN}-{DURATION_MAX} sec) [0=skip]: "), 0)
            cur = parse_float_safe(input("Current setpoint (A) [0=skip]: "), 0.0)
            kp_ = parse_float_safe(input("Kp [0]: "), 0.0)
            ki_ = parse_float_safe(input("Ki [0]: "), 0.0)
            kd_ = parse_float_safe(input("Kd [0]: "), 0.0)
            dir_in = (input("Direction (F/B) [F]: ").strip().upper() or "F")[:1]
            if d is None or cur is None or kp_ is None or ki_ is None or kd_ is None:
                print("Invalid input. Enter numbers only.")
                continue
            err = validate_current_params(d, cur, kp_, ki_, kd_, dir_in)
            if err:
                print(f"  {err}")
                continue
            duration, current_a, kp, ki, kd = d, float(cur), float(kp_), float(ki_), float(kd_)
            direction = dir_in if dir_in in ("F", "B") else "F"
            if duration == 0 or current_a == 0.0:
                print("Skipped (duration=0 or current=0).")
                continue
            break
    else:
        if not port:
            print("No serial port found. Specify port: python motor_encoder_current_vis.py COM4 5 25 F")
            sys.exit(1)
        # Non-interactive args mode = DRILL only (keep it simple/safe)
        mode = "DRILL"
        duration = min(max(args.duration, 0), DURATION_MAX)
        pwm_duty = min(max(args.pwm, 0), PWM_MAX)
        direction = (args.direction or "F").upper()[0]
        err = validate_drill_params(duration, pwm_duty, direction)
        if err:
            print(f"Invalid args: {err}")
            sys.exit(1)
        if duration == 0 or pwm_duty == 0:
            print("Refusing to run with duration=0 or pwm=0.")
            sys.exit(1)

    if not port:
        print("No port specified.")
        sys.exit(1)

    print("=" * 60)
    print("Motor + Encoder + Current (Serial)")
    print("=" * 60)
    print(f"  Port:     {port}")
    print(f"  Mode:     {mode}")
    print(f"  Duration: {duration}s")
    if mode == "DRILL":
        print(f"  PWM:      {pwm_duty}%")
    else:
        print(f"  Current:  {current_a:.3f} A")
        print(f"  PID:      Kp={kp:.3f}, Ki={ki:.3f}, Kd={kd:.3f}")
    print(f"  Dir:      {direction}")
    print()

    print(f"Connecting to {port}...")
    with serial.Serial(port, args.baud, timeout=1) as ser:
        # Opening serial often resets ESP32; wait for it to boot and signal ready
        print("  Waiting for ESP32 (up to 10s; opening port may reset it)...")
        boot_deadline = time.time() + 10.0
        seen_ready = False
        while time.time() < boot_deadline:
            line = ser.readline().decode("utf-8", errors="ignore").strip()
            if line and "READY" in line.upper():
                seen_ready = True
                break
            time.sleep(0.1)
        if not seen_ready:
            print("  (No READY seen; proceeding anyway)")
        time.sleep(0.5)  # Let any remaining boot output drain
        while ser.in_waiting:
            ser.readline()

        while True:
            print()
            print("=" * 60)
            if mode == "DRILL":
                print(f"Drill: {duration}s, PWM={pwm_duty}%, {direction}")
            else:
                print(f"Current control: {duration}s, I={current_a:.3f}A, Kp={kp:.3f} Ki={ki:.3f} Kd={kd:.3f}, {direction}")
            print("=" * 60)

            data = (
                run_drill(ser, duration, pwm_duty, direction)
                if mode == "DRILL"
                else run_current_control(ser, duration, current_a, kp, ki, kd, direction)
            )

            if data is None:
                retry = input("Drill failed. Retry with same params? (y/n): ").strip().lower()
                if retry not in ("y", "yes"):
                    sys.exit(1)
                continue

            print(f"\n{'=' * 60}")
            print("DRILL COMPLETE")
            print(f"{'=' * 60}")
            print_summary(data, duration)

            if args.save:
                save_csv(data, args.save)
            else:
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                save_csv(data, f"motor_encoder_current_{timestamp}.csv")

            # Show graph every time (blocks until window closed)
            if not args.no_plot:
                plot_results(data, duration, pwm_duty if mode == "DRILL" else 0, direction)

            again = input("\nRun another run? (y/n): ").strip().lower()
            if again in ("n", "q", "no", "quit"):
                break
            if again not in ("y", "yes"):
                break

            # Start over with full prompts (default 0 = skip)
            print()
            while True:
                m = (input("Mode (D=drill / C=current control) [D]: ").strip().upper() or "D")[:1]
                mode = "CURRENT" if m == "C" else "DRILL"

                if mode == "DRILL":
                    d = parse_int_safe(input(f"Duration ({DURATION_MIN}-{DURATION_MAX} sec) [0=skip]: "), 0)
                    p = parse_int_safe(input(f"PWM (0-{PWM_MAX}) [0=skip]: "), 0)
                    dir_in = (input("Direction (F/B) [F]: ").strip().upper() or "F")[:1]
                    if d is None or p is None:
                        print("Invalid input. Enter numbers only.")
                        continue
                    err = validate_drill_params(d, p, dir_in)
                    if err:
                        print(f"  {err}")
                        continue
                    duration, pwm_duty, direction = d, p, dir_in if dir_in in ("F", "B") else "F"
                    if duration == 0 or pwm_duty == 0:
                        print("Skipped (duration=0 or pwm=0).")
                        continue
                    break

                d = parse_int_safe(input(f"Duration ({DURATION_MIN}-{DURATION_MAX} sec) [0=skip]: "), 0)
                cur = parse_float_safe(input("Current setpoint (A) [0=skip]: "), 0.0)
                kp_ = parse_float_safe(input("Kp [0]: "), 0.0)
                ki_ = parse_float_safe(input("Ki [0]: "), 0.0)
                kd_ = parse_float_safe(input("Kd [0]: "), 0.0)
                dir_in = (input("Direction (F/B) [F]: ").strip().upper() or "F")[:1]
                if d is None or cur is None or kp_ is None or ki_ is None or kd_ is None:
                    print("Invalid input. Enter numbers only.")
                    continue
                err = validate_current_params(d, cur, kp_, ki_, kd_, dir_in)
                if err:
                    print(f"  {err}")
                    continue
                duration, current_a, kp, ki, kd = d, float(cur), float(kp_), float(ki_), float(kd_)
                direction = dir_in if dir_in in ("F", "B") else "F"
                if duration == 0 or current_a == 0.0:
                    print("Skipped (duration=0 or current=0).")
                    continue
                break


if __name__ == "__main__":
    main()
