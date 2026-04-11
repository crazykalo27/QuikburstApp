"""
Encoder Accuracy Analysis

Collects encoder data for a fixed duration, then produces:
  - Position and velocity plots with setpoint reference lines
  - Statistical accuracy report (console + figure annotation)
  - Timestamped CSV export of raw data

Dependencies:
    pip install pyserial matplotlib numpy

Usage:
    1. Set PORT below to your Arduino's COM port
    2. Set SETPOINTS_M to the target position(s) you will move to (in meters)
    3. python analyze_encoder.py
    4. Move the spool to the desired position during the acquisition window
"""

import csv
import datetime
import os
import sys
import threading
import time

import matplotlib.pyplot as plt
import numpy as np
import serial

# ============================================================================
# CONFIGURATION
# ============================================================================

PORT                   = "COM11"     # Arduino COM port
BAUD                   = 115200
DURATION_S             = 10          # Acquisition duration in seconds
SETPOINTS_M            = [1]       # Target positions (m); set [] to skip setpoint analysis
VELOCITY_THRESHOLD_MPS = 0.01        # |v| < this → sample counted as "stationary"

# Hardware constants (mirrors encoder_only_test.ino)
COUNTS_PER_REV   = 2400              # 600 PPR × 4x quadrature
SPOOL_DIA_INCHES = 4.0
METERS_PER_COUNT = 3.14159265 * SPOOL_DIA_INCHES * 0.0254 / COUNTS_PER_REV

# ============================================================================
# SHARED STATE  (written by serial thread, read by main thread post-acquisition)
# ============================================================================

_lock    = threading.Lock()
_times:  list[float] = []   # seconds relative to first sample
_counts: list[int]   = []   # raw encoder count
_pos:    list[float] = []   # position in meters
_vel:    list[float] = []   # velocity in m/s
_t0:     float | None = None
_running: bool = False      # set True before thread starts, False to stop it

# ============================================================================
# SERIAL READER THREAD
# ============================================================================

def serial_reader(ser: serial.Serial) -> None:
    global _t0
    buf = ""
    while _running:
        try:
            chunk = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        except serial.SerialException:
            print("\nSerial connection lost.")
            break

        buf += chunk
        while "\n" in buf:
            line, buf = buf.split("\n", 1)
            line = line.strip()
            if not line.startswith("ENC,"):
                if line:
                    print(f"\n[Arduino] {line}")
                continue
            parts = line.split(",")
            if len(parts) != 5:
                continue
            try:
                time_ms = float(parts[1])
                count   = int(parts[2])
                pos_m   = float(parts[3])
                vel_mps = float(parts[4])
            except ValueError:
                continue

            with _lock:
                if _t0 is None:
                    _t0 = time_ms
                t_s = (time_ms - _t0) / 1000.0
                _times.append(t_s)
                _counts.append(count)
                _pos.append(pos_m)
                _vel.append(vel_mps)

# ============================================================================
# RESET HELPERS
# ============================================================================

def send_reset(ser: serial.Serial) -> None:
    global _t0
    ser.write(b"RESET\n")
    with _lock:
        _t0 = None
        _times.clear()
        _counts.clear()
        _pos.clear()
        _vel.clear()


def _wait_for_reset_ok(ser: serial.Serial) -> None:
    """Read lines for up to 2 s waiting for RESET_OK confirmation."""
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        line = ser.readline().decode("utf-8", errors="replace").strip()
        if line:
            print(f"  [Arduino] {line}")
        if line == "RESET_OK":
            print("  Encoder zeroed.")
            return
    print("  Warning: did not receive RESET_OK — proceeding anyway.")

# ============================================================================
# ACQUISITION
# ============================================================================

def run_acquisition(ser: serial.Serial) -> None:
    global _running

    _running = True
    t_serial = threading.Thread(target=serial_reader, args=(ser,), daemon=True)
    t_serial.start()

    BAR_WIDTH = 40
    t_start   = time.monotonic()
    t_end     = t_start + DURATION_S

    try:
        while True:
            elapsed   = time.monotonic() - t_start
            remaining = max(0.0, DURATION_S - elapsed)
            fraction  = min(elapsed / DURATION_S, 1.0)
            filled    = int(BAR_WIDTH * fraction)
            bar       = "#" * filled + "-" * (BAR_WIDTH - filled)

            with _lock:
                n = len(_times)

            print(
                f"\r  [{bar}] {elapsed:5.1f}s / {DURATION_S}s"
                f"  |  {n:5d} samples"
                f"  |  {remaining:.1f}s left   ",
                end="", flush=True,
            )

            if elapsed >= DURATION_S:
                break
            time.sleep(0.1)

    except KeyboardInterrupt:
        print("\n  Acquisition interrupted — using data collected so far.")

    _running = False
    t_serial.join(timeout=1.0)
    print()  # newline after progress bar

