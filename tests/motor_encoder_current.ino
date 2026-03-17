/*
 * Motor + Encoder + Current Sensor Test (Serial only)
 *
 * Combines:
 *   - Motor control from working/pwmAndEncoder.ino (exact)
 *   - Encoder reading/processing from AhaanEncoder/newEncoderread.ino (exact)
 *   - Current sensor from tests/currentsensor.ino
 *
 * Protocol (same as pwmAndEncoder, over Serial): DRILL,<seconds>,<pwm>,<dir> → GO
 *   dir: F (forward) or B (backward)
 *   pwm: 0-100%
 *
 * Output: DATA,index,time_ms,position_m,velocity_mps,accel_mps2,current_A (same as encoder + current)
 */

#include "driver/pcnt.h"
#include <vector>
#include <algorithm>

// ============================================================================
// CONFIGURATION — from working/pwmAndEncoder.ino and AhaanEncoder/newEncoderread.ino
// ============================================================================

// Motor (from pwmAndEncoder)
#define PWM1_PIN 32
#define PWM2_PIN 33
#define EN_PIN 27
const int PWM_CHANNEL_1 = 0;
const int PWM_CHANNEL_2 = 1;
const int PWM_FREQ = 5000;
const int PWM_RESOLUTION = 10;

// Encoder (from newEncoderread)
static constexpr int      ENCODER_PIN_A       = 25;
static constexpr int      ENCODER_PIN_B       = 26;
static constexpr int      ENCODER_PPR         = 600;
static constexpr int      QUADRATURE_MULT     = 4;
static constexpr int      COUNTS_PER_REV      = ENCODER_PPR * QUADRATURE_MULT;

// Spool geometry (from newEncoderread)
static constexpr float    SPOOL_DIA_INCHES    = 4.0f;
static constexpr float    SPOOL_CIRCUMF_M     = 3.14159265f * SPOOL_DIA_INCHES * 0.0254f;
static constexpr float    METERS_PER_COUNT    = SPOOL_CIRCUMF_M / (float)COUNTS_PER_REV;

// Sampling (from newEncoderread)
static constexpr uint32_t SAMPLE_HZ           = 100;
static constexpr uint32_t SAMPLE_INTERVAL_US  = 1000000UL / SAMPLE_HZ;

// Pre/post drill: 1 second of current sampling before and after motor run
static constexpr uint32_t PRE_DRILL_SEC       = 1;
static constexpr uint32_t POST_DRILL_SEC      = 1;

// Signal processing (from newEncoderread)
static constexpr int      MEDIAN_WINDOW       = 5;
static constexpr int      MA_WINDOW           = 9;

// PCNT (from newEncoderread)
static constexpr pcnt_unit_t PCNT_UNIT        = PCNT_UNIT_0;
static constexpr int16_t  PCNT_H_LIM          = 32767;
static constexpr int16_t  PCNT_L_LIM          = -32768;
static constexpr uint16_t PCNT_FILTER_VAL     = 100;

// Current sensor (from currentsensor.ino)
#define CURRENT_SENSOR_PIN 34
#define SUPPLY_SENSOR_PIN 4
#define ZERO_OVERRIDE_PIN 0
#define ADC_BITS 12
#define ADC_MAX 4095.0
#define VREF 3.3
#define SENSITIVITY_MV_PER_A 66.0
#define DIVIDER_RATIO 2.0
#define CURRENT_SAMPLES 8

// ============================================================================
// STATE MACHINE (from pwmAndEncoder)
// ============================================================================

enum class State : uint8_t {
    IDLE,
    ARMED,
    RUNNING,
    PROCESSING,
    SENDING
};

enum class Direction : uint8_t { DIR_FORWARD, DIR_BACKWARD };

// ============================================================================
// DATA STRUCTURES (from newEncoderread + current)
// ============================================================================

struct RawSample {
    uint32_t timestamp_us;
    int32_t  count;
    float    current_A;
};

struct ProcessedSample {
    float time_s;
    float position_m;
    float velocity_mps;
    float accel_mps2;
    float current_A;
};

// ============================================================================
// GLOBAL STATE
// ============================================================================

static volatile State     g_state = State::IDLE;
static uint32_t           g_drill_duration_s = 0;
static int                g_pwm_duty = 50;
static Direction          g_direction = Direction::DIR_FORWARD;

static volatile int32_t   g_overflowAccum = 0;

static std::vector<RawSample>       g_rawSamples;
static std::vector<ProcessedSample> g_processed;

static uint32_t g_nextSampleUs   = 0;
static uint32_t g_drillStartUs   = 0;   // GO received
static uint32_t g_motorStartUs   = 0;   // motor on
static uint32_t g_motorEndUs     = 0;   // motor off
static uint32_t g_drillEndUs     = 0;   // post phase done
static int32_t  g_countAtGo      = 0;

static size_t g_sendIndex = 0;

// Periodic "ready" in IDLE so Python can connect anytime (ESP32 may reset when serial opens)
static constexpr uint32_t READY_INTERVAL_MS = 10000;
static uint32_t g_lastReadyMs = 0;

