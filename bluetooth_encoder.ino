/*
 * QuickBurst Rotary Encoder + Bluetooth + Motor Control Arduino Code
 * DUAL-CORE ARCHITECTURE VERSION
 * 
 * Hardware: ESP32 + Incremental Optical Encoder (600 PPR, quadrature) + L293D H-bridge
 * Communication: BLE (Service UUID: FFE0, Characteristic UUID: FFE1)
 * 
 * Architecture:
 *   Core 0 (PRO_CPU): Bluetooth handling (BLE server, command parsing, data transmission)
 *   Core 1 (APP_CPU): Motor control, encoder reading, data sampling
 * 
 * Inter-Core Communication:
 *   - Command Queue: Core 0 -> Core 1 (motor commands)
 *   - Data Queue: Core 1 -> Core 0 (encoder samples for BLE transmission)
 * 
 * Motor Control:
 *   - PWM on GPIO25 (EN pin) via LEDC, 20 kHz, 10-bit resolution
 *   - Direction on GPIO26 (IN1) and GPIO27 (IN2)
 *   - Closed-loop control using encoder feedback
 *   - Three command modes: liveMode, constantForce, percentageBaseline
 * 
 * Encoder Reading:
 *   - Uses EXACT code from encoderread.ino
 *   - 10ms sampling interval (matches encoderread.ino)
 *   - PCNT hardware quadrature decoding
 * 
 * Required Libraries:
 *   - ESP32 Arduino Core (built-in PCNT and LEDC support)
 *   - BLE libraries (BLEDevice, BLEServer, BLEUtils, BLE2902)
 *   - FreeRTOS (built-in)
 * 
 * Wiring:
 *   Encoder A  -> GPIO 12 (ENCODER_PIN_A)
 *   Encoder B  -> GPIO 13 (ENCODER_PIN_B)
 *   Motor EN   -> GPIO 25 (MOTOR_EN_PIN)  [PWM]
 *   Motor IN1  -> GPIO 26 (MOTOR_IN1_PIN)
 *   Motor IN2  -> GPIO 27 (MOTOR_IN2_PIN)
 *   Encoder VCC -> 5V
 *   Encoder GND -> GND
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/pcnt.h"
#include "driver/ledc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

// ============== BLE CONFIGURATION ==============

#define SERVICE_UUID        "FFE0"
#define CHARACTERISTIC_UUID "FFE1"
#define DEVICE_NAME "Quikburst"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// ============== HARDWARE CONFIGURATION ==============

const int ENCODER_PIN_A = 12;  // Quadrature channel A
const int ENCODER_PIN_B = 13;  // Quadrature channel B

// Motor pins (L293D H-bridge)
const int MOTOR_EN_PIN = 25;   // PWM enable pin (EN1,2)
const int MOTOR_IN1_PIN = 26;  // Direction control IN1
const int MOTOR_IN2_PIN = 27;  // Direction control IN2

// PWM configuration
const int PWM_FREQ_HZ = 20000;      // 20 kHz PWM frequency
const int PWM_RESOLUTION_BITS = 10; // 10-bit resolution (0-1023)
const int PWM_MAX_DUTY = (1 << PWM_RESOLUTION_BITS) - 1; // 1023

// LEDC channel for PWM
const ledc_channel_t PWM_CHANNEL = LEDC_CHANNEL_0;
const ledc_timer_t PWM_TIMER = LEDC_TIMER_0;

// ============== ENCODER SPECIFICATIONS (from encoderread.ino) ==============

const int COUNTS_PER_REV = 2400;             // 600 PPR * 4 (quadrature)
const float SPOOL_RADIUS_M = 0.003;          // 3mm radius (matches encoderread.ino)
const float COUNTS_TO_DISTANCE_M = (2.0 * PI * SPOOL_RADIUS_M) / COUNTS_PER_REV; // meters per count

// ============== DATA SAMPLING (EXACT from encoderread.ino) ==============

const unsigned long SAMPLE_INTERVAL_MS = 10;    // Sampling period (ms) - EXACT from encoderread.ino
const unsigned long TRIAL_DURATION_MS = 5000;   // Total trial duration (ms) - EXACT from encoderread.ino
const int MAX_SAMPLES = (TRIAL_DURATION_MS / SAMPLE_INTERVAL_MS) + 10;  // Buffer with margin - EXACT from encoderread.ino

// ============== PCNT CONFIGURATION (from encoderread.ino) ==============

const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
const int16_t PCNT_HIGH_LIMIT = 32767;
const int16_t PCNT_LOW_LIMIT  = -32768;

// Overflow tracking (PCNT is 16-bit, we need 32-bit range) - EXACT from encoderread.ino
volatile int32_t overflowCount = 0;a     

// ============== INTER-CORE COMMUNICATION ==============

// Command type enum (must be defined outside struct for proper scoping)
enum CommandType {
    CMD_NONE,
    CMD_LIVE_MODE,
    CMD_CONSTANT_FORCE,
    CMD_PERCENTAGE_BASELINE,
    CMD_PERCENTAGE_EXECUTION,
    CMD_STOP
};

// Command structure for Core 0 -> Core 1
typedef struct {
    CommandType type;
    union {
        struct {
            float dutyPercent;
            int direction;
        } liveMode;
        struct {
            uint32_t id;
            float forcePercent;
            int direction;
            uint32_t durationMs;
            float targetDistance;
        } constantForce;
        struct {
            uint32_t id;
            int direction;
            uint32_t durationMs;
            float targetDistance;
            bool isBaselineCapture;
            float targetPercent;
            float forcePercent;
        } percentage;
    } data;
} MotorCommand;

// Data sample structure for Core 1 -> Core 0
typedef struct {
    uint32_t id;
    unsigned long timeMs;
    int32_t counts;
    bool isComplete;  // true when sampling is done
} EncoderSample;

// FreeRTOS queues
QueueHandle_t commandQueue = NULL;  // Core 0 -> Core 1 (commands)
QueueHandle_t dataQueue = NULL;    // Core 1 -> Core 0 (samples)

// ============== STATE MACHINE (Core 1) ==============

enum DrillState {
    STATE_IDLE,
    STATE_LIVE_MODE,
    STATE_CONSTANT_FORCE_RUNNING,
    STATE_PERCENTAGE_BASELINE_CAPTURE,
    STATE_PERCENTAGE_EXECUTION
};

DrillState currentState = STATE_IDLE;

// Execution tracking (Core 1)
unsigned long drillStartTime = 0;
int32_t drillStartPosition = 0;
float baselineSpeed = 0.0f;
int baselineSamples = 0;
unsigned long baselineCaptureStart = 0;
const unsigned long BASELINE_CAPTURE_DURATION_MS = 2000; // 2 seconds
const int MIN_BASELINE_SAMPLES = 10;

// Current command data (Core 1)
MotorCommand currentCmd;

// ============== DATA SAMPLING (Core 1) - LIVE STREAMING ==============

bool isSampling = false;
unsigned long trialStartTime = 0;
unsigned long lastSampleTime = 0;
int32_t firstCounts = 0; // First sample counts for relative calculation

// ============== BLE DATA TRANSMISSION (Core 0) - LIVE STREAMING ==============

bool liveStreamingActive = false;
uint32_t streamingDataId = 0;
int samplesReceivedSoFar = 0;
int32_t firstCountsInStream = 0; // First counts for relative calculation
unsigned long prevTimeMs = 0; // Previous sample time for velocity/acceleration calculation
int32_t prevCounts = 0; // Previous counts for velocity/acceleration calculation
float prevVelocity = 0.0f; // Previous velocity for acceleration calculation

// ============== PCNT OVERFLOW ISR (EXACT from encoderread.ino) ==============

void IRAM_ATTR pcntOverflowISR(void *arg) {
    uint32_t status = 0;
    pcnt_get_event_status(PCNT_UNIT, &status);
    
    if (status & PCNT_EVT_H_LIM) {
        overflowCount += PCNT_HIGH_LIMIT;
    }
    if (status & PCNT_EVT_L_LIM) {
        overflowCount += PCNT_LOW_LIMIT;
    }
}

// ============== PCNT SETUP (EXACT from encoderread.ino) ==============

void setupPCNT() {
    // Configure PCNT unit for quadrature decoding
    pcnt_config_t config = {
        .pulse_gpio_num = ENCODER_PIN_A,
        .ctrl_gpio_num  = ENCODER_PIN_B,
        .lctrl_mode     = PCNT_MODE_REVERSE,  // Reverse on B low
        .hctrl_mode     = PCNT_MODE_KEEP,     // Keep on B high
        .pos_mode       = PCNT_COUNT_INC,     // Count up on A rising
        .neg_mode       = PCNT_COUNT_DEC,     // Count down on A falling
        .counter_h_lim  = PCNT_HIGH_LIMIT,
        .counter_l_lim  = PCNT_LOW_LIMIT,
        .unit           = PCNT_UNIT,
        .channel        = PCNT_CHANNEL_0
    };
    pcnt_unit_config(&config);
    
    // Configure channel 1 for full quadrature (x4 decoding)
    pcnt_config_t config2 = {
        .pulse_gpio_num = ENCODER_PIN_B,
        .ctrl_gpio_num  = ENCODER_PIN_A,
        .lctrl_mode     = PCNT_MODE_KEEP,
        .hctrl_mode     = PCNT_MODE_REVERSE,
        .pos_mode       = PCNT_COUNT_INC,
        .neg_mode       = PCNT_COUNT_DEC,
        .counter_h_lim  = PCNT_HIGH_LIMIT,
        .counter_l_lim  = PCNT_LOW_LIMIT,
        .unit           = PCNT_UNIT,
        .channel        = PCNT_CHANNEL_1
    };
    pcnt_unit_config(&config2);
    
    // Enable glitch filter (rejects pulses < 100 clock cycles)
    pcnt_set_filter_value(PCNT_UNIT, 100);
    pcnt_filter_enable(PCNT_UNIT);
    
    // Setup overflow interrupts
    pcnt_event_enable(PCNT_UNIT, PCNT_EVT_H_LIM);
    pcnt_event_enable(PCNT_UNIT, PCNT_EVT_L_LIM);
    pcnt_isr_service_install(0);
    pcnt_isr_handler_add(PCNT_UNIT, pcntOverflowISR, NULL);
    
    // Initialize counter
    pcnt_counter_pause(PCNT_UNIT);
    pcnt_counter_clear(PCNT_UNIT);
    pcnt_counter_resume(PCNT_UNIT);
}

// ============== ENCODER READ (EXACT from encoderread.ino) ==============

int32_t readEncoderCount() {
    int16_t count16 = 0;
    pcnt_get_counter_value(PCNT_UNIT, &count16);
    return overflowCount + count16;
}

void resetEncoder() {
    pcnt_counter_pause(PCNT_UNIT);
    pcnt_counter_clear(PCNT_UNIT);
    overflowCount = 0;
    pcnt_counter_resume(PCNT_UNIT);
}

// ============== MOTOR DRIVER CLASS ==============

class MotorDriver {
public:
    MotorDriver() : pwmDuty(0), direction(1), initialized(false) {}
    
    void begin() {
        Serial.println("[CORE1] Initializing MotorDriver...");
        
        // Configure GPIO pins for direction control
        pinMode(MOTOR_IN1_PIN, OUTPUT);
        pinMode(MOTOR_IN2_PIN, OUTPUT);
        
        // Set direction pins LOW initially (coast)
        digitalWrite(MOTOR_IN1_PIN, LOW);
        digitalWrite(MOTOR_IN2_PIN, LOW);
        
        pinMode(MOTOR_EN_PIN, OUTPUT);
        digitalWrite(MOTOR_EN_PIN, LOW);
        
        // Configure LEDC timer
        ledc_timer_config_t timerConf = {
            .speed_mode = LEDC_LOW_SPEED_MODE,
            .duty_resolution = (ledc_timer_bit_t)PWM_RESOLUTION_BITS,
            .timer_num = PWM_TIMER,
            .freq_hz = PWM_FREQ_HZ,
            .clk_cfg = LEDC_AUTO_CLK
        };
        esp_err_t timerErr = ledc_timer_config(&timerConf);
        Serial.print("[CORE1] LEDC timer config: ");
        Serial.println(timerErr == ESP_OK ? "OK" : "FAILED");
        
        // Configure LEDC channel
        ledc_channel_config_t channelConf = {};
        channelConf.gpio_num = MOTOR_EN_PIN;
        channelConf.speed_mode = LEDC_LOW_SPEED_MODE;
        channelConf.channel = PWM_CHANNEL;
        channelConf.intr_type = LEDC_INTR_DISABLE;
        channelConf.timer_sel = PWM_TIMER;
        channelConf.duty = 0;
        channelConf.hpoint = 0;
        esp_err_t channelErr = ledc_channel_config(&channelConf);
        Serial.print("[CORE1] LEDC channel config: ");
        Serial.println(channelErr == ESP_OK ? "OK" : "FAILED");
        
        // Set initial duty to 0
        ledc_set_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL, 0);
        ledc_update_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL);
        
        pwmDuty = 0.0f;
        initialized = true;
        Serial.println("[CORE1] MotorDriver initialized successfully");
    }
    
    void setDirection(int dir) {
        direction = (dir > 0) ? 1 : -1;
        
        if (direction > 0) {
            digitalWrite(MOTOR_IN1_PIN, HIGH);
            digitalWrite(MOTOR_IN2_PIN, LOW);
        } else {
            digitalWrite(MOTOR_IN1_PIN, LOW);
            digitalWrite(MOTOR_IN2_PIN, HIGH);
        }
    }
    
    void setDuty01(float duty) {
        if (duty < 0.0f) duty = 0.0f;
        if (duty > 1.0f) duty = 1.0f;
        
        pwmDuty = duty;
        uint32_t dutyValue = (uint32_t)(duty * PWM_MAX_DUTY);
        
        ledc_set_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL, dutyValue);
        ledc_update_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL);
    }
    
    void stop() {
        setDuty01(0.0f);
    }
    
    float getDuty() const { return pwmDuty; }
    bool isInitialized() const { return initialized; }
    
private:
    float pwmDuty;
    int direction;
    bool initialized;
};

MotorDriver motorDriver;

// ============== TRIAL CONTROL (EXACT from encoderread.ino) ==============

void startTrial() {
    // Reset state for live streaming
    resetEncoder();
    trialStartTime = millis();
    drillStartTime = trialStartTime;
    drillStartPosition = readEncoderCount(); // Store start position
    firstCounts = drillStartPosition; // Store first counts for relative calculation
    isSampling = true;
    lastSampleTime = 0;
    
    Serial.print("[CORE1] TRIAL_STARTED at ");
    Serial.println(trialStartTime);
}

// ============== CORE 1 TASK: Motor Control & Encoder Sampling ==============

void motorControlTask(void *pvParameters) {
    Serial.print("[CORE1] Motor control task started on core: ");
    Serial.println(xPortGetCoreID());
    
    // Initialize motor driver
    motorDriver.begin();
    
    // Initialize encoder
    setupPCNT();
    
    Serial.println("[CORE1] Initialization complete. Waiting for commands...");
    
    MotorCommand cmd;
    unsigned long lastControlTime = 0;
    const unsigned long CONTROL_INTERVAL_MS = 10;  // Control loop period
    
    while (1) {
        // Check for commands from Core 0
        if (xQueueReceive(commandQueue, &cmd, 0) == pdTRUE) {
            Serial.print("[CORE1] Received command type: ");
            Serial.println(cmd.type);
            
            switch (cmd.type) {
                case CMD_LIVE_MODE:
                    // If already in live mode, just update duty cycle (don't restart trial)
                    if (currentState == STATE_LIVE_MODE) {
                        motorDriver.setDirection(cmd.data.liveMode.direction);
                        motorDriver.setDuty01(cmd.data.liveMode.dutyPercent / 100.0f);
                        currentCmd = cmd; // Update current command
                    } else {
                        // Starting new live mode session
                        motorDriver.setDirection(cmd.data.liveMode.direction);
                        delay(50);
                        motorDriver.setDuty01(cmd.data.liveMode.dutyPercent / 100.0f);
                        startTrial();
                        currentState = STATE_LIVE_MODE;
                        currentCmd = cmd;
                    }
                    break;
                    
                case CMD_CONSTANT_FORCE:
                    motorDriver.setDirection(cmd.data.constantForce.direction);
                    delay(50);
                    motorDriver.setDuty01(cmd.data.constantForce.forcePercent / 100.0f);
                    startTrial();
                    currentState = STATE_CONSTANT_FORCE_RUNNING;
                    currentCmd = cmd;
                    break;
                    
                case CMD_PERCENTAGE_BASELINE:
                    motorDriver.setDirection(cmd.data.percentage.direction);
                    delay(50);
                    motorDriver.stop(); // No motor during baseline capture
                    startTrial();
                    baselineCaptureStart = millis();
                    baselineSpeed = 0.0f;
                    baselineSamples = 0;
                    currentState = STATE_PERCENTAGE_BASELINE_CAPTURE;
                    currentCmd = cmd;
                    break;
                    
                case CMD_PERCENTAGE_EXECUTION:
                    motorDriver.setDirection(cmd.data.percentage.direction);
                    delay(50);
                    motorDriver.setDuty01(cmd.data.percentage.forcePercent / 100.0f);
                    startTrial();
                    currentState = STATE_PERCENTAGE_EXECUTION;
                    currentCmd = cmd;
                    break;
                    
                case CMD_STOP:
                    motorDriver.stop();
                    isSampling = false;
                    currentState = STATE_IDLE;
                    // Send completion marker
                    EncoderSample sample;
                    sample.id = 0;
                    sample.isComplete = true;
                    xQueueSend(dataQueue, &sample, portMAX_DELAY);
                    break;
                    
                default:
                    break;
            }
        }
        
        // Control loop and state machine
        unsigned long nowMs = millis();
        if (nowMs - lastControlTime >= CONTROL_INTERVAL_MS) {
            lastControlTime = nowMs;
            
            switch (currentState) {
                case STATE_IDLE:
                    // Do nothing
                    break;
                    
                case STATE_LIVE_MODE:
                case STATE_CONSTANT_FORCE_RUNNING:
                case STATE_PERCENTAGE_BASELINE_CAPTURE:
                case STATE_PERCENTAGE_EXECUTION:
                    // Sample encoder data at fixed intervals and send LIVE
                    if (isSampling && (nowMs - lastSampleTime >= SAMPLE_INTERVAL_MS)) {
                        lastSampleTime = nowMs;
                        
                        // Read encoder and calculate relative time
                        int32_t currentCounts = readEncoderCount();
                        unsigned long relativeTimeMs = nowMs - trialStartTime;
                        
                        // Send sample to Core 0 via queue IMMEDIATELY (live streaming)
                        EncoderSample sample;
                        sample.id = (currentState == STATE_LIVE_MODE) ? (uint32_t)millis() : 
                                   (currentState == STATE_CONSTANT_FORCE_RUNNING) ? currentCmd.data.constantForce.id :
                                   currentCmd.data.percentage.id;
                        sample.timeMs = relativeTimeMs;
                        sample.counts = currentCounts;
                        sample.isComplete = false;
                        
                        if (xQueueSend(dataQueue, &sample, 0) != pdTRUE) {
                            Serial.println("[CORE1] WARNING: Data queue full, sample dropped!");
                        }
                        
                        // Check completion conditions
                        unsigned long elapsedMs = nowMs - drillStartTime;
                        bool timeComplete = false;
                        bool distanceComplete = false;
                        
                        if (currentState == STATE_CONSTANT_FORCE_RUNNING) {
                            int32_t currentPos = readEncoderCount();
                            int32_t positionDelta = currentPos - drillStartPosition;
                            float distanceM = positionDelta * COUNTS_TO_DISTANCE_M;
                            timeComplete = (currentCmd.data.constantForce.durationMs > 0 && 
                                          elapsedMs >= currentCmd.data.constantForce.durationMs);
                            distanceComplete = (currentCmd.data.constantForce.targetDistance > 0 && 
                                               distanceM >= currentCmd.data.constantForce.targetDistance);
                        } else if (currentState == STATE_PERCENTAGE_BASELINE_CAPTURE) {
                            elapsedMs = nowMs - baselineCaptureStart;
                            int32_t currentPos = readEncoderCount();
                            int32_t positionDelta = currentPos - drillStartPosition;
                            float distanceM = positionDelta * COUNTS_TO_DISTANCE_M;
                            timeComplete = (currentCmd.data.percentage.durationMs > 0 && 
                                          elapsedMs >= currentCmd.data.percentage.durationMs);
                            distanceComplete = (currentCmd.data.percentage.targetDistance > 0 && 
                                               distanceM >= currentCmd.data.percentage.targetDistance);
                            
                            // Calculate baseline speed from recent samples (simplified - using current vs start)
                            // Note: For accurate baseline, we'd need to track recent velocity samples
                            // This is a simplified version
                            if (elapsedMs > 100) { // After 100ms, start calculating baseline
                                float dtSec = elapsedMs / 1000.0f;
                                float speedMps = abs(distanceM / dtSec);
                                
                                if (speedMps > 0.1f) {
                                    baselineSpeed = (baselineSpeed * baselineSamples + speedMps) / (baselineSamples + 1);
                                    baselineSamples++;
                                }
                            }
                            
                            if ((timeComplete || distanceComplete) && baselineSamples >= MIN_BASELINE_SAMPLES) {
                                motorDriver.stop();
                                isSampling = false;
                                currentState = STATE_IDLE;
                                // Send completion
                                EncoderSample completeSample;
                                completeSample.id = currentCmd.data.percentage.id;
                                completeSample.isComplete = true;
                                xQueueSend(dataQueue, &completeSample, portMAX_DELAY);
                            } else if (elapsedMs >= BASELINE_CAPTURE_DURATION_MS && baselineSamples < MIN_BASELINE_SAMPLES) {
                                motorDriver.stop();
                                isSampling = false;
                                currentState = STATE_IDLE;
                                EncoderSample completeSample;
                                completeSample.id = currentCmd.data.percentage.id;
                                completeSample.isComplete = true;
                                xQueueSend(dataQueue, &completeSample, portMAX_DELAY);
                            }
                        } else if (currentState == STATE_PERCENTAGE_EXECUTION) {
                            int32_t currentPos = readEncoderCount();
                            int32_t positionDelta = currentPos - drillStartPosition;
                            float distanceM = positionDelta * COUNTS_TO_DISTANCE_M;
                            timeComplete = (currentCmd.data.percentage.durationMs > 0 && 
                                          elapsedMs >= currentCmd.data.percentage.durationMs);
                            distanceComplete = (currentCmd.data.percentage.targetDistance > 0 && 
                                               distanceM >= currentCmd.data.percentage.targetDistance);
                        }
                        
                        if (timeComplete || distanceComplete) {
                            motorDriver.stop();
                            isSampling = false;
                            
                            // Send completion with correct ID before changing state
                            EncoderSample completeSample;
                            if (currentState == STATE_CONSTANT_FORCE_RUNNING) {
                                completeSample.id = currentCmd.data.constantForce.id;
                            } else if (currentState == STATE_PERCENTAGE_EXECUTION || 
                                      currentState == STATE_PERCENTAGE_BASELINE_CAPTURE) {
                                completeSample.id = currentCmd.data.percentage.id;
                            } else {
                                completeSample.id = 0;
                            }
                            completeSample.isComplete = true;
                            xQueueSend(dataQueue, &completeSample, portMAX_DELAY);
                            
                            currentState = STATE_IDLE;
                        }
                    }
                    break;
            }
        }
        
        // Small delay to prevent CPU spinning
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

// ============== JSON PARSING & GENERATION ==============

String extractJSONValue(String json, String key) {
    int keyPos = json.indexOf("\"" + key + "\"");
    if (keyPos == -1) return "";
    
    int colonPos = json.indexOf(':', keyPos);
    if (colonPos == -1) return "";
    
    int startPos = colonPos + 1;
    while (startPos < json.length() && (json[startPos] == ' ' || json[startPos] == '\t')) {
        startPos++;
    }
    
    int endPos = startPos;
    if (json[startPos] == '"') {
        startPos++;
        endPos = json.indexOf('"', startPos);
    } else {
        while (endPos < json.length() && 
               (json[endPos] == '-' || json[endPos] == '.' || 
                (json[endPos] >= '0' && json[endPos] <= '9'))) {
            endPos++;
        }
    }
    
    if (endPos > startPos && endPos <= json.length()) {
        return json.substring(startPos, endPos);
    }
    return "";
}

void sendBLEMessage(String message) {
    if (deviceConnected && pCharacteristic != NULL) {
        const int MAX_BLE_SIZE = 500;
        
        if (!message.endsWith("\n")) {
            message += "\n";
        }
        
        if (message.length() <= MAX_BLE_SIZE) {
            pCharacteristic->setValue(message.c_str());
            pCharacteristic->notify();
            Serial.print("[BLE_TX] [");
            Serial.print(millis());
            Serial.print("ms] [");
            Serial.print(message.length());
            Serial.print(" bytes] ");
            if (message.length() < 100) {
                Serial.println(message);
            } else {
                Serial.print(message.substring(0, 50));
                Serial.println("...");
            }
        }
    }
}

// ============== BLE CALLBACKS ==============

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.print("[CORE0] [");
        Serial.print(millis());
        Serial.println("ms] Device CONNECTED");
        
        BLEDevice::setMTU(512);
        
        String readyMsg = "{\"type\":\"connectionStatus\",\"status\":\"ready\"}\n";
        sendBLEMessage(readyMsg);
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        Serial.print("[CORE0] [");
        Serial.print(millis());
        Serial.println("ms] Device DISCONNECTED");
    }
};

class MyCharacteristicCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pCharacteristic) {
        String value = pCharacteristic->getValue();
        
        if (value.length() > 0) {
            value.trim();
            
            if (value.startsWith("{")) {
                String type = extractJSONValue(value, "type");
                
                MotorCommand cmd;
                cmd.type = CMD_NONE;
                
                if (type == "liveMode") {
                    String dutyStr = extractJSONValue(value, "dutyPercent");
                    String dirStr = extractJSONValue(value, "direction");
                    if (dutyStr.length() > 0 && dirStr.length() > 0) {
                        cmd.type = CMD_LIVE_MODE;
                        cmd.data.liveMode.dutyPercent = constrain(dutyStr.toFloat(), 0.0f, 100.0f);
                        cmd.data.liveMode.direction = (dirStr.toInt() > 0) ? 1 : -1;
                    }
                }
                else if (type == "constantForce") {
                    String idStr = extractJSONValue(value, "id");
                    String forceStr = extractJSONValue(value, "forcePercent");
                    String dirStr = extractJSONValue(value, "direction");
                    String durationStr = extractJSONValue(value, "durationMs");
                    String distanceStr = extractJSONValue(value, "targetDistance");
                    
                    if (idStr.length() > 0 && forceStr.length() > 0 && dirStr.length() > 0) {
                        cmd.type = CMD_CONSTANT_FORCE;
                        cmd.data.constantForce.id = idStr.toInt();
                        cmd.data.constantForce.forcePercent = constrain(forceStr.toFloat(), 0.0f, 100.0f);
                        cmd.data.constantForce.direction = (dirStr.toInt() > 0) ? 1 : -1;
                        cmd.data.constantForce.durationMs = (durationStr.length() > 0 && durationStr != "null") ? durationStr.toInt() : 0;
                        cmd.data.constantForce.targetDistance = (distanceStr.length() > 0 && distanceStr != "null") ? distanceStr.toFloat() : 0.0f;
                    }
                }
                else if (type == "percentageBaseline") {
                    String idStr = extractJSONValue(value, "id");
                    String dirStr = extractJSONValue(value, "direction");
                    String durationStr = extractJSONValue(value, "durationMs");
                    String distanceStr = extractJSONValue(value, "targetDistance");
                    
                    if (idStr.length() > 0 && dirStr.length() > 0) {
                        cmd.type = CMD_PERCENTAGE_BASELINE;
                        cmd.data.percentage.id = idStr.toInt();
                        cmd.data.percentage.direction = (dirStr.toInt() > 0) ? 1 : -1;
                        cmd.data.percentage.durationMs = (durationStr.length() > 0 && durationStr != "null") ? durationStr.toInt() : 0;
                        cmd.data.percentage.targetDistance = (distanceStr.length() > 0 && distanceStr != "null") ? distanceStr.toFloat() : 0.0f;
                        cmd.data.percentage.isBaselineCapture = true;
                    }
                }
                else if (type == "percentageExecution") {
                    String idStr = extractJSONValue(value, "id");
                    String percentStr = extractJSONValue(value, "targetPercent");
                    String forceStr = extractJSONValue(value, "forcePercent");
                    String dirStr = extractJSONValue(value, "direction");
                    
                    if (idStr.length() > 0 && percentStr.length() > 0 && forceStr.length() > 0 && dirStr.length() > 0) {
                        cmd.type = CMD_PERCENTAGE_EXECUTION;
                        cmd.data.percentage.id = idStr.toInt();
                        cmd.data.percentage.targetPercent = percentStr.toFloat();
                        cmd.data.percentage.forcePercent = constrain(forceStr.toFloat(), 0.0f, 100.0f);
                        cmd.data.percentage.direction = (dirStr.toInt() > 0) ? 1 : -1;
                        cmd.data.percentage.isBaselineCapture = false;
                    }
                }
                else if (type == "stop") {
                    cmd.type = CMD_STOP;
                }
                
                // Send command to Core 1
                if (cmd.type != CMD_NONE) {
                    if (xQueueSend(commandQueue, &cmd, portMAX_DELAY) == pdTRUE) {
                        Serial.print("[CORE0] Command sent to Core 1: ");
                        Serial.println(cmd.type);
                    }
                    
                    // Send ACK for certain commands
                    if (cmd.type == CMD_CONSTANT_FORCE) {
                        sendBLEMessage("{\"type\":\"ack\",\"id\":" + String(cmd.data.constantForce.id) + ",\"status\":\"started\"}");
                    } else if (cmd.type == CMD_PERCENTAGE_BASELINE) {
                        sendBLEMessage("{\"type\":\"ack\",\"id\":" + String(cmd.data.percentage.id) + ",\"status\":\"baselineStarted\"}");
                    } else if (cmd.type == CMD_PERCENTAGE_EXECUTION) {
                        sendBLEMessage("{\"type\":\"ack\",\"id\":" + String(cmd.data.percentage.id) + ",\"status\":\"executionStarted\"}");
                    } else if (cmd.type == CMD_STOP) {
                        sendBLEMessage("{\"type\":\"ack\",\"status\":\"stopped\"}");
                    }
                }
            }
        }
    }
};

// ============== CORE 0 TASK: Bluetooth Handling ==============

void bluetoothTask(void *pvParameters) {
    Serial.print("[CORE0] Bluetooth task started on core: ");
    Serial.println(xPortGetCoreID());
    
    // Initialize BLE device
    BLEDevice::init(DEVICE_NAME);
    
    // Create BLE Server
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    
    // Create BLE Service
    BLEService* pService = pServer->createService(BLEUUID(SERVICE_UUID));
    
    // Create BLE Characteristic
    pCharacteristic = pService->createCharacteristic(
        BLEUUID(CHARACTERISTIC_UUID),
        BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY |
        BLECharacteristic::PROPERTY_WRITE
    );
    
    // Add descriptor for notifications
    pCharacteristic->addDescriptor(new BLE2902());
    
    // Set callback to handle writes
    pCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
    
    // Set initial value
    pCharacteristic->setValue("Ready");
    
    // Start the service
    pService->start();
    
    // Start advertising
    BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(BLEUUID(SERVICE_UUID));
    pAdvertising->setScanResponse(true);
    pAdvertising->setMinPreferred(0x06);
    pAdvertising->setMaxPreferred(0x12);
    BLEDevice::startAdvertising();
    
    Serial.println("[CORE0] BLE Server started! Waiting for connection...");
    
    while (1) {
        // Handle connection state changes
        if (!deviceConnected && oldDeviceConnected) {
            delay(500);
            pServer->startAdvertising();
            oldDeviceConnected = deviceConnected;
        }
        
        if (deviceConnected && !oldDeviceConnected) {
            oldDeviceConnected = deviceConnected;
        }
        
        // Receive encoder samples from Core 1 - send IMMEDIATELY (live streaming)
        EncoderSample sample;
        if (xQueueReceive(dataQueue, &sample, pdMS_TO_TICKS(10)) == pdTRUE) {
            if (sample.isComplete) {
                // Sampling complete - send dataEnd
                if (liveStreamingActive && deviceConnected) {
                    uint32_t completionId = (streamingDataId != 0) ? streamingDataId : sample.id;
                    sendBLEMessage("{\"type\":\"dataEnd\",\"id\":" + String(completionId) + "}");
                    sendBLEMessage("{\"type\":\"completion\",\"id\":" + String(completionId) + ",\"reason\":\"time\"}");
                }
                
                liveStreamingActive = false;
                streamingDataId = 0;
                samplesReceivedSoFar = 0;
                firstCountsInStream = 0;
                prevTimeMs = 0;
                prevCounts = 0;
                prevVelocity = 0.0f;
            } else {
                // Regular sample - send IMMEDIATELY (live streaming)
                if (!liveStreamingActive) {
                    // Start new data stream
                    liveStreamingActive = true;
                    streamingDataId = sample.id;
                    samplesReceivedSoFar = 0;
                    firstCountsInStream = sample.counts;
                    prevTimeMs = sample.timeMs;
                    prevCounts = sample.counts;
                    prevVelocity = 0.0f;
                    
                    if (deviceConnected) {
                        sendBLEMessage("{\"type\":\"dataStart\",\"id\":" + String(sample.id) + ",\"samples\":0}");
                        delay(20);
                        sendBLEMessage("{\"type\":\"metadata\",\"countsPerRev\":" + String(COUNTS_PER_REV) + 
                                     ",\"spoolRadiusM\":" + String(SPOOL_RADIUS_M, 6) + 
                                     ",\"sampleIntervalMs\":" + String(SAMPLE_INTERVAL_MS) + "}");
                        delay(20);
                    }
                }
                
                // Calculate relative counts (relative to first sample in stream)
                int32_t relativeCount = sample.counts - firstCountsInStream;
                
                // Calculate position
                float position = (relativeCount / (float)COUNTS_PER_REV) * 2.0f * PI * SPOOL_RADIUS_M;
                
                // Calculate velocity and RPM from previous sample
                float velocity = 0.0f;
                float rpm = 0.0f;
                float acceleration = 0.0f;
                
                if (samplesReceivedSoFar > 0) {
                    int32_t countDelta = sample.counts - prevCounts;
                    unsigned long timeDelta = sample.timeMs - prevTimeMs;
                    if (timeDelta > 0) {
                        float dtSec = timeDelta / 1000.0f;
                        velocity = (countDelta * COUNTS_TO_DISTANCE_M) / dtSec;
                        rpm = (countDelta / dtSec) * (60.0f / COUNTS_PER_REV);
                        
                        // Calculate acceleration from velocity change
                        if (samplesReceivedSoFar > 1) {
                            float velocityDelta = velocity - prevVelocity;
                            acceleration = velocityDelta / dtSec;
                        }
                    }
                }
                
                // Send single sample immediately (live streaming)
                if (deviceConnected) {
                    String dataChunk = "{\"type\":\"dataChunk\",\"id\":" + String(streamingDataId) + 
                                     ",\"start\":" + String(samplesReceivedSoFar) + 
                                     ",\"data\":[{\"t\":" + String(sample.timeMs) + 
                                     ",\"counts\":" + String(relativeCount) +
                                     ",\"position\":" + String(position, 2) +
                                     ",\"velocity\":" + String(velocity, 2) +
                                     ",\"rpm\":" + String(rpm, 1) +
                                     ",\"acceleration\":" + String(acceleration, 2) + "}]}";
                    sendBLEMessage(dataChunk);
                }
                
                // Update for next sample
                samplesReceivedSoFar++;
                prevTimeMs = sample.timeMs;
                prevCounts = sample.counts;
                prevVelocity = velocity;
            }
        }
        
        // Small delay
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

// ============== MAIN SETUP ==============

void setup() {
    Serial.begin(115200);
    delay(500);
    Serial.println("\n\n=== QUICKBURST ESP32 DUAL-CORE STARTING ===");
    Serial.print("Setup running on core: ");
    Serial.println(xPortGetCoreID());
    
    // Create FreeRTOS queues
    commandQueue = xQueueCreate(10, sizeof(MotorCommand));
    dataQueue = xQueueCreate(100, sizeof(EncoderSample));
    
    if (commandQueue == NULL || dataQueue == NULL) {
        Serial.println("ERROR: Failed to create queues!");
        while (1) { delay(1000); }
    }
    
    Serial.println("Queues created successfully");
    
    // Create Core 0 task (Bluetooth)
    xTaskCreatePinnedToCore(
        bluetoothTask,      // Task function
        "BluetoothTask",    // Task name
        8192,               // Stack size (bytes)
        NULL,               // Parameters
        2,                  // Priority (higher = higher priority)
        NULL,               // Task handle
        0                   // Core 0
    );
    
    // Create Core 1 task (Motor & Encoder)
    xTaskCreatePinnedToCore(
        motorControlTask,   // Task function
        "MotorControlTask", // Task name
        8192,               // Stack size (bytes)
        NULL,               // Parameters
        2,                  // Priority
        NULL,               // Task handle
        1                   // Core 1
    );
    
    Serial.println("Tasks created. Core 0: Bluetooth, Core 1: Motor/Encoder");
    Serial.println("Protocol: liveMode, constantForce, percentageBaseline, percentageExecution, stop");
}

// ============== MAIN LOOP ==============

void loop() {
    // Empty - all work is done in FreeRTOS tasks
    vTaskDelay(pdMS_TO_TICKS(1000));
}
