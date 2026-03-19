# Motor + Encoder + Current Test — Change Log

## 2026-03-19

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