// Current sensor (from currentsensor.ino)
float overrideZeroMV = -1.0;
bool lastButtonState = true;

// ============================================================================
// PCNT ISR (from newEncoderread)
// ============================================================================

void IRAM_ATTR pcntOverflowISR(void* arg) {
    uint32_t status = 0;
    pcnt_get_event_status(PCNT_UNIT, &status);
    if (status & PCNT_EVT_H_LIM) g_overflowAccum += PCNT_H_LIM;
    if (status & PCNT_EVT_L_LIM) g_overflowAccum += PCNT_L_LIM;
}

// ============================================================================
// ENCODER READ (from newEncoderread)
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
// MOTOR CONTROL (from pwmAndEncoder — exact)
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

static int dutyToPwm(int duty) {
    duty = constrain(duty, 0, 100);
    return map(100 - duty, 0, 100, 0, 1023);
}

// ============================================================================
// CURRENT SENSOR (from currentsensor.ino)
// ============================================================================

static float readCurrentAmps() {
    uint32_t sum = 0;
    for (int i = 0; i < CURRENT_SAMPLES; i++) {
        sum += analogRead(CURRENT_SENSOR_PIN);
        delayMicroseconds(100);
    }
    float sensorMV = ((sum / (float)CURRENT_SAMPLES) / ADC_MAX) * VREF * 1000.0f;

    float supplyDivider = 0;
    for (int i = 0; i < 4; i++) {
        supplyDivider += analogRead(SUPPLY_SENSOR_PIN);
        delayMicroseconds(50);
    }
    float supplyV = ((supplyDivider / 4.0f) / ADC_MAX) * VREF * DIVIDER_RATIO;
    float zeroMV = (overrideZeroMV >= 0) ? overrideZeroMV : (supplyV * 1000.0f) / 2.0f;
    return (sensorMV - zeroMV) / SENSITIVITY_MV_PER_A;
}

static void checkZeroOverride() {
    bool btn = (digitalRead(ZERO_OVERRIDE_PIN) == LOW);
    if (btn && !lastButtonState) {
        uint32_t sum = 0;
        for (int i = 0; i < 16; i++) {
            sum += analogRead(CURRENT_SENSOR_PIN);
            delayMicroseconds(200);
        }
        overrideZeroMV = ((sum / 16.0f) / ADC_MAX) * VREF * 1000.0f;
        Serial.print(">>> ZERO OVERRIDE: ");
        Serial.print(overrideZeroMV, 1);
        Serial.println(" mV <<<");
    }
    lastButtonState = btn;
}

// ============================================================================
// SERIAL COMMAND PROCESSING (from pwmAndEncoder processCommand, Serial instead of BLE)
// ============================================================================

static String g_serialBuffer = "";

static void serialSend(const char* msg) {
    Serial.print(msg);
}

static void serialSendFormatted(const char* fmt, ...) {
    char buf[200];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    Serial.print(buf);
}

static void processCommand(const String& cmd) {
    Serial.print("[RX] ");
    Serial.println(cmd);

    if (cmd.startsWith("DRILL,")) {
        if (g_state != State::IDLE) {
            serialSendFormatted("ERROR,NOT_IDLE,received:%s\n", cmd.c_str());
            return;
        }
        int c1 = cmd.indexOf(',', 6);
        if (c1 < 0) {
            serialSendFormatted("ERROR,BAD_FORMAT,received:%s\n", cmd.c_str());
            return;
        }
        int c2 = cmd.indexOf(',', c1 + 1);
        int c3 = cmd.indexOf(',', c2 + 1);
        int end = cmd.length();

        String durStr = cmd.substring(6, c1);
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
            serialSendFormatted("ERROR,INVALID_DURATION,received:%s\n", cmd.c_str());
            return;
        }

        size_t totalSec = PRE_DRILL_SEC + g_drill_duration_s + POST_DRILL_SEC;
        size_t expectedSamples = (size_t)totalSec * SAMPLE_HZ + 128;
        g_rawSamples.clear();
        g_processed.clear();
        try {
            g_rawSamples.reserve(expectedSamples);
        } catch (...) {
            serialSendFormatted("ERROR,OUT_OF_MEMORY,received:%s\n", cmd.c_str());
            return;
        }

        g_state = State::ARMED;
        Serial.printf("[STATE] ARMED duration=%u pwm=%d dir=%s\n",
            g_drill_duration_s, g_pwm_duty,
            g_direction == Direction::DIR_FORWARD ? "F" : "B");
        serialSendFormatted("READY,%u,%d,%s\n", g_drill_duration_s, g_pwm_duty,
            g_direction == Direction::DIR_FORWARD ? "F" : "B");
        return;
    }

    if (cmd == "GO") {
        if (g_state != State::ARMED) {
            serialSendFormatted("ERROR,NOT_ARMED,received:%s\n", cmd.c_str());
            return;
        }
        g_countAtGo    = readEncoderCount();
        g_drillStartUs = micros();
        g_motorStartUs = g_drillStartUs + (PRE_DRILL_SEC * 1000000UL);
        g_motorEndUs   = g_motorStartUs + (g_drill_duration_s * 1000000UL);
        g_drillEndUs   = g_motorEndUs + (POST_DRILL_SEC * 1000000UL);
        g_nextSampleUs = g_drillStartUs;
        g_rawSamples.clear();
        g_state = State::RUNNING;
        Serial.println("[STATE] RUNNING (1s pre, drill, 1s post)");
        serialSend("RUNNING\n");
        return;
    }

    if (cmd == "ABORT") {
        if (g_state != State::IDLE) {
            setMotorIdle();
            g_rawSamples.clear();
            g_processed.clear();
            g_state = State::IDLE;
            serialSend("ABORTED\n");
        }
        return;
    }

    serialSendFormatted("ERROR,UNKNOWN_CMD,received:%s\n", cmd.c_str());
}

