"""
============================================================================
QuickBurst BLE Encoder Client — Python
============================================================================

PURPOSE:
    Connects to QuickBurst ESP32 over BLE Nordic UART Service,
    sends DRILL → GO sequence, collects processed kinematics data,
    saves to CSV.

DEPENDENCIES:
    pip install bleak numpy

USAGE:
    python quickburst_ble_client.py
    python quickburst_ble_client.py --duration 10
    python quickburst_ble_client.py --duration 10 --output my_drill.csv

BLE CONTRACT:
    Service: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E  (Nordic UART)
    RX:      6E400002-B5A3-F393-E0A9-E50E24DCCA9E  (App → ESP32, write)
    TX:      6E400003-B5A3-F393-E0A9-E50E24DCCA9E  (ESP32 → App, notify)

    Commands sent:      DRILL,<seconds>\n  →  GO\n
    Expected responses: READY,<seconds>\n  →  RUNNING\n  →  DONE\n
                        DATA,index,time_ms,position_m,velocity_mps,accel_mps2\n ...
                        END\n

HARDWARE MATH (for reference — processing is done on ESP32):
    Encoder: Taiss 600 PPR, x4 quadrature → 2400 CPR
    Spool:   0.5 in diameter → C = π × 0.5 × 0.0254 = 0.039898 m
    Resolution: 0.039898 / 2400 = 1.66243e-5 m/count ≈ 0.0166 mm

============================================================================
"""

import asyncio
import argparse
import sys
import time
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

DEFAULT_DURATION_S  = 5
DEFAULT_OUTPUT_FILE = None  # Auto-generate timestamped filename if None

# BLE UUIDs — Nordic UART Service
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_UUID      = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # Write to this
NUS_TX_UUID      = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # Notifications from this

# Timeouts for state transitions
READY_TIMEOUT_S     = 5.0
RUNNING_TIMEOUT_S   = 5.0
DONE_TIMEOUT_S      = None   # Computed from drill duration
DATA_TIMEOUT_S      = 120.0  # Max time to receive all DATA + END


# ============================================================================
# DATA COLLECTOR
# ============================================================================

class DrillDataCollector:
    """
    Collects and parses BLE notifications from QuickBurst ESP32.
    Handles partial BLE packets via line-buffering.
    """

    def __init__(self):
        # Parsed data storage
        self.indices       = []
        self.times_ms      = []
        self.positions_m   = []
        self.velocities    = []
        self.accelerations = []

        # State tracking
        self.ready_event   = asyncio.Event()
        self.running_event = asyncio.Event()
        self.done_event    = asyncio.Event()
        self.end_event     = asyncio.Event()
        self.error_msg     = None

        # BLE packet reassembly buffer
        self._rx_buffer = ""

        # Statistics
        self.data_count    = 0
        self.parse_errors  = 0

    def notification_handler(self, sender, data: bytearray):
        """
        BLE notification callback. Accumulates bytes and processes
        complete lines. Handles partial packets safely.

        BLE notifications may split a single logical message across
        multiple packets, or combine multiple messages in one packet.
        Line-buffering on '\\n' handles both cases.
        """
        try:
            text = data.decode("utf-8", errors="replace")
        except Exception:
            return

        self._rx_buffer += text

        # Process all complete lines
        while "\n" in self._rx_buffer:
            line, self._rx_buffer = self._rx_buffer.split("\n", 1)
            line = line.strip()
            if line:
                self._process_line(line)

    def _process_line(self, line: str):
        """Parse a single complete line from ESP32."""

        # --- READY,<seconds> ---
        if line.startswith("READY,"):
            duration = line.split(",", 1)[1]
            print(f"  [ESP32] READY (duration={duration}s)")
            self.ready_event.set()
            return

        # --- RUNNING ---
        if line == "RUNNING":
            print(f"  [ESP32] RUNNING")
            self.running_event.set()
            return

        # --- DONE ---
        if line == "DONE":
            print(f"  [ESP32] DONE")
            self.done_event.set()
            return

        # --- DATA,index,time_ms,position_m,velocity_mps,accel_mps2 ---
        if line.startswith("DATA,"):
            self._parse_data_line(line)
            return

        # --- END ---
        if line == "END":
            print(f"  [ESP32] END — received {self.data_count} data points")
            self.end_event.set()
            return

        # --- ABORTED ---
        if line == "ABORTED":
            self.error_msg = "Drill aborted by ESP32"
            self.end_event.set()
            return

        # --- ERROR,<reason> ---
        if line.startswith("ERROR,"):
            reason = line.split(",", 1)[1]
            self.error_msg = f"ESP32 error: {reason}"
            print(f"  [ESP32] ERROR: {reason}")
            self.end_event.set()
            return

        # Unknown
        print(f"  [ESP32] {line}")

    def _parse_data_line(self, line: str):
        """
        Parse: DATA,index,time_ms,position_m,velocity_mps,accel_mps2
        All fields are numeric. Robust to minor formatting issues.
        """
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

        # Progress indicator every 100 samples
        if self.data_count % 100 == 0:
            print(f"    ... received {self.data_count} samples", end="\r")

    def to_numpy(self):
        """Convert collected data to numpy arrays."""
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
    """Scan for BLE device by name. Returns address."""
    print(f"Scanning for '{name}' (timeout={timeout}s)...")

    device = await BleakScanner.find_device_by_name(
        name, timeout=timeout
    )

    if device is None:
        print(f"\nERROR: Device '{name}' not found.")
        print("Troubleshooting:")
        print("  1. Ensure ESP32 is powered and running firmware")
        print("  2. Check Serial Monitor for '[BLE] Advertising' message")
        print("  3. Verify no other device is connected to the ESP32")
        print("  4. Try resetting the ESP32")
        sys.exit(1)

    print(f"  Found: {device.name} [{device.address}]")
    return device.address


