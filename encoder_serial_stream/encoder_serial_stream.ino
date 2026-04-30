/*
 * Real-time encoder stream over USB Serial (ESP32)
 *
 * Encoder read + position math matches working/pwmAndEncoder.ino exactly:
 *   - PCNT quadrature on GPIO A=25, B=33 (same unit config as pwm; only B pin differs from pwm's 26).
 *   - readEncoderCount() = hardware counter + overflow ISR (same as pwm).
 *   - Linear position from stream start: (pcnt - count_at_arm) * METERS_PER_COUNT
 *     (same as pwm processData: (count - g_countAtGo) * METERS_PER_COUNT).
 *   - Do NOT analogRead() on the encoder pins — on ESP32 that muxes ADC onto them and corrupts PCNT.
 *
 * 600 PPR × 4 quadrature = 2400 counts/rev; 4 in spool → METERS_PER_COUNT as in pwm.
 *
 * Commands: PING | STREAM,<s> | STREAM_ADC,<s> | RAW,<s> | RAW_ADC,<s> | STOP
 *
 * STREAM (100 Hz), 7 fields after "DATA," — ends with tag PCNT:
 *   DATA,<t_us>,<pcnt>,<d_pcnt>,<dpos_m>,<pos_m>,<dir>,PCNT
 *
 * STREAM_ADC: same + 12-bit ADC on A/B after each PCNT read (may disturb PCNT on ESP32):
 *   DATA,...,PCNT,<adcA>,<adcB>
 *
 * RAW / RAW_ADC: 6 fields, or 8 fields + trailing tag ADC for RAW_ADC:
 *   RAW,<t_us>,<pcnt>,<d_pcnt>,<dpos_m>,<pos_m>,<dir>
 *   RAW,<t_us>,<pcnt>,<d_pcnt>,<dpos_m>,<pos_m>,<dir>,<adcA>,<adcB>,ADC
 *
 * --- If PCNT stays flat but ADC (old firmware) showed “motion” ---
 * PCNT needs fast 0/3.3 V transitions; the ADC path often shows ramps/noise that never
 * cross the digital Schmitt thresholds. Also: GPIO25 = DAC1 on classic ESP32 — call dacDisable(25).
 * Open-drain encoders need pull-ups (internal INPUT_PULLUP and/or 4.7k–10k to 3.3 V).
 * A and B must be 90° quadrature (not the same net, not in phase). pwmAndEncoder uses B=26;
 * this sketch uses B=33 — if 33 is loaded (motor PCB trace, LED, etc.), try wiring B to 26 instead.
 */

#include "driver/pcnt.h"
#include "esp32-hal-dac.h"

static constexpr int      ENCODER_PIN_A       = 25;
static constexpr int      ENCODER_PIN_B       = 33;
static constexpr int      ENCODER_PPR         = 600;
static constexpr int      QUADRATURE_MULT     = 4;
static constexpr int      COUNTS_PER_REV      = ENCODER_PPR * QUADRATURE_MULT;  // 2400

static constexpr float    SPOOL_DIA_INCHES    = 4.0f;
static constexpr float    SPOOL_CIRCUMF_M     = 3.14159265f * SPOOL_DIA_INCHES * 0.0254f;
static constexpr float    METERS_PER_COUNT    = SPOOL_CIRCUMF_M / (float)COUNTS_PER_REV;

static constexpr uint32_t SAMPLE_HZ           = 100;
static constexpr uint32_t SAMPLE_INTERVAL_US  = 1000000UL / SAMPLE_HZ;

static constexpr pcnt_unit_t PCNT_UNIT        = PCNT_UNIT_0;
static constexpr int16_t    PCNT_H_LIM        = 32767;
static constexpr int16_t    PCNT_L_LIM        = -32768;
static constexpr uint16_t   PCNT_FILTER_VAL   = 100;

static constexpr uint32_t   STREAM_MIN_S      = 1;
static constexpr uint32_t   STREAM_MAX_S      = 600;

enum class RunMode : uint8_t { IDLE, STREAMING, STREAMING_ADC, RAW_TAP, RAW_ADC };

static volatile int32_t     g_overflowAccum = 0;

static RunMode              g_mode = RunMode::IDLE;
static uint32_t             g_runEndUs = 0;
static uint32_t             g_nextSampleUs = 0;
static int32_t              g_prevCount = 0;
static int32_t              g_countAtArm = 0;
static uint32_t             g_sampleIndex = 0;

static String               g_rxBuffer;