static void pollSerialCommands() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n' || c == '\r') {
            if (g_serialBuffer.length() > 0) {
                processCommand(g_serialBuffer);
                g_serialBuffer = "";
            }
        } else {
            g_serialBuffer += c;
            if (g_serialBuffer.length() > 200) g_serialBuffer = "";
        }
    }
}

// ============================================================================
// PCNT SETUP (from newEncoderread — exact)
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
// PWM / MOTOR SETUP (from pwmAndEncoder — exact)
// ============================================================================

static void setupMotor() {
    pinMode(EN_PIN, OUTPUT);
    digitalWrite(EN_PIN, LOW);
    ledcAttachChannel(PWM1_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_1);
    ledcAttachChannel(PWM2_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_2);
    setMotorIdle();
}

// ============================================================================
// SIGNAL PROCESSING (from newEncoderread — exact)
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
        g_processed[i].current_A    = g_rawSamples[i].current_A;
    }
    g_rawSamples.clear();
    g_rawSamples.shrink_to_fit();
    return true;
}

// ============================================================================
// SETUP
// ============================================================================

void setup() {
    Serial.begin(115200);
    delay(500);

    analogReadResolution(ADC_BITS);
    analogSetAttenuation(ADC_11db);
    pinMode(CURRENT_SENSOR_PIN, INPUT);
    pinMode(SUPPLY_SENSOR_PIN, INPUT);
    pinMode(ZERO_OVERRIDE_PIN, INPUT_PULLUP);

    setupMotor();
    setupPCNT();

    Serial.println();
    Serial.println("Motor + Encoder + Current (Serial)");
    Serial.println("Protocol: DRILL,<seconds>,<pwm>,<F|B> then GO");
    Serial.println("Zero override: GPIO0 - press when 0A before run");
    Serial.println("[READY]");
}

// ============================================================================
// LOOP (from pwmAndEncoder + newEncoderread, Serial instead of BLE)
// ============================================================================

void loop() {
    uint32_t nowUs = micros();

    checkZeroOverride();

    switch (g_state) {
        case State::IDLE: {
            setMotorIdle();
            pollSerialCommands();
            uint32_t nowMs = millis();
            if (nowMs - g_lastReadyMs >= READY_INTERVAL_MS) {
                g_lastReadyMs = nowMs;
                serialSend("READY\n");  // Periodic so Python can connect anytime
            }
            delay(10);
            break;
        }

        case State::ARMED:
            pollSerialCommands();
            delay(10);
            break;

        case State::RUNNING: {
            if (nowUs >= g_drillEndUs) {
                setMotorIdle();
                g_state = State::PROCESSING;
                serialSend("DONE\n");
                break;
            }

            pollSerialCommands();

            // Motor idle during pre and post phases; run only during drill phase
            if (nowUs >= g_motorStartUs && nowUs < g_motorEndUs) {
                int pwm = dutyToPwm(g_pwm_duty);
                if (g_direction == Direction::DIR_FORWARD)
                    setMotorForward(pwm);
                else
                    setMotorBackward(pwm);
            } else {
                setMotorIdle();
            }

            if ((int32_t)(nowUs - g_nextSampleUs) >= 0) {
                RawSample s;
                s.timestamp_us = nowUs;
                s.count        = readEncoderCount();
                s.current_A    = readCurrentAmps();
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
                serialSend("ERROR,PROCESSING_FAILED\n");
                g_state = State::IDLE;
            }
            break;
        }

        case State::SENDING: {
            if (g_sendIndex < g_processed.size()) {
                const ProcessedSample& s = g_processed[g_sendIndex];
                uint32_t time_ms = (uint32_t)(s.time_s * 1000.0f + 0.5f);
                char buf[160];
                snprintf(buf, sizeof(buf), "DATA,%u,%u,%.5f,%.4f,%.3f,%.4f\n",
                    (unsigned)g_sendIndex, time_ms,
                    s.position_m, s.velocity_mps, s.accel_mps2, s.current_A);
                serialSend(buf);
                g_sendIndex++;
                delay(12);
            } else {
                serialSend("END\n");
                g_processed.clear();
                g_processed.shrink_to_fit();
                g_state = State::IDLE;
            }
            break;
        }
    }
}
