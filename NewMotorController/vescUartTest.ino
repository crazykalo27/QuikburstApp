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
 *   SET_BRAKE                 → OK,SET_BRAKE (full brake; no host current arg — see VESC_BRAKE_APPLY_AMPS)
 *   SET_DUTY,<duty>           → duty clamped to 0…0.20 (20%)
 *   STOP                      → OK,STOP
 *   GET_VALUES                → TELEM,esp32_ms,rpm,duty,vbat,imotor,iin,tmos,tmotor,tach,tachAbs,fault
 *                               (esp32_ms = millis() when line is sent; same clock as ENC time_ms)
 *   GET_FW                    → FW,...
 *   KEEPALIVE                 → OK,KEEPALIVE
 *   ENC_RESET                 → OK,ENC_RESET (zero encoder count / position)
 *   ENC_STREAM,<0|1>         → OK,ENC_STREAM,... (enable/disable ENC line streaming)
 *   ENC,...                   — streamed ~100 Hz when ENC_STREAM on (BLE):
 *                               ENC,time_ms,count,position_m,velocity_mps
 *                               (same quadrature + spool geometry as ahaan100/encoder.ino)
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
#define VESC_MAX_DUTY 0.20f
#endif

// SET_BRAKE applies this brake current over UART; VESC still enforces its own limits. Not sent from host.
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

static const uint32_t ENC_SAMPLE_INTERVAL_MS = 10;  // 100 Hz

volatile int32_t g_encoderCount = 0;
volatile int8_t  g_lastEncoded  = 0;
bool             g_encResetPending  = false;
bool             g_encStreamEnabled = true;

void IRAM_ATTR updateEncoder() {
  int8_t a       = (int8_t)digitalRead(ENC_PIN_A);
  int8_t b       = (int8_t)digitalRead(ENC_PIN_B);
  int8_t encoded = (a << 1) | b;
  int8_t sum     = (g_lastEncoded << 2) | encoded;

  if (sum == 0b1101 || sum == 0b0100 || sum == 0b0010 || sum == 0b1011) g_encoderCount++;
  if (sum == 0b1110 || sum == 0b0111 || sum == 0b0001 || sum == 0b1000) g_encoderCount--;

  g_lastEncoded = encoded;
}

static void pollEncoderStream(uint32_t nowMs) {
  static uint32_t lastSampleMs = 0;
  static float    lastPosM     = 0.0f;
  static uint32_t lastPosMs    = 0;
  static bool     lastStreamOn = false;

  if (g_encStreamEnabled != lastStreamOn) {
    lastStreamOn = g_encStreamEnabled;
    lastSampleMs = 0;
  }

  if (!g_encStreamEnabled) {
    return;
  }

  if (lastSampleMs == 0) {
    lastSampleMs = nowMs;
    noInterrupts();
    int32_t c0 = g_encoderCount;
    interrupts();
    lastPosM  = (float)c0 * METERS_PER_COUNT;
    lastPosMs = nowMs;
    return;
  }

  if (nowMs - lastSampleMs < ENC_SAMPLE_INTERVAL_MS) return;
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
  constexpr size_t kChunk = 20;
  size_t off = 0;
  while (off < len) {
    size_t n = len - off;
    if (n > kChunk) n = kChunk;
    g_txChar->setValue(data + off, n);
    g_txChar->notify();
    off += n;
    delay(3);
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

static void processCommand(const String& cmd) {

  if (cmd == "PING") {
    sendHostLine("PONG,Quikburst");
    return;
  }

  if (cmd == "STOP") {
    UART.setCurrent(0.0f);
    UART.setBrakeCurrent(0.0f);
    g_motorActive = false;
    updateStatusLeds();
    sendHostLine("OK,STOP");
    return;
  }

  if (cmd.startsWith("SET_CURRENT,")) {
    float amps = parseFloat(cmd.substring(12));
    UART.setCurrent(amps);
    g_motorActive = (fabsf(amps) > 1e-4f);
    updateStatusLeds();
    sendHostFmt("OK,SET_CURRENT,%.3f", amps);
    return;
  }

  if (cmd == "SET_BRAKE") {
    UART.setBrakeCurrent(VESC_BRAKE_APPLY_AMPS);
    g_motorActive = true;
    updateStatusLeds();
    sendHostLine("OK,SET_BRAKE");
    return;
  }

  if (cmd.startsWith("SET_DUTY,")) {
    float duty = parseFloat(cmd.substring(9));
    if (duty < 0.0f) duty = 0.0f;
    if (duty > VESC_MAX_DUTY) duty = VESC_MAX_DUTY;
    UART.setDuty(duty);
    g_motorActive = (duty > 1e-5f);
    updateStatusLeds();
    sendHostFmt("OK,SET_DUTY,%.4f", duty);
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
    float on = parseFloat(cmd.substring(11));
    g_encStreamEnabled = (on != 0.0f);
    sendHostFmt("OK,ENC_STREAM,%d", g_encStreamEnabled ? 1 : 0);
    return;
  }

  if (cmd == "GET_VALUES") {
    if (UART.getVescValues()) {
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
  void onConnect(BLEServer*) override {
    g_bleConnected = true;
    updateStatusLeds();
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
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
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
  pollEncoderStream(now);
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

  delay(2);
}
