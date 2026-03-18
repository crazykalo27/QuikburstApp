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
 * Output: DATA,index,time_ms,position_m,velocity_mps,accel_mps2,current_A,error_A,cmd_duty_pct,cmd_pwm,dir_sign
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
const int PWM_RESOLUTION = 12;  // 12-bit = 4096 levels (~0.024% per step)
const int PWM_MAX_VAL = (1 << PWM_RESOLUTION) - 1;  // 4095

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

// Safety limits (firmware enforces even if client sends bad values)
#define PWM_MAX_SAFE 25
#define DURATION_MIN_SAFE 1
#define DURATION_MAX_SAFE 10

// Current-control safety limits (P-only testing)
#define DURATION_MAX_CURRENT_SAFE 20
#define PWM_MAX_CURRENT_CONTROL_SAFE 10  // hard cap: never exceed 10% duty in current-control mode

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
#define CURRENT_SENSOR_OUTPUT_DIVIDER 2.0  // 2:1 divider at sensor output; ADC reads 1/2 of sensor output
#define CURRENT_SAMPLES 8

// ============================================================================
// STATE MACHINE (from pwmAndEncoder)
// ============================================================================

enum class State : uint8_t {
    IDLE,
    ARMED,
    RUNNING,
    CURRENT_CONTROL,
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
    float    error_A;
    float    cmd_duty_pct;
    int      cmd_pwm;   // actual PWM (0-1023) sent to motor
    int8_t   dir_sign;  // +1 forward, -1 backward
};

struct ProcessedSample {
    float time_s;
    float position_m;
    float velocity_mps;
    float accel_mps2;
    float current_A;
    float error_A;
    float cmd_duty_pct;
    int   cmd_pwm;
    int8_t dir_sign;
};

// ============================================================================
// GLOBAL STATE
// ============================================================================

static volatile State     g_state = State::IDLE;
static uint32_t           g_drill_duration_s = 0;
static float              g_pwm_duty = 50.0f;
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

// Current PID control
float c_kp = 1.0f;
float c_ki = 0.0f;
float c_kd = 0.0f;

// Current control setpoint + mode flag (support only; controller itself is WIP)
float g_des_current_A = 0.0f;
bool g_useCurrentControl = false;

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
    ledcWriteChannel(PWM_CHANNEL_1, PWM_MAX_VAL);
    ledcWriteChannel(PWM_CHANNEL_2, PWM_MAX_VAL);
}

void setMotorForward(int pwm) {
    ledcWriteChannel(PWM_CHANNEL_2, pwm);
    ledcWriteChannel(PWM_CHANNEL_1, PWM_MAX_VAL);
}

void setMotorBackward(int pwm) {
    ledcWriteChannel(PWM_CHANNEL_1, pwm);
    ledcWriteChannel(PWM_CHANNEL_2, PWM_MAX_VAL);
}