static void setupEncoderAdc() {
    analogSetAttenuation(ADC_11db);
    analogReadResolution(12);
}

void IRAM_ATTR pcntOverflowISR(void* arg) {
    uint32_t status = 0;
    pcnt_get_event_status(PCNT_UNIT, &status);
    if (status & PCNT_EVT_H_LIM) g_overflowAccum += PCNT_H_LIM;
    if (status & PCNT_EVT_L_LIM) g_overflowAccum += PCNT_L_LIM;
}

// Same as pwmAndEncoder.ino readEncoderCount()
static int32_t readEncoderCount() {
    portDISABLE_INTERRUPTS();
    int16_t hw = 0;
    pcnt_get_counter_value(PCNT_UNIT, &hw);
    int32_t total = g_overflowAccum + (int32_t)hw;
    portENABLE_INTERRUPTS();
    return total;
}

// Same PCNT unit setup as pwmAndEncoder.ino (dual channel quadrature)
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

static void armRun() {
    g_countAtArm = readEncoderCount();
    g_prevCount  = g_countAtArm;
}

static void processSerialLines() {
    while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\r') continue;
        if (c == '\n') {
            String line = g_rxBuffer;
            g_rxBuffer = "";
            line.trim();
            if (line.length() == 0) continue;

            if (line.equalsIgnoreCase("PING")) {
                Serial.println("PONG");
                continue;
            }

            if (line.equalsIgnoreCase("STOP")) {
                if (g_mode != RunMode::IDLE) {
                    g_mode = RunMode::IDLE;
                    Serial.println("STOPPED");
                }
                continue;
            }

            if (line.startsWith("STREAM,")) {
                if (g_mode != RunMode::IDLE) {
                    Serial.println("ERROR,BUSY");
                    continue;
                }
                uint32_t dur = (uint32_t)line.substring(7).toInt();
                if (dur < STREAM_MIN_S || dur > STREAM_MAX_S) {
                    Serial.printf("ERROR,INVALID_DURATION,%lu\n", (unsigned long)dur);
                    continue;
                }

                uint32_t nowUs = micros();
                g_runEndUs      = nowUs + dur * 1000000UL;
                g_nextSampleUs  = nowUs;
                g_sampleIndex   = 0;
                armRun();

                g_mode = RunMode::STREAMING;
                Serial.printf("READY,%lu,%lu,%ld\n",
                    (unsigned long)dur,
                    (unsigned long)SAMPLE_HZ,
                    (long)g_countAtArm);
                continue;
            }

            if (line.startsWith("STREAM_ADC,")) {
                if (g_mode != RunMode::IDLE) {
                    Serial.println("ERROR,BUSY");
                    continue;
                }
                uint32_t dur = (uint32_t)line.substring(11).toInt();
                if (dur < STREAM_MIN_S || dur > STREAM_MAX_S) {
                    Serial.printf("ERROR,INVALID_DURATION,%lu\n", (unsigned long)dur);
                    continue;
                }

                setupEncoderAdc();
                uint32_t nowUs = micros();
                g_runEndUs      = nowUs + dur * 1000000UL;
                g_nextSampleUs  = nowUs;
                g_sampleIndex   = 0;
                armRun();

                g_mode = RunMode::STREAMING_ADC;
                Serial.printf("READY_ADC,%lu,%lu,%ld\n",
                    (unsigned long)dur,
                    (unsigned long)SAMPLE_HZ,
                    (long)g_countAtArm);
                continue;
            }

            // RAW_ADC before RAW — otherwise "RAW_ADC,10" matches "RAW,".
            if (line.startsWith("RAW_ADC,")) {
                if (g_mode != RunMode::IDLE) {
                    Serial.println("ERROR,BUSY");
                    continue;
                }
                uint32_t dur = (uint32_t)line.substring(8).toInt();
                if (dur < STREAM_MIN_S || dur > STREAM_MAX_S) {
                    Serial.printf("ERROR,INVALID_DURATION,%lu\n", (unsigned long)dur);
                    continue;
                }

                setupEncoderAdc();
                uint32_t nowUs = micros();
                g_runEndUs      = nowUs + dur * 1000000UL;
                g_nextSampleUs  = nowUs;
                g_sampleIndex   = 0;
                armRun();

                g_mode = RunMode::RAW_ADC;
                Serial.printf("READY_RAW_ADC,%lu,%lu,%ld\n",
                    (unsigned long)dur,
                    (unsigned long)SAMPLE_HZ,
                    (long)g_countAtArm);
                continue;
            }

            if (line.startsWith("RAW,")) {
                if (g_mode != RunMode::IDLE) {
                    Serial.println("ERROR,BUSY");
                    continue;
                }
                uint32_t dur = (uint32_t)line.substring(4).toInt();
                if (dur < STREAM_MIN_S || dur > STREAM_MAX_S) {
                    Serial.printf("ERROR,INVALID_DURATION,%lu\n", (unsigned long)dur);
                    continue;
                }

                uint32_t nowUs = micros();
                g_runEndUs      = nowUs + dur * 1000000UL;
                g_nextSampleUs  = nowUs;
                g_sampleIndex   = 0;
                armRun();

                g_mode = RunMode::RAW_TAP;
                Serial.printf("READY_RAW,%lu,%lu,%ld\n",
                    (unsigned long)dur,
                    (unsigned long)SAMPLE_HZ,
                    (long)g_countAtArm);
                continue;
            }

            Serial.printf("ERROR,UNKNOWN_CMD,%s\n", line.c_str());
        } else {
            g_rxBuffer += c;
            if (g_rxBuffer.length() > 128) g_rxBuffer = "";
        }
    }
}

