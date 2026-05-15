# Motor + Encoder + Current Test — Change Log

## 2026-05-06

**Setpoint-gated motion flow**
- `vesc_current_control.py`: added a `Setpoint` UI button and setpoint status readout. Motion/force commands are now blocked in the host until a setpoint is captured.
- `vescNewCurrent.ino`: added `SETPOINT` command support and firmware-side setpoint enforcement so motion commands are refused until setpoint is set.

**Approach behavior near setpoint**
- `vescNewCurrent.ino`: added simple proportional slow-down based on encoder position when within 2 m of setpoint, plus setpoint-reached detection.
- `vescNewCurrent.ino` + `vesc_current_control.py`: when setpoint is reached, firmware emits a non-error info event and repeated STOP acknowledgements; UI reflects this as a stop event (not a safety error).

**Error reset without app restart**
- `vescNewCurrent.ino`: added `SAFETY_RESET` (alias `CLEAR_ERROR`) to clear latched safety-stop state and controller internals so commands can run again immediately.
- `vesc_current_control.py`: clicking the Error indicator now sends `SAFETY_RESET` and clears UI stop/error state on `OK,SAFETY_RESET`.

**Timed run: distance + time stop**
- `vesc_current_control.py`: Run timing panel now includes "Auto-stop after distance (m)" (default 10 m). During timed runs, either condition can end the run: distance threshold OR time threshold (whichever happens first).
- Time-based stop remains active as fallback if distance is not reached.

**Rewind feature**
- `vesc_current_control.py`: added manual `Rewind` button and `Auto-rewind at end of run` checkbox.
- Rewind sequence: `SET_BRAKE,<brake_A>` for 2s, then `STOP`, then `SET_DUTY,0.03` pull-in until firmware setpoint stop is reached.

**iOS Train tab protocol alignment**
- `QuikburstApp/QuikburstApp/TrainTabView.swift`: rebuilt Train UI around `vescNewCurrent.ino` text commands over BLE (`SETPOINT`, `SET_DUTY`, `SET_CURRENT`, `SET_BRAKE`, `STOP`, `ENC_STREAM`, `TELEM_STREAM`).
- Added Train/Monitor sections with forced setpoint gate, force-to-current preview (`2.658 A/lb`), optional distance stop, auto-rewind, manual rewind, hold-to-pull control, and monitor charts (position, velocity, motor current).
- Runs now finalize into a post-stop data popup and are persisted to app history via `SessionResultStore` with encoder traces and derived metrics.

**Setpoint override spool-in**
- `vesc_current_control.py`: added `Override spool-in (hold)` button that commands spool-in at `0.05` duty on press and sends `STOP` on release.
- `vescNewCurrent.ino`: added `OVERRIDE_SPOOL_IN,<duty>` command to bypass setpoint-gated command checks for manual spool-in recovery use cases.

## 2026-04-02

**VESC GUI connect retry**
- `vesc_serial_control.py`: USB connect wrapped in **try/except** (closes port, queues `disconnected`, shows error) so timeouts/exceptions no longer leave **Connect** disabled with status stuck on “Connecting”. **Disconnected** handler now forces status to **Disconnected**. Serial connect thread outer **try/except** catches unexpected crashes. BLE `BleakClient` uses explicit **20s** connect timeout.

**VESC live TELEM graph**
- `vesc_serial_control.py`: default keepalive **0.5s**; live **TELEM** graph (matplotlib) with configurable poll interval (ms) and X-axis time window (s). Layout: **left** = connection + commands + log; **right** = TELEM controls + graph full column height (outer horizontal `PanedWindow`). Telemetry is **request/response** (`GET_VALUES`); live mode polls repeatedly. `requirements.txt`: added `matplotlib`.

**VESC GUI timing + duty cap**
- `vesc_serial_control.py`: auto-stop after N s (0 = until STOP), optional KEEPALIVE interval for VESC UART/APP timeout; applies to motor buttons + matching raw lines. `SET_DUTY` capped at **20%** (matches firmware).
- `vescUartTest.ino`: `SET_DUTY` clamped to **20%** (`VESC_MAX_DUTY`).

**VESC BLE + Python**
- `vesc_serial_control.py`: default UI is **tkinter** (USB + BLE, log, all commands, Help). Terminal mode: `--cli`.
- `vescUartTest.ino`: BLE RX callback uses `String` from `getValue()` for ESP32 Arduino 3.x (not `std::string`).
- `vescUartTest.ino`: BLE peripheral advertising as **Quikburst**, Nordic UART Service (same text commands as USB). USB `Serial` still works. Added `PING` → `PONG,Quikburst` for link checks.
- `vesc_serial_control.py`: `--ble` mode scans by name, connects with **bleak**, runs PING/PONG test, then same interactive commands. USB mode also runs PING test by default (`--no-ping-test` to skip). Added `NewMotorController/requirements.txt` (`pyserial`, `bleak`).

