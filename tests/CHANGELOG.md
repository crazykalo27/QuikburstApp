# Motor + Encoder + Current Test — Change Log

## 2025-03-16

**Current control at 0A setpoint**
- Removed firmware override that forced `cmd_duty_pct = 0` when setpoint is 0A. Controller now uses error to cancel back current (e.g. back-EMF when pulling out).
- Added `cmd_pwm` (0–1023) to data output: actual PWM value sent to motor. Both `cmd_duty_pct` and `cmd_pwm` plotted in Python with dual y-axes.
- DATA format extended: `...,cmd_duty_pct,cmd_pwm,dir_sign`. Python parser supports old format (no cmd_pwm).