void setup() {
    Serial.begin(115200);
    // Classic ESP32: free GPIO25 from DAC so digital / PCNT sees the encoder ([arduino-esp32 #7980]).
    dacDisable(25);
    pinMode(ENCODER_PIN_A, INPUT_PULLUP);
    pinMode(ENCODER_PIN_B, INPUT_PULLUP);
    setupPCNT();
    Serial.println("[READY] encoder_serial_stream — STREAM | STREAM_ADC | RAW | RAW_ADC | PING");
}

void loop() {
    processSerialLines();

    if (g_mode == RunMode::IDLE) {
        delay(1);
        return;
    }

    uint32_t nowUs = micros();
    if ((int32_t)(nowUs - g_runEndUs) >= 0) {
        g_mode = RunMode::IDLE;
        Serial.printf("END,%lu\n", (unsigned long)g_sampleIndex);
        return;
    }

    if ((int32_t)(nowUs - g_nextSampleUs) < 0) {
        return;
    }

    int32_t pcntVal = readEncoderCount();
    int32_t dPcnt   = pcntVal - g_prevCount;
    g_prevCount     = pcntVal;
    float dposM     = (float)dPcnt * METERS_PER_COUNT;
    float posM      = (float)(pcntVal - g_countAtArm) * METERS_PER_COUNT;
    int dir         = (dPcnt > 0) ? 1 : ((dPcnt < 0) ? -1 : 0);

    int adcA = 0;
    int adcB = 0;
    const bool withAdc = (g_mode == RunMode::STREAMING_ADC || g_mode == RunMode::RAW_ADC);
    if (withAdc) {
        adcA = analogRead(ENCODER_PIN_A);
        adcB = analogRead(ENCODER_PIN_B);
    }

    if (g_mode == RunMode::STREAMING) {
        Serial.printf("DATA,%lu,%ld,%ld,%.8f,%.8f,%d,PCNT\n",
            (unsigned long)nowUs,
            (long)pcntVal,
            (long)dPcnt,
            dposM,
            posM,
            dir);
    } else if (g_mode == RunMode::STREAMING_ADC) {
        Serial.printf("DATA,%lu,%ld,%ld,%.8f,%.8f,%d,PCNT,%d,%d\n",
            (unsigned long)nowUs,
            (long)pcntVal,
            (long)dPcnt,
            dposM,
            posM,
            dir,
            adcA,
            adcB);
    } else if (g_mode == RunMode::RAW_TAP) {
        Serial.printf("RAW,%lu,%ld,%ld,%.8f,%.8f,%d\n",
            (unsigned long)nowUs,
            (long)pcntVal,
            (long)dPcnt,
            dposM,
            posM,
            dir);
    } else if (g_mode == RunMode::RAW_ADC) {
        Serial.printf("RAW,%lu,%ld,%ld,%.8f,%.8f,%d,%d,%d,ADC\n",
            (unsigned long)nowUs,
            (long)pcntVal,
            (long)dPcnt,
            dposM,
            posM,
            dir,
            adcA,
            adcB);
    }

    g_sampleIndex++;
    g_nextSampleUs += SAMPLE_INTERVAL_US;
    if ((int32_t)(nowUs - g_nextSampleUs) > (int32_t)(2 * SAMPLE_INTERVAL_US))
        g_nextSampleUs = nowUs + SAMPLE_INTERVAL_US;
}
