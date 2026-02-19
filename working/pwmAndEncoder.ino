/*
 * PWM Motor Control + Encoder for ESP32 — BLE Version
 *
 * Combines motor control with encoder reading, transmits drill data over BLE.
 * Protocol: DRILL,<seconds>,<pwm>,<dir> → GO
 *   dir: F (forward) or B (backward)
 *   pwm: 0-100%
 *
 * Motor: PWM1=32, PWM2=33, EN=27. EN always LOW.
 * Idle: both PWM1 and PWM2 HIGH.
 * Forward: PWM2=pwm, PWM1=HIGH. Backward: PWM1=pwm, PWM2=HIGH.
 *
 * Encoder: A=25, B=26. Taiss 600 PPR, x4 quadrature = 2400 CPR.
 * BLE: Nordic UART Service (NUS), same as newEncoderread.ino
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/pcnt.h"
#include <vector>
#include <algorithm>

// ============================================================================
// CONFIGURATION
// ============================================================================

// Motor
#define PWM1_PIN 32
#define PWM2_PIN 33
#define EN_PIN 27
const int PWM_CHANNEL_1 = 0;
const int PWM_CHANNEL_2 = 1;
const int PWM_FREQ = 5000;
const int PWM_RESOLUTION = 10;  // 0-1023

// Encoder
static constexpr int      ENCODER_PIN_A       = 25;
static constexpr int      ENCODER_PIN_B       = 26;
static constexpr int      ENCODER_PPR         = 600;
static constexpr int      QUADRATURE_MULT     = 4;
static constexpr int      COUNTS_PER_REV      = ENCODER_PPR * QUADRATURE_MULT;  // 2400

// Spool geometry (matches newEncoderread.ino exactly)
//   C = π × d = π × 4.0 in × 0.0254 m/in
static constexpr float    SPOOL_DIA_INCHES    = 4.0f;
static constexpr float    SPOOL_CIRCUMF_M     = 3.14159265f * SPOOL_DIA_INCHES * 0.0254f;
static constexpr float    METERS_PER_COUNT    = SPOOL_CIRCUMF_M / (float)COUNTS_PER_REV;

// Sampling
static constexpr uint32_t SAMPLE_HZ           = 100;
static constexpr uint32_t SAMPLE_INTERVAL_US  = 1000000UL / SAMPLE_HZ;

// Signal processing (from newEncoderread)
static constexpr int      MEDIAN_WINDOW       = 5;
static constexpr int      MA_WINDOW           = 9;

// BLE
static constexpr uint16_t BLE_MTU             = 256;
static constexpr uint32_t BLE_TX_PACE_MS      = 12;
static const char*        DEVICE_NAME         = "QuickBurst";

// PCNT
static constexpr pcnt_unit_t PCNT_UNIT        = PCNT_UNIT_0;
static constexpr int16_t  PCNT_H_LIM          = 32767;
static constexpr int16_t  PCNT_L_LIM          = -32768;
static constexpr uint16_t PCNT_FILTER_VAL     = 100;

#define NUS_SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_RX_UUID       "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define NUS_TX_UUID       "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// ============================================================================
// STATE MACHINE
// ============================================================================

enum class State : uint8_t {
    IDLE,
    ARMED,
    RUNNING,      // Motor runs, encoder sampled
    PROCESSING,
    SENDING
};

enum class Direction : uint8_t { DIR_FORWARD, DIR_BACKWARD };

// ============================================================================
// DATA STRUCTURES
// ============================================================================

struct RawSample {
    uint32_t timestamp_us;
    int32_t  count;
};

struct ProcessedSample {
    float time_s;
    float position_m;
    float velocity_mps;
    float accel_mps2;
};

// ============================================================================
// GLOBAL STATE
// ============================================================================

static volatile State     g_state = State::IDLE;
static uint32_t           g_drill_duration_s = 0;
static int                g_pwm_duty = 50;   // 0-100
static Direction          g_direction = Direction::DIR_FORWARD;

static volatile int32_t   g_overflowAccum = 0;

static std::vector<RawSample>       g_rawSamples;
static std::vector<ProcessedSample> g_processed;

static uint32_t g_nextSampleUs   = 0;
static uint32_t g_drillStartUs   = 0;
static uint32_t g_drillEndUs     = 0;
static int32_t  g_countAtGo      = 0;

static BLECharacteristic* g_txChar = nullptr;
static BLECharacteristic* g_rxChar = nullptr;
static bool               g_bleConnected = false;
static String             g_rxBuffer = "";

static size_t g_sendIndex = 0;

// ============================================================================
// PCNT ISR
// ============================================================================

void IRAM_ATTR pcntOverflowISR(void* arg) {
    uint32_t status = 0;
    pcnt_get_event_status(PCNT_UNIT, &status);
    if (status & PCNT_EVT_H_LIM) g_overflowAccum += PCNT_H_LIM;
    if (status & PCNT_EVT_L_LIM) g_overflowAccum += PCNT_L_LIM;
}

// ============================================================================
// ENCODER READ
// ============================================================================

static int32_t readEncoderCount() {
    portDISABLE_INTERRUPTS();
    int16_t hw = 0;
    pcnt_get_counter_value(PCNT_UNIT, &hw);
    int32_t total = g_overflowAccum + (int32_t)hw;
    portENABLE_INTERRUPTS();
    return total;
}

// ============================================================================
// MOTOR CONTROL
// ============================================================================

void setMotorIdle() {
    ledcWriteChannel(PWM_CHANNEL_1, 1023);
    ledcWriteChannel(PWM_CHANNEL_2, 1023);
}

void setMotorForward(int pwm) {
    ledcWriteChannel(PWM_CHANNEL_2, pwm);
    ledcWriteChannel(PWM_CHANNEL_1, 1023);
}

void setMotorBackward(int pwm) {
    ledcWriteChannel(PWM_CHANNEL_1, pwm);
    ledcWriteChannel(PWM_CHANNEL_2, 1023);
}

// Map 0-100 duty to 0-1023 ( inverted: 5→95%, 95→5% for compatibility)
static int dutyToPwm(int duty) {
    duty = constrain(duty, 0, 100);
    return map(100 - duty, 0, 100, 0, 1023);
}

// ============================================================================
// BLE HELPERS
// ============================================================================

static void bleSend(const char* msg) {
    if (!g_bleConnected || g_txChar == nullptr) return;
    g_txChar->setValue((uint8_t*)msg, strlen(msg));
    g_txChar->notify();
}

static void bleSendFormatted(const char* fmt, ...) {
    char buf[200];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    bleSend(buf);
}

// ============================================================================
// BLE CALLBACKS
// ============================================================================

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) override {
        g_bleConnected = true;
        Serial.println("[BLE] Client connected");
    }
    void onDisconnect(BLEServer* pServer) override {
        g_bleConnected = false;
        Serial.println("[BLE] Client disconnected");
        if (g_state == State::RUNNING || g_state == State::ARMED) {
            g_state = State::IDLE;
            setMotorIdle();
        }
        pServer->startAdvertising();
    }
};

class RxCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pChar) override {
        String val = pChar->getValue();
        g_rxBuffer += val;
        int newlineIdx;
        while ((newlineIdx = g_rxBuffer.indexOf('\n')) >= 0) {
            String line = g_rxBuffer.substring(0, newlineIdx);
            g_rxBuffer = g_rxBuffer.substring(newlineIdx + 1);
            line.trim();
            if (line.length() > 0) processCommand(line);
        }
    }

    void processCommand(const String& cmd) {
        Serial.print("[BLE RX] ");
        Serial.println(cmd);

        if (cmd.startsWith("DRILL,")) {
            if (g_state != State::IDLE) {
                bleSendFormatted("ERROR,NOT_IDLE,received:%s\n", cmd.c_str());
                return;
            }
            // DRILL,<seconds>,<pwm>,<F|B> — parse with indexOf (robust to BLE chunking)
            // "DRILL," is 6 chars; first value starts at index 6
            int c1 = cmd.indexOf(',', 6);   // comma after duration (skip comma in "DRILL,")
            if (c1 < 0) {
                bleSendFormatted("ERROR,BAD_FORMAT,received:%s\n", cmd.c_str());
                return;
            }
            int c2 = cmd.indexOf(',', c1 + 1);
            int c3 = cmd.indexOf(',', c2 + 1);
            int end = cmd.length();

            String durStr = cmd.substring(6, c1);   // duration is between "DRILL," and first comma
            durStr.trim();
            g_drill_duration_s = durStr.toInt();

            if (c2 >= 0) {
                String pwmStr = cmd.substring(c1 + 1, c2);
                pwmStr.trim();
                g_pwm_duty = pwmStr.toInt();
                if (g_pwm_duty < 0 || g_pwm_duty > 100) g_pwm_duty = 50;
            } else {
                g_pwm_duty = 50;
            }

            if (c2 >= 0 && c3 >= 0) {
                String dirStr = cmd.substring(c2 + 1, c3);
                dirStr.trim();
                dirStr.toUpperCase();
                g_direction = (dirStr == "B") ? Direction::DIR_BACKWARD : Direction::DIR_FORWARD;
            } else if (c2 >= 0) {
                String dirStr = cmd.substring(c2 + 1, end);
                dirStr.trim();
                dirStr.toUpperCase();
                g_direction = (dirStr == "B") ? Direction::DIR_BACKWARD : Direction::DIR_FORWARD;
            } else {
                g_direction = Direction::DIR_FORWARD;
            }

            if (g_drill_duration_s < 1 || g_drill_duration_s > 10) {
                bleSendFormatted("ERROR,INVALID_DURATION,received:%s\n", cmd.c_str());
                return;
            }

            size_t expectedSamples = (size_t)g_drill_duration_s * SAMPLE_HZ + 128;
            g_rawSamples.clear();
            g_processed.clear();
            try {
                g_rawSamples.reserve(expectedSamples);
            } catch (...) {
                bleSendFormatted("ERROR,OUT_OF_MEMORY,received:%s\n", cmd.c_str());
                return;
            }

            g_state = State::ARMED;
            Serial.printf("[STATE] ARMED duration=%u pwm=%d dir=%s\n",
                g_drill_duration_s, g_pwm_duty,
                g_direction == Direction::DIR_FORWARD ? "F" : "B");
            bleSendFormatted("READY,%u,%d,%s\n", g_drill_duration_s, g_pwm_duty,
                g_direction == Direction::DIR_FORWARD ? "F" : "B");
            return;
        }

        if (cmd == "GO") {
            if (g_state != State::ARMED) {
                bleSendFormatted("ERROR,NOT_ARMED,received:%s\n", cmd.c_str());
                return;
            }
            g_countAtGo    = readEncoderCount();
            g_drillStartUs = micros();
            g_drillEndUs   = g_drillStartUs + (g_drill_duration_s * 1000000UL);
            g_nextSampleUs = g_drillStartUs;
            g_rawSamples.clear();
            g_state = State::RUNNING;
            Serial.println("[STATE] RUNNING");
            bleSend("RUNNING\n");
            return;
        }

        if (cmd == "ABORT") {
            if (g_state != State::IDLE) {
                setMotorIdle();
                g_rawSamples.clear();
                g_processed.clear();
                g_state = State::IDLE;
                bleSend("ABORTED\n");
            }
            return;
        }

        bleSendFormatted("ERROR,UNKNOWN_CMD,received:%s\n", cmd.c_str());
    }
};

// ============================================================================
// PCNT SETUP
// ============================================================================

static void setupPCNT() {
    pcnt_config_t cfg0 = {};
    cfg0.pulse_gpio_num = ENCODER_PIN_A;
    cfg0.ctrl_gpio_num  = ENCODER_PIN_B;
    cfg0.lctrl_mode     = PCNT_MODE_REVERSE;
    cfg0.hctrl_mode     = PCNT_MODE_KEEP;
    cfg0.pos_mode       = PCNT_COUNT_INC;
    cfg0.neg_mode       = PCNT_COUNT_DEC;
    cfg0.counter_h_lim  = PCNT_H_LIM;
    cfg0.counter_l_lim  = PCNT_L_LIM;
    cfg0.unit           = PCNT_UNIT;
    cfg0.channel        = PCNT_CHANNEL_0;
    pcnt_unit_config(&cfg0);

    pcnt_config_t cfg1 = {};
    cfg1.pulse_gpio_num = ENCODER_PIN_B;
    cfg1.ctrl_gpio_num  = ENCODER_PIN_A;
    cfg1.lctrl_mode     = PCNT_MODE_KEEP;
    cfg1.hctrl_mode     = PCNT_MODE_REVERSE;
    cfg1.pos_mode       = PCNT_COUNT_INC;
    cfg1.neg_mode       = PCNT_COUNT_DEC;
    cfg1.counter_h_lim  = PCNT_H_LIM;
    cfg1.counter_l_lim  = PCNT_L_LIM;
    cfg1.unit           = PCNT_UNIT;
    cfg1.channel        = PCNT_CHANNEL_1;
    pcnt_unit_config(&cfg1);

    pcnt_set_filter_value(PCNT_UNIT, PCNT_FILTER_VAL);
    pcnt_filter_enable(PCNT_UNIT);
    pcnt_event_enable(PCNT_UNIT, PCNT_EVT_H_LIM);
    pcnt_event_enable(PCNT_UNIT, PCNT_EVT_L_LIM);
    pcnt_isr_service_install(0);
    pcnt_isr_handler_add(PCNT_UNIT, pcntOverflowISR, NULL);
    pcnt_counter_pause(PCNT_UNIT);
    pcnt_counter_clear(PCNT_UNIT);
    pcnt_counter_resume(PCNT_UNIT);
}

// ============================================================================
// PWM / MOTOR SETUP
// ============================================================================

static void setupMotor() {
    pinMode(EN_PIN, OUTPUT);
    digitalWrite(EN_PIN, LOW);
    ledcAttachChannel(PWM1_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_1);
    ledcAttachChannel(PWM2_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_2);
    setMotorIdle();
}

// ============================================================================
// SIGNAL PROCESSING (from newEncoderread)
// ============================================================================

static void medianFilter(std::vector<float>& data) {
    const int N = (int)data.size();
    const int halfW = MEDIAN_WINDOW / 2;
    if (N < MEDIAN_WINDOW) return;
    std::vector<float> out(data);
    float window[MEDIAN_WINDOW];
    for (int i = halfW; i < N - halfW; i++) {
        for (int j = 0; j < MEDIAN_WINDOW; j++)
            window[j] = data[i - halfW + j];
        for (int a = 1; a < MEDIAN_WINDOW; a++) {
            float key = window[a];
            int b = a - 1;
            while (b >= 0 && window[b] > key) {
                window[b + 1] = window[b];
                b--;
            }
            window[b + 1] = key;
        }
        out[i] = window[halfW];
    }
    data = out;
}

static void movingAverage(std::vector<float>& data) {
    const int N = (int)data.size();
    const int halfW = MA_WINDOW / 2;
    if (N < MA_WINDOW) return;
    std::vector<float> out(data);
    float sum = 0.0f;
    for (int j = 0; j < MA_WINDOW; j++) sum += data[j];
    out[halfW] = sum / (float)MA_WINDOW;
    for (int i = halfW + 1; i < N - halfW; i++) {
        sum += data[i + halfW] - data[i - halfW - 1];
        out[i] = sum / (float)MA_WINDOW;
    }
    data = out;
}

static bool processData() {
    const size_t N = g_rawSamples.size();
    if (N < (size_t)MA_WINDOW + 2) return false;

    const float dt = 1.0f / (float)SAMPLE_HZ;
    const float dt2 = 2.0f * dt;

    std::vector<float> pos(N);
    for (size_t i = 0; i < N; i++)
        pos[i] = (float)(g_rawSamples[i].count - g_countAtGo) * METERS_PER_COUNT;

    medianFilter(pos);
    movingAverage(pos);

    std::vector<float> vel(N);
    vel[0]     = (pos[1] - pos[0]) / dt;
    vel[N - 1] = (pos[N - 1] - pos[N - 2]) / dt;
    for (size_t i = 1; i < N - 1; i++)
        vel[i] = (pos[i + 1] - pos[i - 1]) / dt2;

    std::vector<float> acc(N);
    acc[0]     = (vel[1] - vel[0]) / dt;
    acc[N - 1] = (vel[N - 1] - vel[N - 2]) / dt;
    for (size_t i = 1; i < N - 1; i++)
        acc[i] = (vel[i + 1] - vel[i - 1]) / dt2;

    g_processed.resize(N);
    for (size_t i = 0; i < N; i++) {
        float t_s = (float)(g_rawSamples[i].timestamp_us - g_rawSamples[0].timestamp_us) / 1e6f;
        g_processed[i].time_s       = t_s;
        g_processed[i].position_m   = pos[i];
        g_processed[i].velocity_mps = vel[i];
        g_processed[i].accel_mps2   = acc[i];
    }
    g_rawSamples.clear();
    g_rawSamples.shrink_to_fit();
    return true;
}

// ============================================================================
// BLE SETUP
// ============================================================================

static void setupBLE() {
    BLEDevice::init(DEVICE_NAME);
    BLEDevice::setMTU(BLE_MTU);
    BLEServer* pServer = BLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());
    BLEService* pService = pServer->createService(NUS_SERVICE_UUID);

    g_txChar = pService->createCharacteristic(
        NUS_TX_UUID,
        BLECharacteristic::PROPERTY_NOTIFY
    );
    g_txChar->addDescriptor(new BLE2902());

    g_rxChar = pService->createCharacteristic(
        NUS_RX_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
    );
    g_rxChar->setCallbacks(new RxCallbacks());

    pService->start();
    BLEAdvertising* pAdv = BLEDevice::getAdvertising();
    pAdv->addServiceUUID(NUS_SERVICE_UUID);
    pAdv->setScanResponse(true);
    pAdv->setMinPreferred(0x06);
    pAdv->setMaxPreferred(0x12);
    BLEDevice::startAdvertising();
    Serial.printf("[BLE] Advertising as '%s'\n", DEVICE_NAME);
}

// ============================================================================
// SETUP
// ============================================================================

void setup() {
    Serial.begin(115200);
    setupMotor();
    setupPCNT();
    setupBLE();
    Serial.println("[READY] QuickBurst PWM+Encoder BLE");
}

// ============================================================================
// LOOP
// ============================================================================

void loop() {
    uint32_t nowUs = micros();

    switch (g_state) {
        case State::IDLE:
            setMotorIdle();
            delay(10);
            break;

        case State::ARMED:
            delay(10);
            break;

        case State::RUNNING: {
            if (nowUs >= g_drillEndUs) {
                setMotorIdle();
                g_state = State::PROCESSING;
                bleSend("DONE\n");
                break;
            }

            if (!g_bleConnected) {
                setMotorIdle();
                g_rawSamples.clear();
                g_state = State::IDLE;
                break;
            }

            int pwm = dutyToPwm(g_pwm_duty);
            if (g_direction == Direction::DIR_FORWARD)
                setMotorForward(pwm);
            else
                setMotorBackward(pwm);

            if ((int32_t)(nowUs - g_nextSampleUs) >= 0) {
                RawSample s;
                s.timestamp_us = nowUs;
                s.count        = readEncoderCount();
                g_rawSamples.push_back(s);
                g_nextSampleUs += SAMPLE_INTERVAL_US;
                if ((int32_t)(nowUs - g_nextSampleUs) > (int32_t)(2 * SAMPLE_INTERVAL_US))
                    g_nextSampleUs = nowUs + SAMPLE_INTERVAL_US;
            }
            break;
        }

        case State::PROCESSING: {
            bool ok = processData();
            if (ok) {
                g_sendIndex = 0;
                g_state = State::SENDING;
            } else {
                bleSend("ERROR,PROCESSING_FAILED\n");
                g_state = State::IDLE;
            }
            break;
        }

        case State::SENDING: {
            if (!g_bleConnected) {
                g_processed.clear();
                g_state = State::IDLE;
                break;
            }
            if (g_sendIndex < g_processed.size()) {
                const ProcessedSample& s = g_processed[g_sendIndex];
                uint32_t time_ms = (uint32_t)(s.time_s * 1000.0f + 0.5f);
                char buf[128];
                snprintf(buf, sizeof(buf), "DATA,%u,%u,%.5f,%.4f,%.3f\n",
                    (unsigned)g_sendIndex, time_ms,
                    s.position_m, s.velocity_mps, s.accel_mps2);
                bleSend(buf);
                g_sendIndex++;
                delay(BLE_TX_PACE_MS);
            } else {
                bleSend("END\n");
                g_processed.clear();
                g_processed.shrink_to_fit();
                g_state = State::IDLE;
            }
            break;
        }
    }
}