# ============================================================================
# DATA SNAPSHOT
# ============================================================================

def snapshot_data() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    with _lock:
        times  = np.array(_times,  dtype=np.float64)
        counts = np.array(_counts, dtype=np.int32)
        pos    = np.array(_pos,    dtype=np.float64)
        vel    = np.array(_vel,    dtype=np.float64)
    return times, counts, pos, vel

# ============================================================================
# STATISTICS
# ============================================================================

def compute_overall_stats(pos: np.ndarray, vel: np.ndarray, times: np.ndarray) -> dict:
    n      = len(pos)
    t_span = times[-1] - times[0] if n > 1 else 0.0
    rate   = (n - 1) / t_span if t_span > 0 else 0.0
    return {
        "n_samples": n,
        "rate_hz":   rate,
        "mean_pos":  float(np.mean(pos)),
        "std_pos":   float(np.std(pos)),
        "min_pos":   float(np.min(pos)),
        "max_pos":   float(np.max(pos)),
    }


def compute_setpoint_stats(pos: np.ndarray, setpoint_m: float) -> dict:
    errors  = pos - setpoint_m
    abs_err = np.abs(errors)
    n       = len(pos)
    return {
        "setpoint_m":      setpoint_m,
        "mean_error":      float(np.mean(errors)),
        "rms_error":       float(np.sqrt(np.mean(errors ** 2))),
        "max_abs_error":   float(np.max(abs_err)),
        "pct_within_1mm":  100.0 * float(np.sum(abs_err <= 0.001)) / n,
        "pct_within_5mm":  100.0 * float(np.sum(abs_err <= 0.005)) / n,
        "pct_within_10mm": 100.0 * float(np.sum(abs_err <= 0.010)) / n,
    }


def compute_noise_floor(pos: np.ndarray, vel: np.ndarray) -> tuple[float | None, int]:
    mask = np.abs(vel) < VELOCITY_THRESHOLD_MPS
    stat_pos = pos[mask]
    if len(stat_pos) < 2:
        return None, int(np.sum(mask))
    return float(np.std(stat_pos)), int(len(stat_pos))

# ============================================================================
# CONSOLE OUTPUT
# ============================================================================

def print_stats(
    overall: dict,
    setpoint_stats_list: list[dict],
    noise_std: float | None,
    n_stationary: int,
) -> None:
    print("\n" + "=" * 62)
    print("  ENCODER ACCURACY ANALYSIS")
    print("=" * 62)
    print(f"  Samples collected : {overall['n_samples']}")
    print(f"  Actual rate       : {overall['rate_hz']:.1f} Hz  (target: 100 Hz)")
    print(f"  Mean position     : {overall['mean_pos']:.5f} m")
    print(f"  Std dev position  : {overall['std_pos'] * 1000:.3f} mm")
    print(f"  Min position      : {overall['min_pos']:.5f} m")
    print(f"  Max position      : {overall['max_pos']:.5f} m")
    print(f"  Range             : {(overall['max_pos'] - overall['min_pos']) * 1000:.3f} mm")

    if noise_std is not None:
        print(f"\n  Noise floor (|v| < {VELOCITY_THRESHOLD_MPS} m/s, {n_stationary} samples):")
        print(f"    Std dev         : {noise_std * 1000:.4f} mm")
    else:
        print(f"\n  Noise floor: insufficient stationary samples "
              f"({n_stationary} found, threshold |v| < {VELOCITY_THRESHOLD_MPS} m/s)")

    for sp in setpoint_stats_list:
        print(f"\n  Setpoint {sp['setpoint_m']:.4f} m:")
        print(f"    Mean error      : {sp['mean_error'] * 1000:+.3f} mm")
        print(f"    RMS error       : {sp['rms_error'] * 1000:.3f} mm")
        print(f"    Max abs error   : {sp['max_abs_error'] * 1000:.3f} mm")
        print(f"    Within ±1 mm    : {sp['pct_within_1mm']:.1f}%")
        print(f"    Within ±5 mm    : {sp['pct_within_5mm']:.1f}%")
        print(f"    Within ±10 mm   : {sp['pct_within_10mm']:.1f}%")
    print("=" * 62)

# ============================================================================
# CSV EXPORT
# ============================================================================

def export_csv(
    times: np.ndarray,
    counts: np.ndarray,
    pos: np.ndarray,
    vel: np.ndarray,
) -> str:
    ts         = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    filepath   = os.path.join(script_dir, f"encoder_test_{ts}.csv")

    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["time_s", "count", "position_m", "velocity_mps"])
        for i in range(len(times)):
            writer.writerow([
                f"{times[i]:.4f}",
                int(counts[i]),
                f"{pos[i]:.6f}",
                f"{vel[i]:.5f}",
            ])

    print(f"\n  CSV saved: {filepath}  ({len(times)} rows)")
    return filepath