**VESC sketch UART pins**
- `vescUartTest.ino` now uses `Serial2` with configurable `VESC_UART_RX_PIN` / `VESC_UART_TX_PIN` (default GPIO16/GPIO17 for typical RX2/TX2 silkscreen), instead of `D12`/`D11`, which many ESP32 boards do not expose.

## 2026-04-01

**New: VESC UART test pair (NewMotorController/)**
- Rewrote `vescUartTest.ino` from LCD-only telemetry display into a full serial command bridge. ESP32 accepts text commands over USB (`Serial`) and forwards them to a Flipsky VESC over `Serial1` using the SolidGeek/VescUart library.
- Supported commands: `SET_CURRENT`, `SET_BRAKE`, `SET_DUTY`, `SET_RPM`, `STOP`, `GET_VALUES`, `GET_FW`, `KEEPALIVE`. Protocol follows the same newline-terminated text style as the motor_encoder_current test pair.
- Created `vesc_serial_control.py` as the Python companion — interactive CLI with auto port detection, background reader thread, and Ctrl-C safety stop.

## 2026-03-19

**Signed command plot**
- Python command subplot now applies `dir_sign` so `cmd_duty_pct` and `cmd_pwm` are shown as signed motor commands. This makes controller reversals and braking effort visible around 0 instead of looking like a constant positive magnitude.

**Signed current setpoint**
- `CURRENT,...` accepts negative `current_A`; the same P-loop drives toward the signed setpoint (error = setpoint − measured). Python validation and prompts updated; current plot shows a blue setpoint line in current-control mode.

**Current sense polarity**
- Added `CURRENT_SENSE_SIGN` (default `-1.0f` for this hardware) so a positive `CURRENT` setpoint closes on positive reported amps. Set to `+1.0f` if your shunt/INA polarity already matches without a flip.

**Faster current loop**
- Raised the firmware sampling cadence from 100 Hz to 250 Hz as a conservative step up for current control.
- Current sampling now does less ADC work per cycle by caching the zero/reference voltage and refreshing the supply-based reference periodically instead of every sample.

**Quieter active runs**
- Removed non-protocol serial debug chatter during `DRILL` and `CURRENT` runs so the ESP32 mainly sends `READY`, `RUNNING`, `DONE`, `DATA`, `END`, and errors.
- Zero-override feedback is still available, but only emitted outside the active run states.

**More robust timing**
- Post-processing now derives velocity/acceleration from the actual sample timestamps rather than assuming every interval was perfect.
- Data upload after a run is paced by UART buffer availability instead of a fixed per-line delay, so higher sample counts do not spend extra time idling after completion.
- Python no longer prints `READY`, `RUNNING`, and `DONE` markers for every run, which keeps the terminal focused on actual results while preserving the same handshake logic.

## 2026-03-18

**Serial sync + completion handling**
- Python now drains stale serial lines instead of blindly resetting the input buffer before each run.
- Host treats incoming data as proof the run completed even if the `DONE` marker was late or missed, which prevents false disconnect/retry loops.

**Signed current**
- Avg current and est. power are now signed: + = forward/into motor, - = reverse/regen.
- Summary and plot show peak +/-, avg with sign, and 0 A reference line. CSV stores raw signed current_A.

**Current-control timing**
- Firmware current-control now updates motor command and logs data on the same fixed sample cadence.
- Removed duplicate ADC work inside the control loop so the ESP32 is less likely to drift past the expected run-complete timing.

## 2025-03-16

**PWM resolution + float duty**
- PWM resolution increased 10-bit → 12-bit (4096 levels, ~0.024% per step).
- `dutyToPwm(float)` now accepts float; conversion uses full resolution, rounds only at final int. No early rounding of current-control error.
- Drill and current-control both support float duty (e.g. 4.56%). Python prompts and DRILL command accept floats.

**Current control at 0A setpoint**
- Removed firmware override that forced `cmd_duty_pct = 0` when setpoint is 0A. Controller now uses error to cancel back current (e.g. back-EMF when pulling out).
- Added `cmd_pwm` (0–1023) to data output: actual PWM value sent to motor. Both `cmd_duty_pct` and `cmd_pwm` plotted in Python with dual y-axes.
- DATA format extended: `...,cmd_duty_pct,cmd_pwm,dir_sign`. Python parser supports old format (no cmd_pwm).
