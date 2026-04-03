/*
 * VESC UART Test — ESP32 ↔ Python serial bridge
 *
 * Serial  (USB, 115200) — commands from Python host
 * Serial2 (UART2) — VESC communication via VescUart lib
 *
 * Pin names: many boards label UART2 as RX2 / TX2 (not D11/D12). Set GPIOs below
 * to match YOUR board’s pinout (often RX2=GPIO16, TX2=GPIO17 on ESP32-WROOM DevKits).
 * Do not use TX0/RX0 for the VESC if those pins are tied to the USB–serial chip.
 *
 * Protocol (newline-terminated text, same style as tests/motor_encoder_current):
 *   SET_CURRENT,<amps>        → drive motor at <amps> (signed float)
 *   SET_BRAKE,<amps>          → apply brake current
 *   SET_DUTY,<duty>           → duty cycle 0.0–1.0
 *   SET_RPM,<erpm>            → target eRPM (RPM × poles)
 *   STOP                      → setCurrent(0) — release motor
 *   GET_VALUES                → request telemetry snapshot
 *   GET_FW                    → request firmware version
 *   KEEPALIVE                 → send keepalive to VESC
 *
 * Responses:
 *   OK,<cmd>                  — command accepted
 *   TELEM,rpm,duty,voltage,avgMotorCurrent,avgInputCurrent,tempMos,tempMotor,tach,tachAbs,fault
 *   FW,<major>.<minor>
 *   ERROR,<reason>
 *   [READY]                   — periodic heartbeat in idle
 */

#include <VescUart.h>
#include <stdarg.h>

// UART2 to VESC — GPIO numbers (not silkscreen “D” labels unless your core maps them).
// Wiring: ESP32 TX pin → VESC RX ; ESP32 RX pin → VESC TX ; GND ↔ GND.
#if !defined(VESC_UART_RX_PIN) || !defined(VESC_UART_TX_PIN)
#define VESC_UART_RX_PIN 16  // often labeled RX2 — receives bytes from VESC TX
#define VESC_UART_TX_PIN 17  // often labeled TX2 — drives VESC RX
#endif

VescUart UART;

static String g_cmdBuf = "";

static constexpr uint32_t READY_INTERVAL_MS = 5000;
static uint32_t g_lastReadyMs = 0;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

static void respond(const char* msg) {
  Serial.println(msg);
}

static void respondFmt(const char* fmt, ...) {
  char buf[256];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  Serial.println(buf);
}

static float parseFloat(const String& s) {
  String t = s;
  t.trim();
  return t.toFloat();
}

// ---------------------------------------------------------------------------
// command handler
// ---------------------------------------------------------------------------

static void processCommand(const String& cmd) {

  if (cmd == "STOP") {
    UART.setCurrent(0.0f);
    respond("OK,STOP");
    return;
  }

  if (cmd.startsWith("SET_CURRENT,")) {
    float amps = parseFloat(cmd.substring(12));
    UART.setCurrent(amps);
    respondFmt("OK,SET_CURRENT,%.3f", amps);
    return;
  }

  if (cmd.startsWith("SET_BRAKE,")) {
    float amps = parseFloat(cmd.substring(10));
    UART.setBrakeCurrent(amps);
    respondFmt("OK,SET_BRAKE,%.3f", amps);
    return;
  }

  if (cmd.startsWith("SET_DUTY,")) {
    float duty = parseFloat(cmd.substring(9));
    UART.setDuty(duty);
    respondFmt("OK,SET_DUTY,%.4f", duty);
    return;
  }

  if (cmd.startsWith("SET_RPM,")) {
    float rpm = parseFloat(cmd.substring(8));
    UART.setRPM(rpm);
    respondFmt("OK,SET_RPM,%.1f", rpm);
    return;
  }

  if (cmd == "KEEPALIVE") {
    UART.sendKeepalive();
    respond("OK,KEEPALIVE");
    return;
  }

  if (cmd == "GET_VALUES") {
    if (UART.getVescValues()) {
      respondFmt("TELEM,%.1f,%.4f,%.2f,%.3f,%.3f,%.1f,%.1f,%ld,%ld,%d",
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
    } else {
      respond("ERROR,VESC_TIMEOUT");
    }
    return;
  }

  if (cmd == "GET_FW") {
    if (UART.getFWversion()) {
      respondFmt("FW,%d.%d", UART.fw_version.major, UART.fw_version.minor);
    } else {
      respond("ERROR,FW_TIMEOUT");
    }
    return;
  }

  respondFmt("ERROR,UNKNOWN_CMD,%s", cmd.c_str());
}

// ---------------------------------------------------------------------------
// serial polling
// ---------------------------------------------------------------------------

static void pollSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (g_cmdBuf.length() > 0) {
        processCommand(g_cmdBuf);
        g_cmdBuf = "";
      }
    } else {
      g_cmdBuf += c;
      if (g_cmdBuf.length() > 200) g_cmdBuf = "";
    }
  }
}

// ---------------------------------------------------------------------------
// setup / loop
// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  while (!Serial) { delay(10); }

  Serial2.begin(115200, SERIAL_8N1, VESC_UART_RX_PIN, VESC_UART_TX_PIN);
  UART.setSerialPort(&Serial2);

  delay(500);
  Serial.println();
  Serial.println("VESC UART Test (ESP32)");
  Serial.println("Commands: SET_CURRENT,<A> | SET_BRAKE,<A> | SET_DUTY,<d> | SET_RPM,<e> | STOP | GET_VALUES | GET_FW | KEEPALIVE");
  Serial.println("[READY]");
}

void loop() {
  pollSerial();

  uint32_t now = millis();
  if (now - g_lastReadyMs >= READY_INTERVAL_MS) {
    g_lastReadyMs = now;
    respond("[READY]");
  }

  delay(1);
}
