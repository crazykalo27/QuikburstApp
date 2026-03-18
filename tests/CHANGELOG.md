# Motor + Encoder + Current Test — Change Log

## 2025-03-16

**PWM resolution + float duty**
- PWM resolution increased 10-bit → 12-bit (4096 levels, ~0.024% per step).
- `dutyToPwm(float)` now accepts float; conversion uses full resolution, rounds only at final int. No early rounding of current-control error.
- Drill and current-control both support float duty (e.g. 4.56%). Python prompts and DRILL command accept floats.

**Current control at 0A setpoint**
- Removed firmware override that forced `cmd_duty_pct = 0` when setpoint is 0A. Controller now uses error to cancel back current (e.g. back-EMF when pulling out).
- Added `cmd_pwm` (0–1023) to data output: actual PWM value sent to motor. Both `cmd_duty_pct` and `cmd_pwm` plotted in Python with dual y-axes.
- DATA format extended: `...,cmd_duty_pct,cmd_pwm,dir_sign`. Python parser supports old format (no cmd_pwm).
