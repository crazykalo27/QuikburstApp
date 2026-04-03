/*
 * VESC UART Test — ESP32 ↔ host (USB Serial + BLE) ↔ VESC (UART2)
 *
 * Serial  (USB, 115200) — same text protocol as before
 * BLE     — Nordic UART Service (NUS); advertised name "Quikburst" for discovery
 *
 * VESC: Serial2 @ VESC_UART_RX_PIN / VESC_UART_TX_PIN (see below).
 *
 * Protocol (newline-terminated; identical on USB and BLE):
 *   PING                      → PONG,Quikburst
 *   SET_CURRENT,<amps>        → OK,SET_CURRENT,...
 *   SET_BRAKE,<amps>          → ...
 *   SET_DUTY,<duty>           → duty clamped to 0…0.20 (20%)
 *   SET_RPM,<erpm>            → ...
 *   STOP                      → OK,STOP
 *   GET_VALUES                → TELEM,...
 *   GET_FW                    → FW,...
 *   KEEPALIVE                 → OK,KEEPALIVE
 *   [READY]                   — periodic heartbeat (USB + BLE when connected)
 *
 * BLE UUIDs (Nordic UART Service — works with bleak / nRF Connect):
 *   Service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *   RX (host writes) 6E400002-B5A3-F393-E0A9-E50E24DCCA9E
 *   TX (notify)      6E400003-B5A3-F393-E0A9-E50E24DCCA9E
 */

#include <VescUart.h>
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

static constexpr char BLE_DEVICE_NAME[] = "Quikburst";

#define NUS_SERVICE_UUID        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_UUID             "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_TX_UUID             "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

VescUart UART;

static String g_serialCmdBuf;
static String g_bleCmdBuf;

static constexpr uint32_t READY_INTERVAL_MS = 5000;
static uint32_t g_lastReadyMs = 0;

static BLEServer* g_server = nullptr;
static BLECharacteristic* g_txChar = nullptr;
static bool g_bleConnected = false;
static bool g_bleWasConnected = false;

// ---------------------------------------------------------------------------
// Host output: USB Serial + BLE notify (chunked; client should reassemble to lines)
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
  Serial.println(line);
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
    sendHostLine("OK,STOP");
    return;
  }

  if (cmd.startsWith("SET_CURRENT,")) {
    float amps = parseFloat(cmd.substring(12));
    UART.setCurrent(amps);
    sendHostFmt("OK,SET_CURRENT,%.3f", amps);
    return;
  }

  if (cmd.startsWith("SET_BRAKE,")) {
    float amps = parseFloat(cmd.substring(10));
    UART.setBrakeCurrent(amps);
    sendHostFmt("OK,SET_BRAKE,%.3f", amps);
    return;
  }

  if (cmd.startsWith("SET_DUTY,")) {
    float duty = parseFloat(cmd.substring(9));
    if (duty < 0.0f) duty = 0.0f;
    if (duty > VESC_MAX_DUTY) duty = VESC_MAX_DUTY;
    UART.setDuty(duty);
    sendHostFmt("OK,SET_DUTY,%.4f", duty);
    return;
  }

  if (cmd.startsWith("SET_RPM,")) {
    float rpm = parseFloat(cmd.substring(8));
    UART.setRPM(rpm);
    sendHostFmt("OK,SET_RPM,%.1f", rpm);
    return;
  }

  if (cmd == "KEEPALIVE") {
    UART.sendKeepalive();
    sendHostLine("OK,KEEPALIVE");
    return;
  }

  if (cmd == "GET_VALUES") {
    if (UART.getVescValues()) {
      sendHostFmt("TELEM,%.1f,%.4f,%.2f,%.3f,%.3f,%.1f,%.1f,%ld,%ld,%d",
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
    sendHostLine("OK,BT_CONNECTED");
  }
  void onDisconnect(BLEServer*) override {
    g_bleConnected = false;
    Serial.println("(BLE disconnected)");
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

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(NUS_SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.print("BLE advertising as \"");
  Serial.print(BLE_DEVICE_NAME);
  Serial.println("\" (Nordic UART Service)");
}

// ---------------------------------------------------------------------------
// USB Serial
// ---------------------------------------------------------------------------

static void pollSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    feedLineBuffer(g_serialCmdBuf, c);
  }
}

// ---------------------------------------------------------------------------
// setup / loop
// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  delay(800);

  Serial2.begin(115200, SERIAL_8N1, VESC_UART_RX_PIN, VESC_UART_TX_PIN);
  UART.setSerialPort(&Serial2);

  setupBle();

  delay(300);
  Serial.println();
  Serial.println("VESC UART Test (ESP32) — USB + BLE \"Quikburst\"");
  Serial.println("Commands: PING | SET_CURRENT,<A> | SET_BRAKE,<A> | SET_DUTY,<d> | SET_RPM,<e> | STOP | GET_VALUES | GET_FW | KEEPALIVE");
  sendHostLine("[READY]");
}

void loop() {
  pollSerial();

  uint32_t now = millis();
  if (now - g_lastReadyMs >= READY_INTERVAL_MS) {
    g_lastReadyMs = now;
    sendHostLine("[READY]");
  }

  if (!g_bleConnected && g_bleWasConnected) {
    delay(300);
    BLEDevice::startAdvertising();
  }
  g_bleWasConnected = g_bleConnected;

  delay(2);
}
