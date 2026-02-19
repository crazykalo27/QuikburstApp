"""
QuickBurst PWM + Encoder Control — BLE Version (Interactive)

Connects to ESP32 running pwmAndEncoder.ino over BLE.

Required: pip install bleak numpy

HARDWARE MATH (for reference — processing is done on ESP32, must match newEncoderread.ino):
    Encoder: Taiss 600 PPR, x4 quadrature → 2400 CPR
    Spool:   4.0 in diameter → C = π × 4.0 × 0.0254 m
    Resolution: SPOOL_CIRCUMF_M / 2400 m/count
"""

import asyncio
import sys
from datetime import datetime

import numpy as np

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("ERROR: bleak not installed. Run: pip install bleak")
    sys.exit(1)

# ============================================================================
# CONFIGURATION
# ============================================================================

DEVICE_NAME         = "QuickBurst"
SCAN_TIMEOUT_S      = 10.0
CONNECT_TIMEOUT_S   = 15.0

NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

READY_TIMEOUT_S     = 5.0
RUNNING_TIMEOUT_S   = 5.0
DATA_TIMEOUT_S      = 120.0

# ============================================================================
# DATA COLLECTOR
# ============================================================================

class DrillDataCollector:
    """Collects and parses BLE notifications from QuickBurst ESP32."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.indices       = []
        self.times_ms      = []
        self.positions_m   = []
        self.velocities    = []
        self.accelerations = []

        self.ready_event   = asyncio.Event()
        self.running_event = asyncio.Event()
        self.done_event    = asyncio.Event()
        self.end_event     = asyncio.Event()
        self.error_msg     = None

        self._rx_buffer = ""
        self.data_count    = 0
        self.parse_errors  = 0

    def notification_handler(self, sender, data: bytearray):
        try:
            text = data.decode("utf-8", errors="replace")
        except Exception:
            return

        self._rx_buffer += text

        while "\n" in self._rx_buffer:
            line, self._rx_buffer = self._rx_buffer.split("\n", 1)
            line = line.strip()
            if line:
                self._process_line(line)

    def _process_line(self, line: str):
        if line.startswith("READY,"):
            print(f"  [ESP32] READY — {line}")
            self.ready_event.set()
            return

        if line == "RUNNING":
            print(f"  [ESP32] RUNNING")
            self.running_event.set()
            return

        if line == "DONE":
            print(f"  [ESP32] DONE")
            self.done_event.set()
            return

        if line.startswith("DATA,"):
            self._parse_data_line(line)
            return

        if line == "END":
            print(f"  [ESP32] END — received {self.data_count} data points")
            self.end_event.set()
            return

        if line == "ABORTED":
            self.error_msg = "Drill aborted by ESP32"
            self.end_event.set()
            return

        if line.startswith("ERROR,"):
            reason = line.split(",", 1)[1]
            self.error_msg = f"ESP32 error: {reason}"
            print(f"  [ESP32] ERROR: {reason}")
            self.end_event.set()
            return

        print(f"  [ESP32] {line}")

    def _parse_data_line(self, line: str):
        """Parse: DATA,index,time_ms,position_m,velocity_mps,accel_mps2"""
        parts = line.split(",")
        if len(parts) != 6:
            self.parse_errors += 1
            return

        try:
            idx   = int(parts[1])
            t_ms  = int(parts[2])
            pos   = float(parts[3])
            vel   = float(parts[4])
            acc   = float(parts[5])
        except ValueError:
            self.parse_errors += 1
            return

        self.indices.append(idx)
        self.times_ms.append(t_ms)
        self.positions_m.append(pos)
        self.velocities.append(vel)
        self.accelerations.append(acc)
        self.data_count += 1

        if self.data_count % 100 == 0:
            print(f"    ... received {self.data_count} samples", end="\r")

    def to_numpy(self):
        return {
            "index":        np.array(self.indices, dtype=np.int32),
            "time_ms":      np.array(self.times_ms, dtype=np.int32),
            "time_s":       np.array(self.times_ms, dtype=np.float64) / 1000.0,
            "position_m":   np.array(self.positions_m, dtype=np.float64),
            "velocity_mps": np.array(self.velocities, dtype=np.float64),
            "accel_mps2":   np.array(self.accelerations, dtype=np.float64),
        }


# ============================================================================
# BLE SCAN + CONNECT
# ============================================================================

async def find_device(name: str, timeout: float) -> str:
    print(f"Scanning for '{name}' (timeout={timeout}s)...")
    device = await BleakScanner.find_device_by_name(name, timeout=timeout)

    if device is None:
        print(f"\nERROR: Device '{name}' not found.")
        print("  1. Ensure ESP32 is powered and running pwmAndEncoder.ino")
        print("  2. Check Serial Monitor for '[BLE] Advertising'")
        sys.exit(1)

    print(f"  Found: {device.name} [{device.address}]")
    return device.address


# ============================================================================
# DRILL EXECUTION (used within interactive session)
# ============================================================================

async def run_drill(client: BleakClient, collector: DrillDataCollector,
                    duration_s: int, pwm_duty: int, direction: str) -> dict | None:
    """Run a drill, return parsed data dict or None on failure."""
    collector.reset()

    drill_cmd = f"DRILL,{duration_s},{pwm_duty},{direction}\n".encode("utf-8")
    print(f"Sending: DRILL,{duration_s},{pwm_duty},{direction}")

    await client.write_gatt_char(NUS_RX_UUID, drill_cmd, response=False)
    await asyncio.sleep(0.1)  # allow ESP32 to process full packet

    try:
        await asyncio.wait_for(collector.ready_event.wait(), timeout=READY_TIMEOUT_S)
    except asyncio.TimeoutError:
        print("ERROR: Timeout waiting for READY")
        return None

    print("Sending: GO")
    await client.write_gatt_char(NUS_RX_UUID, b"GO\n", response=False)

    try:
        await asyncio.wait_for(collector.running_event.wait(), timeout=RUNNING_TIMEOUT_S)
    except asyncio.TimeoutError:
        print("ERROR: Timeout waiting for RUNNING")
        return None

    print(f"\nDrill in progress ({duration_s}s)...")

    try:
        await asyncio.wait_for(collector.done_event.wait(), timeout=duration_s + 5.0)
    except asyncio.TimeoutError:
        print("ERROR: Timeout waiting for DONE")
        return None

    print("Receiving data...")
    try:
        await asyncio.wait_for(collector.end_event.wait(), timeout=DATA_TIMEOUT_S)
    except asyncio.TimeoutError:
        print(f"\nWARNING: Timeout receiving data (got {collector.data_count} samples)")

    if collector.error_msg:
        print(f"\nERROR: {collector.error_msg}")
        return None

    if collector.data_count == 0:
        print("ERROR: No data received")
        return None

    return collector.to_numpy()


# ============================================================================
# SUMMARY + CSV
# ============================================================================

def print_summary(data: dict):
    """Print drill kinematics summary."""
    pos = data["position_m"]
    vel = data["velocity_mps"]
    acc = data["accel_mps2"]
    t   = data["time_s"]

    print(f"\n  Duration:       {t[-1]:.3f} s")
    print(f"  Samples:        {len(t)}")
    print(f"  Sample rate:    {len(t) / t[-1]:.1f} Hz" if t[-1] > 0 else "")
    print(f"  Total distance: {np.max(np.abs(pos)):.4f} m ({np.max(np.abs(pos)) / 0.0254:.2f} in)")
    print(f"  Peak velocity:  {np.max(np.abs(vel)):.3f} m/s ({np.max(np.abs(vel)) * 2.237:.2f} mph)")
    print(f"  Peak accel:     {np.max(acc):.2f} m/s²")
    print(f"  Peak decel:     {np.min(acc):.2f} m/s²")


def save_csv(data: dict, filepath: str):
    """Save drill data to CSV."""
    n = len(data["index"])
    header = "index,time_ms,time_s,position_m,velocity_mps,accel_mps2"

    rows = np.column_stack([
        data["index"],
        data["time_ms"],
        data["time_s"],
        data["position_m"],
        data["velocity_mps"],
        data["accel_mps2"],
    ])

    np.savetxt(
        filepath,
        rows,
        delimiter=",",
        header=header,
        comments="",
        fmt=["%d", "%d", "%.4f", "%.6f", "%.5f", "%.4f"]
    )
    print(f"\n  Saved: {filepath} ({n} rows)")


def print_trial_data(data: dict):
    """Print raw encoder data table."""
    if data is None:
        print("No trial data. Run a trial (f 5 5 or b 5 50) first.")
        return

    time_ms = data["time_ms"]
    pos = data["position_m"]
    vel = data["velocity_mps"]

    print("\n" + "=" * 70)
    print("TRIAL DATA")
    print("=" * 70)
    print(f"{'Idx':<5} {'Time(ms)':<10} {'Position(m)':<14} {'Velocity(m/s)':<14}")
    print("-" * 70)
    step = max(1, len(time_ms) // 20)  # Show ~20 rows
    for i in range(0, len(time_ms), step):
        print(f"{i:<5} {int(time_ms[i]):<10} {pos[i]:<14.4f} {vel[i]:<14.4f}")
    print("-" * 70)
    print(f"Samples: {len(time_ms)}")
    print("=" * 70 + "\n")


def print_options():
    print("  f <sec> <pwm>  forward trial   (sec: 1-10, pwm: 0-100)")
    print("  b <sec> <pwm>  backward trial  (sec: 1-10, pwm: 0-100)")
    print("  d               print data from last trial")
    print("  r               reset (abort in-progress drill)")
    print("  q               quit")
    print()


# ============================================================================
# INTERACTIVE LOOP
# ============================================================================

async def interactive_session(client: BleakClient, collector: DrillDataCollector):
    last_data = None

    while True:
        print_options()
        try:
            loop = asyncio.get_event_loop()
            user = await loop.run_in_executor(None, lambda: input("> "))
        except EOFError:
            break

        user = user.strip().lower()

        if user == "q":
            break

        if user == "d":
            print_trial_data(last_data)
            continue

        if user == "r":
            await client.write_gatt_char(NUS_RX_UUID, b"ABORT\n", response=False)
            print("Reset (ABORT) sent.")
            continue

        parts = user.split()
        if len(parts) != 3:
            print("Usage: f 5 5  or  b 5 50  (direction, seconds 1-10, pwm 0-100)")
            continue

        direction, duration_str, pwm_str = parts[0], parts[1], parts[2]
        if direction not in ("f", "b"):
            print("Direction must be 'f' or 'b'")
            continue

        try:
            duration = int(duration_str)
            pwm_duty = int(pwm_str)
        except ValueError:
            print("Seconds and pwm must be integers")
            continue

        if duration < 1 or duration > 10:
            print("Seconds must be 1-10")
            continue

        if pwm_duty < 0 or pwm_duty > 100:
            print("PWM must be 0-100")
            continue

        data = await run_drill(client, collector, duration, pwm_duty, direction.upper())
        if data is not None:
            last_data = data
            print_summary(data)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            outfile = f"quickburst_drill_{timestamp}.csv"
            save_csv(data, outfile)


# ============================================================================
# MAIN
# ============================================================================

async def main_async():
    print("=" * 50)
    print("QuickBurst PWM + Encoder Control (BLE)")
    print("=" * 50)

    address = await find_device(DEVICE_NAME, SCAN_TIMEOUT_S)

    print(f"\nConnecting to {address}...")
    async with BleakClient(address, timeout=CONNECT_TIMEOUT_S) as client:
        if not client.is_connected:
            print("ERROR: Connection failed")
            return 1

        print(f"  Connected (MTU={client.mtu_size})")

        collector = DrillDataCollector()
        await client.start_notify(NUS_TX_UUID, collector.notification_handler)
        print("  Subscribed to notifications\n")

        await asyncio.sleep(0.5)

        try:
            await interactive_session(client, collector)
        except KeyboardInterrupt:
            print("\n\nInterrupted.")

    print("Disconnected.")
    return 0


def main():
    try:
        exit_code = asyncio.run(main_async())
        sys.exit(exit_code)
    except KeyboardInterrupt:
        print("\n\nAborted by user.")
        sys.exit(130)


if __name__ == "__main__":
    main()