# ============================================================================
# PLOT
# ============================================================================

def plot_results(
    times: np.ndarray,
    pos: np.ndarray,
    vel: np.ndarray,
    overall: dict,
    setpoint_stats_list: list[dict],
    noise_std: float | None,
) -> None:
    fig, (ax_pos, ax_vel) = plt.subplots(2, 1, sharex=True, figsize=(12, 7))
    fig.suptitle(
        f"Encoder Accuracy Analysis — {DURATION_S}s Acquisition"
        f"  |  {overall['n_samples']} samples @ {overall['rate_hz']:.1f} Hz",
        fontsize=12,
    )

    # --- Position subplot ---
    ax_pos.plot(times, pos, color="steelblue", linewidth=1.0, label="Measured position")
    for sp in setpoint_stats_list:
        ax_pos.axhline(
            sp["setpoint_m"], color="crimson", linewidth=1.5,
            linestyle="--", label=f"Setpoint {sp['setpoint_m']:.4f} m",
        )
    ax_pos.set_ylabel("Position (m)")
    ax_pos.grid(True, linestyle="--", alpha=0.5)
    ax_pos.legend(loc="upper right", fontsize=8)

    # --- Velocity subplot ---
    ax_vel.plot(times, vel, color="tomato", linewidth=1.0, label="Velocity")
    ax_vel.axhline(0, color="gray", linewidth=0.8)
    ax_vel.axhspan(
        -VELOCITY_THRESHOLD_MPS, VELOCITY_THRESHOLD_MPS,
        alpha=0.12, color="green",
        label=f"|v| < {VELOCITY_THRESHOLD_MPS} m/s (stationary)",
    )
    ax_vel.set_ylabel("Velocity (m/s)")
    ax_vel.set_xlabel("Time (s)")
    ax_vel.grid(True, linestyle="--", alpha=0.5)
    ax_vel.legend(loc="upper right", fontsize=8)

    # --- Stats text box on position subplot ---
    stats_lines = [
        f"N={overall['n_samples']}   rate={overall['rate_hz']:.1f} Hz",
        f"mean={overall['mean_pos']:.4f} m   std={overall['std_pos'] * 1000:.2f} mm",
        f"min={overall['min_pos']:.4f} m   max={overall['max_pos']:.4f} m",
        f"range={(overall['max_pos'] - overall['min_pos']) * 1000:.2f} mm",
    ]
    if noise_std is not None:
        stats_lines.append(f"noise floor={noise_std * 1000:.3f} mm")
    for sp in setpoint_stats_list:
        stats_lines.append(
            f"SP {sp['setpoint_m']:.3f} m:  "
            f"RMS={sp['rms_error'] * 1000:.2f} mm  "
            f"±1mm={sp['pct_within_1mm']:.0f}%"
        )

    ax_pos.text(
        0.01, 0.97, "\n".join(stats_lines),
        transform=ax_pos.transAxes,
        fontsize=8, verticalalignment="top",
        bbox=dict(boxstyle="round,pad=0.3", facecolor="lightyellow", alpha=0.85),
    )

    plt.tight_layout()
    plt.show()

# ============================================================================
# MAIN
# ============================================================================

def main() -> None:
    print(f"Opening {PORT} at {BAUD} baud...")
    try:
        ser = serial.Serial(PORT, BAUD, timeout=1)
    except serial.SerialException as e:
        print(f"ERROR: Could not open {PORT}: {e}")
        print("Check that the Arduino is connected and PORT is set correctly.")
        sys.exit(1)

    time.sleep(2)               # wait for Arduino to boot after serial open
    ser.reset_input_buffer()

    print("Sending RESET to zero encoder...")
    send_reset(ser)
    _wait_for_reset_ok(ser)

    print(f"\nAcquiring for {DURATION_S} seconds — move spool to target position(s) now.")
    if SETPOINTS_M:
        print(f"  Setpoint(s): {', '.join(f'{s:.4f} m' for s in SETPOINTS_M)}\n")
    run_acquisition(ser)

    ser.close()
    print("Serial port closed.")

    times, counts, pos, vel = snapshot_data()
    if len(times) == 0:
        print("ERROR: No data collected. Check serial connection and COM port.")
        sys.exit(1)

    overall        = compute_overall_stats(pos, vel, times)
    setpoint_stats = [compute_setpoint_stats(pos, sp) for sp in SETPOINTS_M]
    noise_std, n_s = compute_noise_floor(pos, vel)

    print_stats(overall, setpoint_stats, noise_std, n_s)
    export_csv(times, counts, pos, vel)

    print("\nOpening plot — close window to exit.")
    plot_results(times, pos, vel, overall, setpoint_stats, noise_std)


if __name__ == "__main__":
    main()
