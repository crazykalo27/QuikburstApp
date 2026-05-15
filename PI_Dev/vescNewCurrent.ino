/*
 * VESC UART Test — ESP32 ↔ host (BLE only) ↔ VESC (UART2)
 *
 * Host link: Nordic UART Service (NUS); advertised name "Quikburst" for discovery.
 *
 * VESC: Serial2 @ VESC_UART_RX_PIN / VESC_UART_TX_PIN (see below).
 *
 * Protocol (newline-terminated; BLE Nordic UART RX writes, TX notifications):
 *   PING                      → PONG,Quikburst
 *   SET_CURRENT,<amps>        → OK,SET_CURRENT,...
 *   SET_BRAKE[,<amps>]       → OK,SET_BRAKE[,<amps>] (omit <amps> to use VESC_BRAKE_APPLY_AMPS; VESC clamps)
 *   SET_DUTY,<duty>           → duty clamped to 0…0.25 (25%)
 *   STOP                      → OK,STOP
 *   GET_VALUES                → TELEM,esp32_ms,rpm,duty,vbat,imotor,iin,tmos,tmotor,tach,tachAbs,fault
 *                               (esp32_ms = millis() when line is sent; same clock as ENC time_ms)
 *   GET_FW                    → FW,...
 *   KEEPALIVE                 → OK,KEEPALIVE
 *   ENC_RESET                 → OK,ENC_RESET (zero encoder count / position)
 *   ENC_STREAM,<0|1>[,<ms>]  → OK,ENC_STREAM,<on>,<ms> (enable/disable + optional interval; default 25 ms)
 *   TELEM_STREAM,<0|1>[,<ms>]→ OK,TELEM_STREAM,<on>,<ms> (firmware-pushed TELEM at <ms> cadence;
 *                               default 25 ms. Replaces polled GET_VALUES — each sample costs one BLE
 *                               notify instead of a request/response round-trip.)
 *   ENC,...                   — streamed when ENC_STREAM on (BLE):
 *                               ENC,time_ms,count,position_m,velocity_mps
 *                               (same quadrature + spool geometry as ahaan100/encoder.ino)
 *   TELEM,...                 — streamed when TELEM_STREAM on (BLE), same payload as GET_VALUES reply.
 *
 *   PI current controller (port of PI_Dev/PI_ex1.ino — runs on ESP32 at fixed Hz):
 *   PI_ENABLE,<0|1>           → OK,PI_ENABLE,<on>      (resets integrator on enable; setCurrent(0) on disable)
 *   PI_FORCE,<lbs>            → OK,PI_FORCE,<lbs>,<amps>   (target current = amps_per_lb * lbs)
 *   PI_TARGET,<amps>          → OK,PI_TARGET,<amps>        (force-bypass; sets target current directly)
 *   PI_HZ,<hz>                → OK,PI_HZ,<hz>              (target loop frequency, 1–500)
 *   PI_GAINS,<Kp>,<Ki>        → OK,PI_GAINS,<Kp>,<Ki>
 *   PI_PARAMS,<Kt>,<Ke>,<R>,<L> → OK,PI_PARAMS,...
 *   PI_LIMITS,<I_max>,<I_int_max>,<amps_per_lb>,<pole_pairs> → OK,PI_LIMITS,...
 *   PI_CONFIG                 → PICFG,Kt,Ke,R,L,Kp,Ki,I_max,I_int_max,amps_per_lb,pole_pairs,target_hz,enabled,target_lb,target_a
 *   PICTRL,...                — streamed from PI loop:
 *                               PICTRL,esp32_ms,i_target_a,i_meas_a,i_cmd_a,omega_rps,actual_hz,target_lb,i_error_a,i_ff_a,i_int_a,i_cmd_unsat_a,back_emf_a
 *   [READY]                   — periodic heartbeat to BLE when connected
 *
 * BLE UUIDs (Nordic UART Service — works with bleak / nRF Connect):
 *   Service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *   RX (host writes) 6E400002-B5A3-F393-E0A9-E50E24DCCA9E
 *   TX (notify)      6E400003-B5A3-F393-E0A9-E50E24DCCA9E
 *
 * BLE reconnect: after a central disconnects, advertising is restarted from loop() (~400 ms later)
 * so you can scan and connect again without power-cycling the ESP32.
 *
 * Status LEDs (active HIGH):
 *   GPIO 27 — on while firmware is running and not BLE-connected (idle advertising).
 *   GPIO 26 — on while BLE host is connected (27 off) unless motor is active.
 *   When motor is commanded non-idle (current / duty / brake): both 26 and 27 on.
 */

 #include <VescUart.h>
 #include <math.h>
 #include <stdarg.h>
 #include <BLEDevice.h>
 #include <BLEServer.h>
 #include <BLEUtils.h>
 #include <BLE2902.h>
 
 // UART2 to VESC
 #if !defined(VESC_UART_RX_PIN) || !defined(VESC_UART_TX_PIN)
 #define VESC_UART_RX_PIN 16
 #define VESC_UART_TX_PIN 17
 #endif
 
 // Max duty cycle for SET_DUTY (fraction 0–1); matches Python GUI cap.
 #ifndef VESC_MAX_DUTY
 #define VESC_MAX_DUTY 0.25f
 #endif
 
 // Default brake current when host sends SET_BRAKE with no comma argument; VESC still enforces its own limits.
 #ifndef VESC_BRAKE_APPLY_AMPS
 #define VESC_BRAKE_APPLY_AMPS 120.0f
 #endif
 
 // ---------------------------------------------------------------------------
 // Rotary encoder — matches ahaan100/encoder.ino (linear distance from spool)
 // ---------------------------------------------------------------------------
 
 #ifndef ENC_PIN_A
 #define ENC_PIN_A 33
 #endif
 #ifndef ENC_PIN_B
 #define ENC_PIN_B 25
 #endif
 
 static const int     ENCODER_PPR        = 600;
 static const int     QUADRATURE_MULT    = 4;
 static const int     COUNTS_PER_REV     = ENCODER_PPR * QUADRATURE_MULT;
 
 static const float   SPOOL_DIA_INCHES   = 4.0f;
 static const float   SPOOL_CIRCUMF_M    = 3.14159265f * SPOOL_DIA_INCHES * 0.0254f;
 static const float   METERS_PER_COUNT   = SPOOL_CIRCUMF_M / (float)COUNTS_PER_REV;
 
 // Spool radius for omega calculation: v = omega * r  →  omega = v / r
 // Motor has 1:1 ratio with spool, so motor omega == spool omega.
 static const float   SPOOL_RADIUS_M     = (SPOOL_DIA_INCHES * 0.0254f) / 2.0f;
 
 // Velocity update interval for the PI feedforward — independent of BLE emit rate.
 // At 5 ms (200 Hz) this is comfortably faster than the ~90 Hz PI loop.
 static const uint32_t ENC_VEL_UPDATE_MS = 5;
 
 // ENC stream interval is runtime-configurable via ENC_STREAM,<on>,<ms>. Default is 25 ms (40 Hz);
 // at a 15 ms BLE connection interval (macOS floor) the link has only ~67 notify slots/s total,
 // so with TELEM on use a similar interval for both (defaults: 25 ms each) so neither stream starves.
 #ifndef ENC_STREAM_DEFAULT_MS
 #define ENC_STREAM_DEFAULT_MS 25
 #endif
 static const uint32_t ENC_STREAM_MIN_MS = 1;
 static const uint32_t ENC_STREAM_MAX_MS = 1000;
 
 volatile int32_t g_encoderCount = 0;
 volatile int8_t  g_lastEncoded  = 0;
 bool             g_encResetPending  = false;
 bool             g_encStreamEnabled = true;
 uint32_t         g_encStreamIntervalMs = ENC_STREAM_DEFAULT_MS;
 
 // Firmware-pushed TELEM. When enabled, loop() calls UART.getVescValues() every g_telemStreamIntervalMs
 // and emits one TELEM line — no host GET_VALUES required. Kills one BLE direction per sample vs polling.
 #ifndef TELEM_STREAM_DEFAULT_MS
 #define TELEM_STREAM_DEFAULT_MS 25
 #endif
 static const uint32_t TELEM_STREAM_MIN_MS = 5;
 static const uint32_t TELEM_STREAM_MAX_MS = 5000;
 
 bool      g_telemStreamEnabled = false;
 uint32_t  g_telemStreamIntervalMs = TELEM_STREAM_DEFAULT_MS;
 
 // ---------------------------------------------------------------------------
 // PI current controller (port of PI_Dev/PI_ex1.ino)
 // ---------------------------------------------------------------------------
 // Loop runs on ESP32 at a fixed target Hz. Host sends a FORCE (lbs); firmware
 // converts to a target current with one named line below, then runs the same
 // PI law from PI_ex1.ino with anti-windup back-calculation. setCurrent(i_cmd)
 // is sent to the VESC each cycle.
 //
 // Omega is derived from the rope encoder (1:1 spool-to-motor ratio) rather than
 // VESC RPM, which reads zero during backdrive / passive generation.
 //
 // Practical Hz floor is the VESC UART read (~10 ms / 115200 baud), so 50 Hz is
 // tight, 100 Hz is the ceiling, and PICTRL emit is decimated to ≤ ~100 Hz so
 // BLE doesn't choke when the loop runs faster than that.
 
 struct PiCfg {
   float Kt;          // N·m/A   — info only (not used in current loop here)
   float Ke;          // V·s/rad — feedforward back-EMF cancellation
   float R;           // Ohms    — feedforward back-EMF cancellation
   float L;           // H       — info only
   float Kp;          // A/A
   float Ki;          // A/(A·s)
   float I_max;       // A       — symmetric saturation limit (signed)
   float I_int_max;   // A       — symmetric integrator clamp limit (signed)
   float amps_per_lb; // A/lb    — force → current scale (CLEAR EQUATION)
   int   pole_pairs;  // kept for reference; omega now comes from encoder not VESC RPM
   uint32_t target_hz;
 };
 
 static PiCfg g_pi = {
   /*Kt*/ 0.085f,
   /*Ke*/ 0.0859f,
   /*R*/  0.4f,
   /*L*/  0.0003f,
   /*Kp*/ 0.5f,
   /*Ki*/ 3.0f,
   /*I_max*/ 8.0f,
   /*I_int_max*/ 5.0f,
   /*amps_per_lb*/ 4.44822f*2.0f*0.0254f/0.085f,    // Fdes*4.44822[N/lbf]*2[in]*0.0254[m/in]/Kt[Nm/A]
   /*pole_pairs*/ 7,
   /*target_hz*/ 50
 };
 
 static bool     g_piEnabled       = false;
 static float    g_piTargetLbs     = 0.0f;
 static float    g_piTargetAmps    = 0.0f;
 static float    g_piIntegrator    = 0.0f;
 static float    g_piTPrevS        = -1.0f;   // <0 ⇒ not-yet-initialized
 static uint32_t g_piT0Us          = 0;       // µs anchor so float t_s stays precise
 static uint32_t g_piLastTickUs    = 0;
 static uint32_t g_piPeriodEmaUs   = 0;       // smoothed actual loop period
 static uint32_t g_piEmitDecimCnt  = 0;
 static uint32_t g_piEmitEveryN    = 1;
 static uint32_t g_piLastUartMs    = 0;       // shared with TELEM (avoid double-read)
 
 // Runtime toggle: reset integrator when i_target crosses zero
 static bool g_piResetIntOnCrossing = true;
 
 // Latest snapshot for any external consumer (TELEM passthrough, debug)
 static float g_piIMeas = 0.0f;
 static float g_piOmega = 0.0f;
 static float g_piICmd  = 0.0f;
 static float g_piError = 0.0f;
 static float g_piFF = 0.0f;
 static float g_piICmdUnsat = 0.0f;
 static float g_piBackEmf = 0.0f;
 static float g_piTargetAmpsPrev = 0.0f;      // previous i_target for zero-crossing detection
 
 static uint32_t g_encoderLastSeenMs = 0;
 static float    g_lastEncoderVelMps = 0.0f;
 static float    g_lastEncoderPosM = 0.0f;
 static uint32_t g_telemetryLastSeenMs = 0;
 static uint32_t g_velocityOverLimitSinceMs = 0;
 static uint32_t g_currentOverLimitSinceMs  = 0;
 static uint32_t g_negativeCurrentStartMs   = 0;
 static uint32_t g_safetyLastSampleMs       = 0;
 static const uint32_t SAFETY_MONITOR_MS    = 25;
 static bool     g_safetyStopEngaged = false;
 
 // Setpoint guard + approach handling
 static bool  g_setpointDefined = false;
 static float g_setpointPosM = 0.0f;
 static bool  g_setpointApproachActive = false;
 static uint8_t g_setpointStopBurstRemaining = 0;
 static uint32_t g_setpointStopBurstLastMs = 0;
 
 enum DirectCommandMode : uint8_t {
   DIRECT_CMD_NONE = 0,
   DIRECT_CMD_CURRENT,
   DIRECT_CMD_BRAKE,
   DIRECT_CMD_DUTY
 };
 
 static DirectCommandMode g_directMode = DIRECT_CMD_NONE;
 static float g_directBaseCmd = 0.0f;
 static uint32_t g_directApplyLastMs = 0;
 
 static const float SETPOINT_SLOWDOWN_START_M = 2.0f;
 static const float SETPOINT_REACHED_TOL_M = 1.0f;
 static const uint32_t SETPOINT_DIRECT_APPLY_MS = 25;
 static const uint32_t SETPOINT_STOP_BURST_MS = 60;
 static const uint8_t SETPOINT_STOP_BURST_COUNT = 4;
 
 void IRAM_ATTR updateEncoder() {
   int8_t a       = (int8_t)digitalRead(ENC_PIN_A);
   int8_t b       = (int8_t)digitalRead(ENC_PIN_B);
   int8_t encoded = (a << 1) | b;
   int8_t sum     = (g_lastEncoded << 2) | encoded;
 
   if (sum == 0b1101 || sum == 0b0100 || sum == 0b0010 || sum == 0b1011) g_encoderCount++;
   if (sum == 0b1110 || sum == 0b0111 || sum == 0b0001 || sum == 0b1000) g_encoderCount--;
 
   g_lastEncoded = encoded;
 }
 
 extern VescUart UART;
 
 static float inferCurrentSign(float i_raw, float duty, float vel_mps) {
   if (i_raw < 0.0f) return i_raw;
   float a = fabsf(i_raw);
   if (a < 1e-6f) return 0.0f;
   if (fabsf(duty) > 1e-5f) {
     return (duty > 0.0f) ? a : -a;
   }
   if (fabsf(vel_mps) >= 0.1f) {
     return (vel_mps > 0.0f) ? a : -a;
   }
   return a;
 }
 
 static bool monitorSafety(uint32_t nowMs) {
   float i_raw = UART.data.avgMotorCurrent;
   float i_meas = inferCurrentSign(i_raw, UART.data.dutyCycleNow, g_lastEncoderVelMps);
 
   // Safety constraint: if motor current stays below -1 A for >= 1 second, stop.
   if (i_meas <= -1.0f) {
     if (g_negativeCurrentStartMs == 0) {
       g_negativeCurrentStartMs = nowMs;
     } else if (nowMs - g_negativeCurrentStartMs >= 1000) {
       triggerSafetyStop("SUSTAINED_NEGATIVE_CURRENT");
       enforceSafetyStop();
       return true;
     }
   } else {
     g_negativeCurrentStartMs = 0;
   }
 
   // Safety constraint: if duty cycle reaches or exceeds the 25% hard ceiling, stop.
   if (UART.data.dutyCycleNow >= VESC_MAX_DUTY) {
     triggerSafetyStop("DUTY_OVER_LIMIT");
     enforceSafetyStop();
     return true;
   }
 
   // Safety constraint: if velocity is at or over 10 m/s for 0.5 seconds continuously, stop.
   if (fabsf(g_lastEncoderVelMps) >= 10.0f) {
     if (g_velocityOverLimitSinceMs == 0) {
       g_velocityOverLimitSinceMs = nowMs;
     } else if (nowMs - g_velocityOverLimitSinceMs >= 500) {
       triggerSafetyStop("VELOCITY_OVER_10MPS");
       enforceSafetyStop();
       return true;
     }
   } else {
     g_velocityOverLimitSinceMs = 0;
   }
 
   // Safety constraint: if motor current stays high for 1 second, stop.
   if (fabsf(i_meas) >= 30.0f) {
     if (g_currentOverLimitSinceMs == 0) {
       g_currentOverLimitSinceMs = nowMs;
     } else if (nowMs - g_currentOverLimitSinceMs >= 1000) {
       triggerSafetyStop("CURRENT_OVER_30A");
       enforceSafetyStop();
       return true;
     }
   } else {
     g_currentOverLimitSinceMs = 0;
   }
 
   // Safety constraint: if VESC telemetry is not received for over 1 second, stop.
   if (g_telemetryLastSeenMs != 0 && (nowMs - g_telemetryLastSeenMs) >= 1000) {
     triggerSafetyStop("VESC_TELEMETRY_LOST");
     enforceSafetyStop();
     return true;
   }
   /*
   // Safety constraint: if the encoder stops providing stream data for 5 seconds while current is present, stop.
   if (g_encStreamEnabled && g_encoderLastSeenMs != 0 && (nowMs - g_encoderLastSeenMs) >= 5000 && fabsf(i_meas) > 0.5f) {
     triggerSafetyStop("ENCODER_LOST_WITH_CURRENT");
     enforceSafetyStop();
     return true;
   }
     */
     
   return false;
 }
 
 static void pollSafety(uint32_t nowMs) {
   if (g_safetyStopEngaged) return;
 
   if (g_piEnabled && g_piLastUartMs != 0 && (nowMs - g_piLastUartMs) < SAFETY_MONITOR_MS) {
     monitorSafety(nowMs);
     return;
   }
   if (nowMs - g_safetyLastSampleMs < SAFETY_MONITOR_MS) return;
 
   g_safetyLastSampleMs = nowMs;
   if (UART.getVescValues()) {
     g_piLastUartMs = nowMs;
     g_telemetryLastSeenMs = nowMs;
     monitorSafety(nowMs);
   }
 }
 
 static void pollEncoderStream(uint32_t nowMs) {
   static uint32_t lastSampleMs    = 0;   // BLE emit timer
   static uint32_t lastVelUpdateMs = 0;   // fast velocity timer
   static float    lastPosForVelM  = 0.0f;
   static float    lastPosM        = 0.0f;
   static uint32_t lastPosMs       = 0;
   static bool     lastStreamOn    = false;
 
   if (g_encStreamEnabled != lastStreamOn) {
     lastStreamOn    = g_encStreamEnabled;
     lastSampleMs    = 0;
     lastVelUpdateMs = 0;
   }
 
   if (!g_encStreamEnabled) {
     return;
   }
 
   // --- Fast velocity update (200 Hz) --------------------------------------
   // Always runs when stream is enabled so g_lastEncoderVelMps stays current
   // for the PI loop even when BLE emit is gated.
   if (lastVelUpdateMs == 0 || (nowMs - lastVelUpdateMs) >= ENC_VEL_UPDATE_MS) {
     noInterrupts();
     int32_t countFast = g_encoderCount;
     interrupts();
     float posNow = (float)countFast * METERS_PER_COUNT;
     if (lastVelUpdateMs != 0) {
       float dt_s = (float)(nowMs - lastVelUpdateMs) / 1000.0f;
       if (dt_s > 0.0f)
         g_lastEncoderVelMps = (posNow - lastPosForVelM) / dt_s;
     }
     g_lastEncoderPosM = posNow;
     lastPosForVelM  = posNow;
     lastVelUpdateMs = nowMs;
     g_encoderLastSeenMs = nowMs;
   }
 
   // --- Slow BLE emit (g_encStreamIntervalMs, default 25 ms) ---------------
   if (lastSampleMs == 0) {
     lastSampleMs = nowMs;
     noInterrupts();
     int32_t c0 = g_encoderCount;
     interrupts();
     lastPosM  = (float)c0 * METERS_PER_COUNT;
     lastPosMs = nowMs;
     return;
   }
 
   if (nowMs - lastSampleMs < g_encStreamIntervalMs) return;
   lastSampleMs = nowMs;
 
   noInterrupts();
   int32_t count = g_encoderCount;
   interrupts();
 
   float posM = (float)count * METERS_PER_COUNT;
 
   if (g_encResetPending) {
     g_encResetPending = false;
     lastPosM  = posM;
     lastPosMs = nowMs;
   }
 
   float dt_s = (float)(nowMs - lastPosMs) / 1000.0f;
   float velMps = (dt_s > 0.0f) ? (posM - lastPosM) / dt_s : 0.0f;
 
   sendHostFmt("ENC,%lu,%ld,%.5f,%.4f",
       (unsigned long)nowMs, (long)count, posM, velMps);
 
   lastPosM  = posM;
   lastPosMs = nowMs;
 }
 
 static constexpr char BLE_DEVICE_NAME[] = "Quikburst";
 
 #define NUS_SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
 #define NUS_RX_UUID             "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
 #define NUS_TX_UUID             "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
 
 VescUart UART;
 
 static String g_bleCmdBuf;
 
 static constexpr uint32_t READY_INTERVAL_MS = 5000;
 static uint32_t g_lastReadyMs = 0;
 
 static BLEServer* g_server = nullptr;
 static BLECharacteristic* g_txChar = nullptr;
 static bool g_bleConnected = false;
 // After a central disconnects, restart advertising from loop() once this deadline passes
 // (avoids doing heavy BLE work inside the disconnect callback; fixes reconnect without power cycle).
 static uint32_t g_bleAdvRestartAtMs = 0;
 
 #ifndef STATUS_LED_BLE_PIN
 #define STATUS_LED_BLE_PIN 26
 #endif
 #ifndef STATUS_LED_ON_PIN
 #define STATUS_LED_ON_PIN 27
 #endif
 
 static bool g_motorActive = false;
 
 static void updateStatusLeds() {
   const int pBle = STATUS_LED_BLE_PIN;
   const int pOn = STATUS_LED_ON_PIN;
   if (g_motorActive) {
     digitalWrite(pBle, HIGH);
     digitalWrite(pOn, HIGH);
   } else if (g_bleConnected) {
     digitalWrite(pBle, HIGH);
     digitalWrite(pOn, LOW);
   } else {
     digitalWrite(pBle, LOW);
     digitalWrite(pOn, HIGH);
   }
 }
 
 // ---------------------------------------------------------------------------
 // Host output: BLE notify only (chunked; client should reassemble to lines)
 // ---------------------------------------------------------------------------
 
 static void sendBleRaw(const uint8_t* data, size_t len) {
   if (!g_bleConnected || !g_txChar || len == 0) return;
   // Python side negotiates ATT MTU 247 (usable payload ~244). Use 180 so a full
   // TELEM / ENC line fits in a single notify — was kChunk=20 with delay(3),
   // which blocked loop() ~12 ms per TELEM and ~6 ms per ENC. The BLE stack
   // has its own TX flow control, so no per-chunk sleep is needed.
   constexpr size_t kChunk = 180;
   size_t off = 0;
   while (off < len) {
     size_t n = len - off;
     if (n > kChunk) n = kChunk;
     g_txChar->setValue(data + off, n);
     g_txChar->notify();
     off += n;
   }
 }
 
 static void sendHostLine(const char* line) {
   if (!g_bleConnected || !g_txChar) return;
   String s(line);
   s += '\n';
   sendBleRaw((const uint8_t*)s.c_str(), s.length());
 }
 
 static void sendHostFmt(const char* fmt, ...) {
   char buf[256];
   va_list args;
   va_start(args, fmt);
   vsnprintf(buf, sizeof(buf), fmt, args);
   va_end(args);
   sendHostLine(buf);
 }
 
 // ---------------------------------------------------------------------------
 // Command parsing (shared)
 // ---------------------------------------------------------------------------
 
 static float parseFloat(const String& s) {
   String t = s;
   t.trim();
   return t.toFloat();
 }
 
 // Parse "<on>[,<ms>]" arguments for *_STREAM commands. Returns true if <ms> was present (and
 // already clamped into [min_ms, max_ms] and written back into out_ms); on-flag always goes to out_on.
 static bool parseStreamArgs(const String& args, bool& out_on, uint32_t& out_ms,
                             uint32_t min_ms, uint32_t max_ms) {
   int comma = args.indexOf(',');
   if (comma < 0) {
     out_on = parseFloat(args) != 0.0f;
     return false;
   }
   out_on = parseFloat(args.substring(0, comma)) != 0.0f;
   long ms = (long)parseFloat(args.substring(comma + 1));
   if (ms < (long)min_ms) ms = (long)min_ms;
   if (ms > (long)max_ms) ms = (long)max_ms;
   out_ms = (uint32_t)ms;
   return true;
 }
 
 // Assemble the TELEM line from the current UART.data snapshot and push it to the host.
 // Caller is responsible for having just run UART.getVescValues() successfully.
 static void sendTelemLineNow() {
   uint32_t espMs = millis();
   sendHostFmt("TELEM,%lu,%.1f,%.4f,%.2f,%.3f,%.3f,%.1f,%.1f,%ld,%ld,%d",
       (unsigned long)espMs,
       UART.data.rpm,
       UART.data.dutyCycleNow,
       UART.data.inpVoltage,
       UART.data.avgMotorCurrent,
       UART.data.avgInputCurrent,
       UART.data.tempMosfet,
       UART.data.tempMotor,
       UART.data.tachometer,
       UART.data.tachometerAbs,
       (int)UART.data.error);
 }
 
 // Firmware-pushed TELEM: mirrors pollEncoderStream but also runs the VESC UART exchange each tick.
 // One BLE notify per sample (vs. polled GET_VALUES which needs host-write + notify = two connection
 // events on top of UART round-trip). A single UART.getVescValues() blocks loop() for ~10 ms at 115200
 // baud, so don't set this below ~15 ms or ENC emission starts to lag.
 static void pollTelemStream(uint32_t nowMs) {
   static uint32_t lastSampleMs = 0;
   static bool     lastStreamOn = false;
 
   if (g_telemStreamEnabled != lastStreamOn) {
     lastStreamOn = g_telemStreamEnabled;
     lastSampleMs = 0;
   }
   if (!g_telemStreamEnabled) return;
 
   if (lastSampleMs == 0) {
     lastSampleMs = nowMs;
     return;
   }
   if (nowMs - lastSampleMs < g_telemStreamIntervalMs) return;
   lastSampleMs = nowMs;
 
   // When the PI loop is running it already polls UART at its own (typically faster) cadence;
   // reusing that cached snapshot here avoids two competing UART round-trips and keeps the
   // serial link headroom available for the closed-loop control read.
   bool ok;
   if (g_piEnabled && g_piLastUartMs != 0 && (nowMs - g_piLastUartMs) < 200) {
     ok = true;
   } else {
     ok = UART.getVescValues();
     if (ok) {
       g_piLastUartMs = nowMs;
       g_telemetryLastSeenMs = nowMs;
     }
   }
   if (ok) sendTelemLineNow();
   // On a bad read we deliberately stay silent and try again next interval — a VESC_TIMEOUT line every
   // 25 ms would drown the link. The Python side already shows staleness via the "Actual Hz" readout.
 }
 
 // ---------------------------------------------------------------------------
 // PI controller core (verbatim port of PI_Dev/PI_ex1.ino, with editable gains)
 // ---------------------------------------------------------------------------
 
 static void hardStopMotor() {
   UART.setCurrent(0.0f);
   UART.setBrakeCurrent(0.0f);
   g_motorActive = false;
   g_directMode = DIRECT_CMD_NONE;
   g_directBaseCmd = 0.0f;
   g_setpointApproachActive = false;
   updateStatusLeds();
 }
 
 static float currentEncoderPosM() {
   noInterrupts();
   int32_t count = g_encoderCount;
   interrupts();
   return (float)count * METERS_PER_COUNT;
 }
 
 static float setpointScaleFromDistance(float distM) {
   if (distM <= SETPOINT_REACHED_TOL_M) return 0.0f;
   if (distM >= SETPOINT_SLOWDOWN_START_M) return 1.0f;
   float s = distM / SETPOINT_SLOWDOWN_START_M;
   if (s < 0.10f) s = 0.10f;
   if (s > 1.0f) s = 1.0f;
   return s;
 }
 
 static void queueSetpointReachedStop(float posNowM) {
   hardStopMotor();
   g_piEnabled = false;
   g_setpointStopBurstRemaining = SETPOINT_STOP_BURST_COUNT;
   g_setpointStopBurstLastMs = 0;
   sendHostFmt("INFO,SETPOINT_REACHED,%.5f", posNowM);
   sendHostLine("OK,STOP");
 }
 
 static void pollSetpointStopBurst(uint32_t nowMs) {
   if (g_setpointStopBurstRemaining == 0) return;
   if (g_setpointStopBurstLastMs != 0 && (nowMs - g_setpointStopBurstLastMs) < SETPOINT_STOP_BURST_MS) return;
   g_setpointStopBurstLastMs = nowMs;
   hardStopMotor();
   sendHostLine("OK,STOP");
   g_setpointStopBurstRemaining--;
 }
 
 static void pollDirectSetpointApproach(uint32_t nowMs) {
   if (!g_setpointDefined || g_piEnabled || !g_setpointApproachActive) return;
   if (g_directMode == DIRECT_CMD_NONE) return;
   if (g_directApplyLastMs != 0 && (nowMs - g_directApplyLastMs) < SETPOINT_DIRECT_APPLY_MS) return;
   g_directApplyLastMs = nowMs;
 
   float posNow = currentEncoderPosM();
   float dist = fabsf(posNow - g_setpointPosM);
   if (dist <= SETPOINT_REACHED_TOL_M) {
     queueSetpointReachedStop(posNow);
     return;
   }
   float scale = setpointScaleFromDistance(dist);
   switch (g_directMode) {
     case DIRECT_CMD_CURRENT:
       UART.setCurrent(g_directBaseCmd * scale);
       break;
     case DIRECT_CMD_BRAKE:
       UART.setBrakeCurrent(fabsf(g_directBaseCmd) * scale);
       break;
     case DIRECT_CMD_DUTY:
       UART.setDuty(g_directBaseCmd * scale);
       break;
     default:
       break;
   }
 }
 
 static void triggerSafetyStop(const char* reason) {
   if (g_safetyStopEngaged) return;
   g_safetyStopEngaged = true;
   g_piEnabled = false;
   hardStopMotor();
   sendHostFmt("ERROR,SAFETY_STOP,%s", reason);
 }
 
 static void enforceSafetyStop() {
   if (!g_safetyStopEngaged) return;
   hardStopMotor();
 }
 
 static void clearSafetyStopLatch() {
   g_safetyStopEngaged = false;
   g_piEnabled = false;
   g_negativeCurrentStartMs = 0;
   g_velocityOverLimitSinceMs = 0;
   g_currentOverLimitSinceMs = 0;
   g_safetyLastSampleMs = 0;
   hardStopMotor();
   g_piIntegrator   = 0.0f;
   g_piTPrevS       = -1.0f;
   g_piT0Us         = 0;
   g_piLastTickUs   = 0;
   g_piPeriodEmaUs  = 0;
   g_piEmitDecimCnt = 0;
   g_piIMeas = g_piOmega = g_piICmd = 0.0f;
 }
 
 static void resetPiController() {
   g_piIntegrator   = 0.0f;
   g_piTPrevS       = -1.0f;
   g_piT0Us         = 0;
   g_piLastTickUs   = 0;
   g_piPeriodEmaUs  = 0;
   g_piEmitDecimCnt = 0;
   g_piIMeas = g_piOmega = g_piICmd = 0.0f;
 }
 
 // Returns commanded current (A). Sign convention: positive = forward/drive,
 // negative = active braking, identical to the prototype in PI_ex1.ino.
 static float piCurrentController(float i_measured, float omega, float t_s, float i_target) {
   if (g_piTPrevS < 0.0f) {
     g_piTPrevS = t_s;
     return i_target;        // pass-through on first call (no dt yet)
   }
   float dt = t_s - g_piTPrevS;
   g_piTPrevS = t_s;
   if (dt <= 0.0f) return i_target;
 
   float back_emf_current = (g_pi.Ke * omega) / g_pi.R;
   g_piBackEmf = back_emf_current;
 
   float e    = i_target - i_measured;
   float i_ff = i_target - back_emf_current;
   float i_cmd_unsat = i_target + g_pi.Kp * e + g_piIntegrator;
   
 
   /*
   Kallens reccomendation is to make i_cmd_unsat = i_target + kp*e + integrator
   and make the back emf current a part of the error term
   because right now if the back emf current is large then the cmd becomes negative and the motor will spin the wrong way continuously
 
 
   float e;
   float i_ff; //lowkey not even using this
   
   if (fabsf(i_target) <= 0.1f) {
     e = i_target - i_measured;
     i_ff = 0.0f;
   } else {
     e = i_target - back_emf_current - i_measured;
     i_ff = i_target - back_emf_current;
   }
 
   float i_cmd_unsat = g_pi.Kp * e + g_piIntegrator;
   //  float i_cmd_unsat = i_ff + g_pi.Kp * e + g_piIntegrator;
   */
 
 
   float i_cmd = i_cmd_unsat;
   if (i_cmd >  g_pi.I_max) i_cmd =  g_pi.I_max;
   if (i_cmd < -g_pi.I_max) i_cmd = -g_pi.I_max;
 
   // Anti-windup back-calculation (keeps integrator honest while saturated)
   if (g_pi.Kp > 1e-6f) {
     g_piIntegrator += g_pi.Ki * e * dt + (1.0f / g_pi.Kp) * (i_cmd - i_cmd_unsat) * dt;
   } else {
     g_piIntegrator += g_pi.Ki * e * dt;
   }
   if (g_piIntegrator >  g_pi.I_int_max) g_piIntegrator =  g_pi.I_int_max;
   if (g_piIntegrator < -g_pi.I_int_max) g_piIntegrator = -g_pi.I_int_max;
 
   g_piError = e;
   g_piFF = i_ff;
   g_piICmdUnsat = i_cmd_unsat;
   return i_cmd;
 }
 
 // Called from loop(); paces itself using micros() against 1e6/target_hz.
 // All blocking work (UART read, BLE notify) happens here so the loop() body
 // stays simple and the PI cadence stays observable from the actual_hz field.
 static void pollPiLoop(uint32_t nowMs, uint32_t nowUs) {
   if (g_safetyStopEngaged) {
     enforceSafetyStop();
     return;
   }
   if (!g_piEnabled) return;
 
   // Link-loss safety: PI sends setCurrent every cycle, so the VESC's APP/UART
   // timeout never trips. If BLE drops mid-run we'd otherwise drive forever.
   if (!g_bleConnected) {
     g_piEnabled = false;
     UART.setCurrent(0.0f);
     g_motorActive = false;
     updateStatusLeds();
     resetPiController();
     return;
   }
 
   uint32_t hz = (g_pi.target_hz < 1) ? 1u : g_pi.target_hz;
   uint32_t period_us = 1000000UL / hz;
 
   if (g_piLastTickUs != 0 && (nowUs - g_piLastTickUs) < period_us) return;
 
   uint32_t actual_dt_us = (g_piLastTickUs == 0) ? period_us : (nowUs - g_piLastTickUs);
   g_piLastTickUs = nowUs;
   g_piPeriodEmaUs = (g_piPeriodEmaUs == 0)
       ? actual_dt_us
       : (g_piPeriodEmaUs * 7 + actual_dt_us) / 8;   // EMA, alpha = 1/8
 
   if (g_piT0Us == 0) g_piT0Us = nowUs;
   float t_s = (float)((nowUs - g_piT0Us)) * 1e-6f;
 
   if (!UART.getVescValues()) {
     // Skip this tick on bad UART — actual_hz will reflect the gap honestly.
     return;
   }
   g_piLastUartMs = nowMs;
   g_telemetryLastSeenMs = nowMs;
   if (monitorSafety(nowMs)) return;
 
   // Derive omega from rope encoder (1:1 spool-to-motor ratio).
   // VESC reports zero RPM during backdrive/passive generation so the encoder
   // is the only reliable velocity source for feedforward back-EMF cancellation.
   float omega  = fabsf(g_lastEncoderVelMps) / SPOOL_RADIUS_M;
   float i_meas = UART.data.avgMotorCurrent;
 
   // Detect i_target sign change BEFORE running controller.
   // Resets integrator so accumulated error from the previous regime doesn't
   // carry over and cause a spike at the zero crossing.
   bool target_crossed_zero = (g_piTargetAmpsPrev >= 0.0f && g_piTargetAmps < 0.0f) ||
                              (g_piTargetAmpsPrev <= 0.0f && g_piTargetAmps > 0.0f);
   if (target_crossed_zero && g_piResetIntOnCrossing) {
     g_piIntegrator = 0.0f;
   }
   g_piTargetAmpsPrev = g_piTargetAmps;
 
   float i_cmd = piCurrentController(i_meas, omega, t_s, g_piTargetAmps);
   if (g_setpointDefined && g_setpointApproachActive) {
     float posNow = currentEncoderPosM();
     float dist = fabsf(posNow - g_setpointPosM);
     if (dist <= SETPOINT_REACHED_TOL_M) {
       queueSetpointReachedStop(posNow);
       return;
     }
     i_cmd *= setpointScaleFromDistance(dist);
   }
 
   UART.setCurrent(i_cmd);
   g_motorActive = (fabsf(i_cmd) > 1e-3f);
   updateStatusLeds();
 
   g_piIMeas = i_meas;
   g_piOmega = omega;
   g_piICmd  = i_cmd;
 
   // Decimate PICTRL emits to ≤ ~100 Hz so BLE notify slots aren't starved when
   // the loop runs faster than the link can sustain (e.g. user picks 200 Hz).
   const uint32_t emit_max_us = 10000;   // 100 Hz emit ceiling
   g_piEmitEveryN = (period_us < emit_max_us) ? (emit_max_us / period_us + 1u) : 1u;
   if (++g_piEmitDecimCnt >= g_piEmitEveryN) {
     g_piEmitDecimCnt = 0;
     float actual_hz = (g_piPeriodEmaUs > 0) ? (1000000.0f / (float)g_piPeriodEmaUs) : 0.0f;
     sendHostFmt("PICTRL,%lu,%.4f,%.4f,%.4f,%.3f,%.2f,%.3f,%.4f,%.4f,%.4f,%.4f,%.4f",
         (unsigned long)nowMs,
         g_piTargetAmps, i_meas, i_cmd, omega,
         actual_hz, g_piTargetLbs,
         g_piError, g_piFF, g_piIntegrator, g_piICmdUnsat, g_piBackEmf);
   }
 }
 
 // PICFG snapshot reply (for PI_CONFIG).
 static void sendPiConfigLine() {
   sendHostFmt("PICFG,%.4f,%.4f,%.4f,%.6f,%.4f,%.4f,%.3f,%.4f,%.4f,%d,%lu,%d,%.3f,%.4f,%d",
       g_pi.Kt, g_pi.Ke, g_pi.R, g_pi.L,
       g_pi.Kp, g_pi.Ki,
       g_pi.I_max, g_pi.I_int_max, g_pi.amps_per_lb,
       g_pi.pole_pairs, (unsigned long)g_pi.target_hz,
       g_piEnabled ? 1 : 0,
       g_piTargetLbs, g_piTargetAmps,
       g_piResetIntOnCrossing ? 1 : 0);
 }
 
 static void processCommand(const String& cmd) {
 
   if (cmd == "PING") {
     sendHostLine("PONG,Quikburst");
     return;
   }
 
   if (cmd == "SAFETY_RESET" || cmd == "CLEAR_ERROR") {
     clearSafetyStopLatch();
     sendHostLine("OK,SAFETY_RESET");
     return;
   }
 
   if (cmd == "STOP") {
     if (g_piEnabled) {
       g_piEnabled = false;
       resetPiController();
     }
     UART.setCurrent(0.0f);
     UART.setBrakeCurrent(0.0f);
     g_motorActive = false;
     g_directMode = DIRECT_CMD_NONE;
     g_directBaseCmd = 0.0f;
     g_setpointApproachActive = false;
     updateStatusLeds();
     sendHostLine("OK,STOP");
     return;
   }
 
   if (cmd == "SETPOINT") {
     g_setpointPosM = currentEncoderPosM();
     g_setpointDefined = true;
     g_setpointApproachActive = false;
     g_setpointStopBurstRemaining = 0;
     sendHostFmt("OK,SETPOINT,%.5f", g_setpointPosM);
     return;
   }
 
   if (cmd.startsWith("OVERRIDE_SPOOL_IN,")) {
     float duty = parseFloat(cmd.substring(18));
     if (duty < 0.0f) duty = 0.0f;
     if (duty > VESC_MAX_DUTY) duty = VESC_MAX_DUTY;
     g_piEnabled = false;
     g_directMode = DIRECT_CMD_DUTY;
     g_directBaseCmd = duty;
     g_setpointApproachActive = false;  // Explicit override bypasses setpoint gate and approach slowdown.
     UART.setDuty(duty);
     g_motorActive = (duty > 1e-5f);
     updateStatusLeds();
     sendHostFmt("OK,OVERRIDE_SPOOL_IN,%.4f", duty);
     return;
   }
 
   if (cmd.startsWith("SET_CURRENT,")) {
     if (!g_setpointDefined) {
       sendHostLine("WARN,SETPOINT_REQUIRED");
       return;
     }
     float amps = parseFloat(cmd.substring(12));
     float dist = fabsf(currentEncoderPosM() - g_setpointPosM);
     if (dist <= SETPOINT_REACHED_TOL_M) {
       queueSetpointReachedStop(currentEncoderPosM());
       return;
     }
     float cmdAmps = amps * setpointScaleFromDistance(dist);
     UART.setCurrent(cmdAmps);
     g_motorActive = (fabsf(cmdAmps) > 1e-4f);
     g_directMode = DIRECT_CMD_CURRENT;
     g_directBaseCmd = amps;
     g_setpointApproachActive = true;
     updateStatusLeds();
     sendHostFmt("OK,SET_CURRENT,%.3f", cmdAmps);
     return;
   }
 
   if (cmd == "SET_BRAKE" || cmd.startsWith("SET_BRAKE,")) {
     if (!g_setpointDefined) {
       sendHostLine("WARN,SETPOINT_REQUIRED");
       return;
     }
     float amps = VESC_BRAKE_APPLY_AMPS;
     if (cmd.startsWith("SET_BRAKE,")) {
       amps = parseFloat(cmd.substring(10));
     }
     if (amps < 0.0f) {
       amps = 0.0f;
     }
     float dist = fabsf(currentEncoderPosM() - g_setpointPosM);
     if (dist <= SETPOINT_REACHED_TOL_M) {
       queueSetpointReachedStop(currentEncoderPosM());
       return;
     }
     float cmdBrake = amps * setpointScaleFromDistance(dist);
     UART.setBrakeCurrent(cmdBrake);
     g_motorActive = (cmdBrake > 1e-4f);
     g_directMode = DIRECT_CMD_BRAKE;
     g_directBaseCmd = amps;
     g_setpointApproachActive = true;
     updateStatusLeds();
     sendHostFmt("OK,SET_BRAKE,%.3f", cmdBrake);
     return;
   }
 
   if (cmd.startsWith("SET_DUTY,")) {
     if (!g_setpointDefined) {
       sendHostLine("WARN,SETPOINT_REQUIRED");
       return;
     }
     float duty = parseFloat(cmd.substring(9));
     if (duty < 0.0f) duty = 0.0f;
     if (duty > VESC_MAX_DUTY) duty = VESC_MAX_DUTY;
     float dist = fabsf(currentEncoderPosM() - g_setpointPosM);
     if (dist <= SETPOINT_REACHED_TOL_M) {
       queueSetpointReachedStop(currentEncoderPosM());
       return;
     }
     float cmdDuty = duty * setpointScaleFromDistance(dist);
     UART.setDuty(cmdDuty);
     g_motorActive = (cmdDuty > 1e-5f);
     g_directMode = DIRECT_CMD_DUTY;
     g_directBaseCmd = duty;
     g_setpointApproachActive = true;
     updateStatusLeds();
     if (cmdDuty >= VESC_MAX_DUTY) {
       triggerSafetyStop("DUTY_OVER_LIMIT");
     }
     sendHostFmt("OK,SET_DUTY,%.4f", cmdDuty);
     return;
   }
 
   if (cmd == "KEEPALIVE") {
     UART.sendKeepalive();
     sendHostLine("OK,KEEPALIVE");
     return;
   }
 
   if (cmd == "ENC_RESET") {
     noInterrupts();
     g_encoderCount = 0;
     interrupts();
     g_encResetPending = true;
     sendHostLine("OK,ENC_RESET");
     return;
   }
 
   if (cmd.startsWith("ENC_STREAM,")) {
     bool on = false;
     uint32_t ms = g_encStreamIntervalMs;
     parseStreamArgs(cmd.substring(11), on, ms, ENC_STREAM_MIN_MS, ENC_STREAM_MAX_MS);
     g_encStreamEnabled = on;
     g_encStreamIntervalMs = ms;
     sendHostFmt("OK,ENC_STREAM,%d,%lu", on ? 1 : 0, (unsigned long)g_encStreamIntervalMs);
     return;
   }
 
   if (cmd.startsWith("TELEM_STREAM,")) {
     bool on = false;
     uint32_t ms = g_telemStreamIntervalMs;
     parseStreamArgs(cmd.substring(13), on, ms, TELEM_STREAM_MIN_MS, TELEM_STREAM_MAX_MS);
     g_telemStreamEnabled = on;
     g_telemStreamIntervalMs = ms;
     sendHostFmt("OK,TELEM_STREAM,%d,%lu", on ? 1 : 0, (unsigned long)g_telemStreamIntervalMs);
     return;
   }
 
   if (cmd.startsWith("SET_NUNCHUCK,")) {
     long val = (long)parseFloat(cmd.substring(13));
     if (val < 0) val = 0;
     if (val > 255) val = 255;
     UART.setNunchuckValues((uint8_t)val);
     sendHostFmt("OK,SET_NUNCHUCK,%ld", val);
     return;
   }
 
   if (cmd == "GET_VALUES") {
     if (UART.getVescValues()) {
       sendTelemLineNow();
     } else {
       sendHostLine("ERROR,VESC_TIMEOUT");
     }
     return;
   }
 
   if (cmd == "GET_FW") {
     if (UART.getFWversion()) {
       sendHostFmt("FW,%d.%d", UART.fw_version.major, UART.fw_version.minor);
     } else {
       sendHostLine("ERROR,FW_TIMEOUT");
     }
     return;
   }
 
   // -------------------------------------------------------------------------
   // PI current controller commands
   // -------------------------------------------------------------------------
 
   if (cmd.startsWith("PI_ENABLE,")) {
     if (!g_setpointDefined) {
       sendHostLine("WARN,SETPOINT_REQUIRED");
       return;
     }
     bool on = parseFloat(cmd.substring(10)) != 0.0f;
     if (on && !g_piEnabled) {
       resetPiController();
     } else if (!on && g_piEnabled) {
       UART.setCurrent(0.0f);
       g_motorActive = false;
       updateStatusLeds();
     }
     g_piEnabled = on;
     if (on) {
       float dist = fabsf(currentEncoderPosM() - g_setpointPosM);
       g_setpointApproachActive = (dist > SETPOINT_REACHED_TOL_M);
     } else {
       g_setpointApproachActive = false;
     }
     sendHostFmt("OK,PI_ENABLE,%d", on ? 1 : 0);
     return;
   }
 
   if (cmd.startsWith("PI_FORCE,")) {
     float lbs = parseFloat(cmd.substring(9));
     g_piTargetLbs  = lbs;
     // ───── Force → current equation (single source of truth) ─────
     g_piTargetAmps = g_pi.amps_per_lb * lbs;
     // ─────────────────────────────────────────────────────────────
     sendHostFmt("OK,PI_FORCE,%.3f,%.4f", lbs, g_piTargetAmps);
     return;
   }
 
   if (cmd.startsWith("PI_TARGET,")) {
     float a = parseFloat(cmd.substring(10));
     g_piTargetAmps = a;
     g_piTargetLbs  = (g_pi.amps_per_lb > 1e-9f) ? (a / g_pi.amps_per_lb) : 0.0f;
     sendHostFmt("OK,PI_TARGET,%.4f", g_piTargetAmps);
     return;
   }
 
   if (cmd.startsWith("PI_HZ,")) {
     long hz = (long)parseFloat(cmd.substring(6));
     if (hz < 1)   hz = 1;
     if (hz > 500) hz = 500;
     g_pi.target_hz = (uint32_t)hz;
     g_piLastTickUs = 0;     // reset pacing so the new period takes effect immediately
     g_piPeriodEmaUs = 0;
     sendHostFmt("OK,PI_HZ,%lu", (unsigned long)g_pi.target_hz);
     return;
   }
 
   if (cmd.startsWith("PI_GAINS,")) {
     String args = cmd.substring(9);
     int comma = args.indexOf(',');
     if (comma > 0) {
       g_pi.Kp = parseFloat(args.substring(0, comma));
       g_pi.Ki = parseFloat(args.substring(comma + 1));
       sendHostFmt("OK,PI_GAINS,%.4f,%.4f", g_pi.Kp, g_pi.Ki);
       sendPiConfigLine();
     } else {
       sendHostLine("ERROR,PI_GAINS_BAD_ARGS");
     }
     return;
   }
 
   if (cmd.startsWith("PI_PARAMS,")) {
     // PI_PARAMS,Kt,Ke,R,L
     String s = cmd.substring(10);
     int c1 = s.indexOf(',');
     int c2 = (c1 >= 0) ? s.indexOf(',', c1 + 1) : -1;
     int c3 = (c2 >= 0) ? s.indexOf(',', c2 + 1) : -1;
     if (c1 > 0 && c2 > c1 && c3 > c2) {
       g_pi.Kt = parseFloat(s.substring(0, c1));
       g_pi.Ke = parseFloat(s.substring(c1 + 1, c2));
       g_pi.R  = parseFloat(s.substring(c2 + 1, c3));
       g_pi.L  = parseFloat(s.substring(c3 + 1));
       sendHostFmt("OK,PI_PARAMS,%.4f,%.4f,%.4f,%.6f", g_pi.Kt, g_pi.Ke, g_pi.R, g_pi.L);
       sendPiConfigLine();
     } else {
       sendHostLine("ERROR,PI_PARAMS_BAD_ARGS");
     }
     return;
   }
 
   if (cmd.startsWith("PI_LIMITS,")) {
     // PI_LIMITS,I_max,I_int_max,amps_per_lb,pole_pairs
     String s = cmd.substring(10);
     int c1 = s.indexOf(',');
     int c2 = (c1 >= 0) ? s.indexOf(',', c1 + 1) : -1;
     int c3 = (c2 >= 0) ? s.indexOf(',', c2 + 1) : -1;
     if (c1 > 0 && c2 > c1 && c3 > c2) {
       g_pi.I_max       = parseFloat(s.substring(0, c1));
       g_pi.I_int_max   = parseFloat(s.substring(c1 + 1, c2));
       g_pi.amps_per_lb = parseFloat(s.substring(c2 + 1, c3));
       g_pi.pole_pairs  = (int)parseFloat(s.substring(c3 + 1));
     } else if (c1 > 0 && c2 > c1) {
       g_pi.I_max       = parseFloat(s.substring(0, c1));
       g_pi.amps_per_lb = parseFloat(s.substring(c1 + 1, c2));
       g_pi.pole_pairs  = (int)parseFloat(s.substring(c2 + 1));
     } else {
       sendHostLine("ERROR,PI_LIMITS_BAD_ARGS");
       return;
     }
     // Re-evaluate target current so the next loop tick uses the new scale.
     g_piTargetAmps = g_pi.amps_per_lb * g_piTargetLbs;
     sendHostFmt("OK,PI_LIMITS,%.3f,%.3f,%.4f,%d",
         g_pi.I_max, g_pi.I_int_max, g_pi.amps_per_lb, g_pi.pole_pairs);
     sendPiConfigLine();
     return;
   }
 
   if (cmd.startsWith("PI_RESET_INT,")) {
     bool on = parseFloat(cmd.substring(13)) != 0.0f;
     g_piResetIntOnCrossing = on;
     sendHostFmt("OK,PI_RESET_INT,%d", on ? 1 : 0);
     return;
   }
 
   if (cmd == "PI_CONFIG") {
     sendPiConfigLine();
     return;
   }
 
   sendHostFmt("ERROR,UNKNOWN_CMD,%s", cmd.c_str());
 }
 
 static void feedLineBuffer(String& buf, char c) {
   if (c == '\n' || c == '\r') {
     if (buf.length() > 0) {
       processCommand(buf);
       buf = "";
     }
   } else {
     buf += c;
     if (buf.length() > 200) buf = "";
   }
 }
 
 // ---------------------------------------------------------------------------
 // BLE
 // ---------------------------------------------------------------------------
 
 class QuikburstServerCallbacks : public BLEServerCallbacks {
   void onConnect(BLEServer* s, esp_ble_gatts_cb_param_t* param) override {
     g_bleConnected = true;
     updateStatusLeds();
     // Ask the central for a tight connection interval (6 = 7.5 ms min, 12 = 15 ms max).
     // Each notify has to wait for the next connection event, so this directly
     // caps the "+interval" offset we see in TELEM cadence. macOS may round to
     // 15 ms per Apple accessory policy, but any reduction from the default helps.
     // latency = 0 (no slave latency); timeout = 400 (4 s supervision).
     s->updateConnParams(param->connect.remote_bda, 6, 12, 0, 400);
     sendHostLine("OK,BT_CONNECTED");
   }
   void onDisconnect(BLEServer*) override {
     g_bleConnected = false;
     updateStatusLeds();
     // Defer restart to loop(): stack is still tearing down; immediate startAdvertising often fails to re-advertise.
     g_bleAdvRestartAtMs = millis() + 400;
   }
 };
 
 class QuikburstRxCallbacks : public BLECharacteristicCallbacks {
   void onWrite(BLECharacteristic* ch) override {
     // ESP32 Arduino 3.x: getValue() returns Arduino String (not std::string).
     String val = ch->getValue();
     if (val.length() == 0) return;
     for (size_t i = 0; i < val.length(); i++) {
       feedLineBuffer(g_bleCmdBuf, val[i]);
     }
   }
 };
 
 static void restartBleAdvertising() {
   BLEAdvertising* adv = BLEDevice::getAdvertising();
   adv->addServiceUUID(NUS_SERVICE_UUID);
   adv->setScanResponse(true);
   // Advertise preferred slave connection interval 7.5–15 ms (units of 1.25 ms).
   // (Previous code called setMinPreferred twice — a known copy-paste bug from
   // the ESP32 Arduino examples; the second call silently overwrote the first.)
   adv->setMinPreferred(0x06);
   adv->setMaxPreferred(0x0C);
   if (g_server != nullptr) {
     g_server->startAdvertising();
   }
   BLEDevice::startAdvertising();
 }
 
 static void setupBle() {
   BLEDevice::init(BLE_DEVICE_NAME);
   g_server = BLEDevice::createServer();
   g_server->setCallbacks(new QuikburstServerCallbacks());
 
   BLEService* svc = g_server->createService(NUS_SERVICE_UUID);
 
   BLECharacteristic* rx = svc->createCharacteristic(
       NUS_RX_UUID,
       BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
   rx->setCallbacks(new QuikburstRxCallbacks());
 
   g_txChar = svc->createCharacteristic(
       NUS_TX_UUID,
       BLECharacteristic::PROPERTY_NOTIFY);
   g_txChar->addDescriptor(new BLE2902());
 
   svc->start();
 
   restartBleAdvertising();
 }
 
 // ---------------------------------------------------------------------------
 // setup / loop
 // ---------------------------------------------------------------------------
 
 void setup() {
   pinMode(STATUS_LED_BLE_PIN, OUTPUT);
   pinMode(STATUS_LED_ON_PIN, OUTPUT);
   g_motorActive = false;
   updateStatusLeds();
 
   Serial2.begin(115200, SERIAL_8N1, VESC_UART_RX_PIN, VESC_UART_TX_PIN);
   UART.setSerialPort(&Serial2);
 
   setupBle();
 
   delay(300);
   pinMode(ENC_PIN_A, INPUT_PULLUP);
   pinMode(ENC_PIN_B, INPUT_PULLUP);
   g_lastEncoded = ((int8_t)digitalRead(ENC_PIN_A) << 1) | (int8_t)digitalRead(ENC_PIN_B);
   attachInterrupt(digitalPinToInterrupt(ENC_PIN_A), updateEncoder, CHANGE);
   attachInterrupt(digitalPinToInterrupt(ENC_PIN_B), updateEncoder, CHANGE);
 
   updateStatusLeds();
   sendHostLine("[READY]");
 }
 
 void loop() {
   uint32_t now = millis();
   uint32_t nowUs = micros();
   pollEncoderStream(now);
   pollSetpointStopBurst(now);
   pollPiLoop(now, nowUs);     // run BEFORE TELEM so cached UART.data is fresh
   pollDirectSetpointApproach(now);
   pollTelemStream(now);
   pollSafety(now);
   if (now - g_lastReadyMs >= READY_INTERVAL_MS) {
     g_lastReadyMs = now;
     sendHostLine("[READY]");
   }
 
   if (g_bleAdvRestartAtMs != 0) {
     int32_t left = (int32_t)(now - g_bleAdvRestartAtMs);
     if (left >= 0) {
       g_bleAdvRestartAtMs = 0;
       if (!g_bleConnected) {
         restartBleAdvertising();
       }
     }
   }
 
   delay(1);
 }
 