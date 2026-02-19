# Project Log

## 2025-02-12 — Train tab: CONTROL.py parity over BLE

**Concept:** Replace CONTROL.py with app for drill control. Train tab: direction, time, pwm → run → view plots. Bluetooth pairing in Profiles → Device Pairing.

**Changes:**
- **BluetoothManager:** Switched to NUS UUIDs (6E400001/2/3) to match pwmAndEncoder.ino. Added drill protocol: sendDrillCommand(duration,pwm,direction), auto-send GO on READY, parse READY/RUNNING/DONE/DATA/END/ERROR/ABORTED. drillState + drillEncoderData published.
- **TrainTabView:** Stripped to CONTROL.py flow: direction (F/B), time (1–10s), pwm (0–100%). Removed connection UI, modes (Constant/Baseline/Live). Loading spinner during armed/running/receiving; plots when done. Drill creation kept elsewhere (Drills tab).

## 2025-02-12 — Encoder count/meters alignment with newEncoderread

**Concept:** Align pwmAndEncoder.ino + CONTROL.py encoder logic with AhaanEncoder/newEncoderread.ino and newEncoderVis.py.

**Changes:**
- **pwmAndEncoder.ino:** Spool geometry fixed to match newEncoderread: use SPOOL_DIA_INCHES (4.0) and circumference = π × d × 0.0254 m/in. Was incorrectly using SPOOL_RADIUS_M=4 and 2πr. Count reading and conversion formula were already identical.
- **CONTROL.py:** Added HARDWARE MATH docstring reference (matches newEncoderVis). Python receives pre-converted position_m from ESP32; no conversion logic changes.

## 2025-02-12 — pwmAndEncoder + CONTROL: BLE, encoder data after drill

**Concept:** Pair pwmAndEncoder.ino + CONTROL.py now use BLE (Nordic UART) instead of serial. Motor runs during drill only; encoder data from that run is captured, processed on ESP32, then transmitted over BLE after drill ends.

**Changes:**
- **pwmAndEncoder.ino:** Added BLE (NUS), state machine IDLE→ARMED→RUNNING→PROCESSING→SENDING. DRILL,<s>,<pwm>,<F|B> → GO. Motor control during RUNNING; encoder sampled at 100 Hz. Processing pipeline (median + MA) from newEncoderread. Transmits DATA lines + END.
- **CONTROL.py:** Switched from pyserial to bleak. Interactive terminal: `f 5 5`, `b 5 50`, `d`, `r`, `q`. Saves each drill to timestamped CSV. Prints distance, peak velocity, acceleration summary.