// Accepts float duty 0-100%; converts with full resolution, rounds only at final int
static int dutyToPwm(float dutyPercent) {
    dutyPercent = constrain(dutyPercent, 0.0f, 100.0f);
    float frac = 1.0f - (dutyPercent / 100.0f);  // inverted: 0% duty -> full PWM
    return (int)(PWM_MAX_VAL * frac + 0.5f);
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
    float adcMV = ((sum / (float)CURRENT_SAMPLES) / ADC_MAX) * VREF * 1000.0f;
    float sensorMV = adcMV * CURRENT_SENSOR_OUTPUT_DIVIDER;  // 2:1 divider: actual = adc * 2

    float supplyDivider = 0;
    for (int i = 0; i < 4; i++) {
        supplyDivider += analogRead(SUPPLY_SENSOR_PIN);
        delayMicroseconds(50);
    }
    float supplyV = ((supplyDivider / 4.0f) / ADC_MAX) * VREF * DIVIDER_RATIO;
    float zeroMV = (overrideZeroMV >= 0) ? (overrideZeroMV * CURRENT_SENSOR_OUTPUT_DIVIDER) : (supplyV * 1000.0f) / 2.0f;
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
        overrideZeroMV = ((sum / 16.0f) / ADC_MAX) * VREF * 1000.0f;  // Store ADC reading (pre-divider)
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

    if (cmd.startsWith("CURRENT,")) {
        // Support command for current-control mode (controller WIP).
        // Format: CURRENT,<seconds>,<current_A>,<kp>,<ki>,<kd>,<F|B>
        if (g_state != State::IDLE) {
            serialSendFormatted("ERROR,NOT_IDLE,received:%s\n", cmd.c_str());
            return;
        }

        // Parse by commas (similar style to DRILL)
        int c1 = cmd.indexOf(',', 8);  // after duration
        int c2 = cmd.indexOf(',', c1 + 1);  // after current
        int c3 = cmd.indexOf(',', c2 + 1);  // after kp
        int c4 = cmd.indexOf(',', c3 + 1);  // after ki
        int c5 = cmd.indexOf(',', c4 + 1);  // after kd
        int end = cmd.length();

        if (c1 < 0 || c2 < 0 || c3 < 0 || c4 < 0 || c5 < 0) {
            serialSendFormatted("ERROR,BAD_FORMAT,received:%s\n", cmd.c_str());
            return;
        }

        String durStr = cmd.substring(8, c1);
        durStr.trim();
        g_drill_duration_s = durStr.toInt();

        if (g_drill_duration_s < 0 || g_drill_duration_s > DURATION_MAX_CURRENT_SAFE) {
            serialSendFormatted("ERROR,INVALID_DURATION_0_%d,received:%s\n", DURATION_MAX_CURRENT_SAFE, cmd.c_str());
            return;
        }

        String curStr = cmd.substring(c1 + 1, c2);
        curStr.trim();
        g_des_current_A = curStr.toFloat();
        // Allow 0A setpoint for first safety test (motor will not drive)
        if (g_des_current_A < 0.0f) {
            serialSend("ERROR,CURRENT_MUST_BE_GTE_0\n");
            return;
        }

        String kpStr = cmd.substring(c2 + 1, c3);
        String kiStr = cmd.substring(c3 + 1, c4);
        String kdStr = cmd.substring(c4 + 1, c5);
        kpStr.trim(); kiStr.trim(); kdStr.trim();
        c_kp = kpStr.toFloat();
        c_ki = kiStr.toFloat();
        c_kd = kdStr.toFloat();

        String dirStr = cmd.substring(c5 + 1, end);
        dirStr.trim();
        dirStr.toUpperCase();
        g_direction = (dirStr == "B") ? Direction::DIR_BACKWARD : Direction::DIR_FORWARD;

        g_useCurrentControl = true;

        size_t totalSec = PRE_DRILL_SEC + (size_t)g_drill_duration_s + POST_DRILL_SEC;
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
        serialSendFormatted("READY,CURRENT,%u,%.3f,%.3f,%.3f,%.3f,%s\n",
            g_drill_duration_s, g_des_current_A, c_kp, c_ki, c_kd,
            g_direction == Direction::DIR_FORWARD ? "F" : "B");
        return;
    }

    if (cmd.startsWith("DRILL,")) {
        if (g_state != State::IDLE) {
            serialSendFormatted("ERROR,NOT_IDLE,received:%s\n", cmd.c_str());
            return;
        }
        g_useCurrentControl = false;  // explicit: DRILL always runs open-loop PWM mode
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
            g_pwm_duty = pwmStr.toFloat();
            if (g_pwm_duty < 0.0f || g_pwm_duty > (float)PWM_MAX_SAFE) {
                serialSendFormatted("ERROR,PWM_MAX_%d,received:%s\n", PWM_MAX_SAFE, cmd.c_str());
                return;
            }
        } else {
            g_pwm_duty = 0.0f;
        }

        if (g_drill_duration_s < DURATION_MIN_SAFE || g_drill_duration_s > DURATION_MAX_SAFE) {
            serialSendFormatted("ERROR,INVALID_DURATION_%d_%d,received:%s\n", DURATION_MIN_SAFE, DURATION_MAX_SAFE, cmd.c_str());
            return;
        }
        if (g_pwm_duty <= 0.0f) {
            serialSend("ERROR,PWM_MUST_BE_GT_0\n");
            return;
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
        Serial.printf("[STATE] ARMED duration=%u pwm=%.2f dir=%s\n",
            g_drill_duration_s, (double)g_pwm_duty,
            g_direction == Direction::DIR_FORWARD ? "F" : "B");
        serialSendFormatted("READY,%u,%.2f,%s\n", g_drill_duration_s, (double)g_pwm_duty,
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
        g_motorEndUs   = g_motorStartUs + ((uint32_t)g_drill_duration_s * 1000000UL);
        g_drillEndUs   = g_motorEndUs + (POST_DRILL_SEC * 1000000UL);
        g_nextSampleUs = g_drillStartUs;
        g_rawSamples.clear();
        g_state = g_useCurrentControl ? State::CURRENT_CONTROL : State::RUNNING;
        Serial.println(g_useCurrentControl ? "[STATE] CURRENT_CONTROL (1s pre, control, 1s post)" : "[STATE] RUNNING (1s pre, drill, 1s post)");
        serialSend("RUNNING\n");
        return;
    }

    if (cmd == "ABORT") {
        if (g_state != State::IDLE) {
            setMotorIdle();
            g_rawSamples.clear();
            g_processed.clear();
            g_state = State::IDLE;
            g_useCurrentControl = false;
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
        g_processed[i].error_A      = g_rawSamples[i].error_A;
        g_processed[i].cmd_duty_pct = g_rawSamples[i].cmd_duty_pct;
        g_processed[i].cmd_pwm      = g_rawSamples[i].cmd_pwm;
        g_processed[i].dir_sign     = g_rawSamples[i].dir_sign;
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
                int pwm = dutyToPwm((float)g_pwm_duty);
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
                s.error_A      = 0.0f;
                s.cmd_duty_pct = g_pwm_duty;
                s.cmd_pwm      = dutyToPwm(g_pwm_duty);
                s.dir_sign     = (g_direction == Direction::DIR_FORWARD) ? 1 : -1;
                g_rawSamples.push_back(s);
                g_nextSampleUs += SAMPLE_INTERVAL_US;
                if ((int32_t)(nowUs - g_nextSampleUs) > (int32_t)(2 * SAMPLE_INTERVAL_US))
                    g_nextSampleUs = nowUs + SAMPLE_INTERVAL_US;
            }
            break;
        }

        case State::CURRENT_CONTROL: {
            if (nowUs >= g_drillEndUs) {
                setMotorIdle();
                g_state = State::PROCESSING;
                serialSend("DONE\n");
                break;
            }

            pollSerialCommands();

            // Motor idle during pre and post phases; run only during drill phase
            if (nowUs >= g_motorStartUs && nowUs < g_motorEndUs) {
                float current = readCurrentAmps();
                float error = g_des_current_A - current;

                // P-only controller output interpreted as duty percent
                float cmd_duty_pct = c_kp * error;

                // Direction chosen by sign of cmd (reversing mid-run is handled)
                bool forward = (cmd_duty_pct >= 0.0f);
                if (cmd_duty_pct < 0.0f) cmd_duty_pct = -cmd_duty_pct;

                // Hard safety clamp (never exceed 10%)
                if (cmd_duty_pct > PWM_MAX_CURRENT_CONTROL_SAFE) cmd_duty_pct = PWM_MAX_CURRENT_CONTROL_SAFE;
                // 0A setpoint: use error to cancel back current (e.g. back-EMF when pulling out)

                // Convert duty percent to inverted motor PWM (0-1023) and drive with chosen direction
                int pwm = dutyToPwm(cmd_duty_pct);
                if (cmd_duty_pct <= 0.0f) {
                    setMotorIdle();
                } else if (forward) {
                    setMotorForward(pwm);
                } else {
                    setMotorBackward(pwm);
                }
            } else {
                setMotorIdle();
            }

            // read data to report at the end of control period
            if ((int32_t)(nowUs - g_nextSampleUs) >= 0) {
                RawSample s;
                s.timestamp_us = nowUs;
                s.count        = readEncoderCount();
                float current = readCurrentAmps();
                float error = g_des_current_A - current;
                float cmd_duty_pct = c_kp * error;
                int8_t dir_sign = (cmd_duty_pct >= 0.0f) ? 1 : -1;
                if (cmd_duty_pct < 0.0f) cmd_duty_pct = -cmd_duty_pct;
                if (cmd_duty_pct > PWM_MAX_CURRENT_CONTROL_SAFE) cmd_duty_pct = PWM_MAX_CURRENT_CONTROL_SAFE;

                s.current_A    = current;
                s.error_A      = error;
                s.cmd_duty_pct = cmd_duty_pct;
                s.cmd_pwm      = (cmd_duty_pct <= 0.0f) ? 0 : dutyToPwm(cmd_duty_pct);
                s.dir_sign     = dir_sign;
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
                char buf[220];
                // DATA,index,time_ms,position_m,velocity_mps,accel_mps2,current_A,error_A,cmd_duty_pct,cmd_pwm,dir_sign
                snprintf(buf, sizeof(buf), "DATA,%u,%u,%.5f,%.4f,%.3f,%.4f,%.4f,%.2f,%d,%d\n",
                    (unsigned)g_sendIndex, time_ms,
                    s.position_m, s.velocity_mps, s.accel_mps2, s.current_A,
                    s.error_A, s.cmd_duty_pct, s.cmd_pwm, (int)s.dir_sign);
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