# ============================================================================
# DRILL EXECUTION
# ============================================================================

async def run_drill(duration_s: int, output_file: str):
    """
    Full drill sequence:
        1. Scan and connect to ESP32
        2. Subscribe to TX notifications
        3. Send DRILL,<seconds>
        4. Wait for READY
        5. Send GO
        6. Wait for RUNNING → DONE → DATA... → END
        7. Save CSV
    """
    print("=" * 60)
    print("QuickBurst BLE Encoder Client")
    print("=" * 60)
    print(f"  Drill duration: {duration_s}s")
    print(f"  Output file:    {output_file}")
    print()

    # --- Step 1: Find device ---
    address = await find_device(DEVICE_NAME, SCAN_TIMEOUT_S)

    # --- Step 2: Connect ---
    print(f"Connecting to {address}...")

    async with BleakClient(address, timeout=CONNECT_TIMEOUT_S) as client:
        if not client.is_connected:
            print("ERROR: Connection failed")
            return False

        print(f"  Connected (MTU={client.mtu_size})")

        # --- Step 3: Subscribe to notifications ---
        collector = DrillDataCollector()
        await client.start_notify(NUS_TX_UUID, collector.notification_handler)
        print("  Subscribed to notifications")

        # Small delay to let BLE stack settle
        await asyncio.sleep(0.5)

        # --- Step 4: Send DRILL command ---
        drill_cmd = f"DRILL,{duration_s}\n".encode("utf-8")
        print(f"\nSending: DRILL,{duration_s}")
        await client.write_gatt_char(NUS_RX_UUID, drill_cmd, response=False)

        # Wait for READY
        try:
            await asyncio.wait_for(
                collector.ready_event.wait(), timeout=READY_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            print("ERROR: Timeout waiting for READY")
            return False

        # --- Step 5: Send GO ---
        print("Sending: GO")
        await client.write_gatt_char(NUS_RX_UUID, b"GO\n", response=False)

        # Wait for RUNNING
        try:
            await asyncio.wait_for(
                collector.running_event.wait(), timeout=RUNNING_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            print("ERROR: Timeout waiting for RUNNING")
            return False

        # --- Step 6: Wait for drill to complete ---
        done_timeout = duration_s + 5.0  # Extra margin
        print(f"\nDrill in progress ({duration_s}s)...")

        try:
            await asyncio.wait_for(
                collector.done_event.wait(), timeout=done_timeout
            )
        except asyncio.TimeoutError:
            print("ERROR: Timeout waiting for DONE")
            return False

        # --- Step 7: Receive DATA stream ---
        print("Receiving data...")

        try:
            await asyncio.wait_for(
                collector.end_event.wait(), timeout=DATA_TIMEOUT_S
            )
        except asyncio.TimeoutError:
            print(f"\nWARNING: Timeout receiving data (got {collector.data_count} samples)")

        # Check for errors
        if collector.error_msg:
            print(f"\nERROR: {collector.error_msg}")
            return False

        # --- Step 8: Process and save ---
        print(f"\n{'=' * 60}")
        print("DRILL COMPLETE")
        print(f"{'=' * 60}")
        print(f"  Samples received: {collector.data_count}")
        print(f"  Parse errors:     {collector.parse_errors}")

        if collector.data_count == 0:
            print("ERROR: No data received")
            return False

        data = collector.to_numpy()
        print_summary(data)
        save_csv(data, output_file)

        await client.stop_notify(NUS_TX_UUID)

    return True


# ============================================================================
# SUMMARY + CSV OUTPUT
# ============================================================================

def print_summary(data: dict):
    """Print drill kinematics summary."""
    pos = data["position_m"]
    vel = data["velocity_mps"]
    acc = data["accel_mps2"]
    t   = data["time_s"]

    print(f"\n  Duration:         {t[-1]:.3f} s")
    print(f"  Samples:          {len(t)}")
    print(f"  Sample rate:      {len(t) / t[-1]:.1f} Hz" if t[-1] > 0 else "")
    print(f"  Total distance:   {np.max(np.abs(pos)):.4f} m "
          f"({np.max(np.abs(pos)) / 0.0254:.2f} in)")
    print(f"  Peak velocity:    {np.max(np.abs(vel)):.3f} m/s "
          f"({np.max(np.abs(vel)) * 2.237:.2f} mph)")
    print(f"  Peak accel:       {np.max(acc):.2f} m/s²")
    print(f"  Peak decel:       {np.min(acc):.2f} m/s²")


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


# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="QuickBurst BLE Encoder Client"
    )
    parser.add_argument(
        "--duration", "-d",
        type=int,
        default=DEFAULT_DURATION_S,
        help=f"Drill duration in seconds (default: {DEFAULT_DURATION_S})"
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        default=DEFAULT_OUTPUT_FILE,
        help="Output CSV file path (default: auto-generated)"
    )
    args = parser.parse_args()

    # Auto-generate output filename if not specified
    if args.output is None:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        args.output = f"quickburst_drill_{timestamp}.csv"

    try:
        success = asyncio.run(run_drill(args.duration, args.output))
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print("\n\nAborted by user.")
        sys.exit(130)


if __name__ == "__main__":
    main()