/*
 * QuickBurst Rotary Encoder + Bluetooth + Motor Control Arduino Code
 * 
 * Hardware: ESP32 + Incremental Optical Encoder (600 PPR, quadrature) + L293D H-bridge
 * Communication: BLE (Service UUID: FFE0, Characteristic UUID: FFE1)
 * 
 * Motor Control:
 *   - PWM on GPIO25 (EN pin) via LEDC, 20 kHz, 10-bit resolution
 *   - Direction on GPIO26 (IN1) and GPIO27 (IN2)
 *   - Closed-loop speed control using encoder feedback
 *   - Drill commands via JSON over BLE
 * 
 * Required Libraries:
 *   - ESP32 Arduino Core (built-in PCNT and LEDC support)
 *   - BLE libraries (BLEDevice, BLEServer, BLEUtils, BLE2902)
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

// ============== ENCODER SPECIFICATIONS ==============

const int COUNTS_PER_REV = 2400;             // 600 PPR * 4 (quadrature)
const float SPOOL_RADIUS_M = 0.1016;         // 4 inches in meters
const float COUNTS_TO_DISTANCE_M = (2.0 * PI * SPOOL_RADIUS_M) / COUNTS_PER_REV; // meters per count

// ============== PCNT CONFIGURATION ==============

const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
const int16_t PCNT_HIGH_LIMIT = 32767;
const int16_t PCNT_LOW_LIMIT  = -32768;

// Overflow tracking (PCNT is 16-bit, we need 32-bit range)
volatile int32_t overflowCount = 0;

// ============== CONTROL LOOP CONFIGURATION ==============

const unsigned long CONTROL_INTERVAL_MS = 10;  // Control loop period (10 ms = 100 Hz)
const unsigned long TELEMETRY_INTERVAL_MS = 25; // Telemetry send period (25 ms = 40 Hz)

// PI controller gains (tuned for speed control)
const float KP = 0.15f;  // Proportional gain
const float KI = 0.02f;  // Integral gain
const float MAX_DUTY_SAFETY = 0.8f;  // Safety limit: max 80% duty

// ============== MOTOR DRIVER CLASS ==============

class MotorDriver {
public:
    MotorDriver() : pwmDuty(0), direction(1), initialized(false) {}
    
    void begin() {
        // Configure GPIO pins
        pinMode(MOTOR_IN1_PIN, OUTPUT);
        pinMode(MOTOR_IN2_PIN, OUTPUT);
        
        // Set direction pins LOW initially (coast)
        digitalWrite(MOTOR_IN1_PIN, LOW);
        digitalWrite(MOTOR_IN2_PIN, LOW);
        
        // Configure LEDC for PWM
        ledc_timer_config_t timerConf = {
            .speed_mode = LEDC_LOW_SPEED_MODE,
            .duty_resolution = (ledc_timer_bit_t)PWM_RESOLUTION_BITS,
            .timer_num = PWM_TIMER,
            .freq_hz = PWM_FREQ_HZ,
            .clk_cfg = LEDC_AUTO_CLK
        };
        ledc_timer_config(&timerConf);
        
        // Configure LEDC channel
        ledc_channel_config_t channelConf = {
            .gpio_num = MOTOR_EN_PIN,
            .speed_mode = LEDC_LOW_SPEED_MODE,
            .channel = PWM_CHANNEL,
            .timer_sel = PWM_TIMER,
            .duty = 0,
            .hpoint = 0
        };
        ledc_channel_config(&channelConf);
        
        // Ensure PWM starts at 0 (motor disabled)
        setDuty01(0.0f);
        initialized = true;
        Serial.println("MotorDriver initialized");
    }
    
    void setDirection(int dir) {
        // dir: +1 = forward, -1 = reverse
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
        // Clamp duty to [0, 1]
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

// ============== DRILL COMMAND STRUCTURE ==============

struct DrillCommand {
    uint32_t id;
    float targetSpeed;      // m/s
    uint32_t durationMs;    // 0 if unused
    float targetDistance;   // meters, 0 if unused
    float forcePercent;     // 0-100, maps to maxDuty
    uint32_t rampMs;        // ramp time
    int direction;          // +1 forward, -1 reverse
};

// ============== DRILL STATE MACHINE ==============

enum DrillState {
    DRILL_IDLE,
    DRILL_RAMP,
    DRILL_HOLD,
    DRILL_DONE,
    DRILL_ABORT
};

// Forward declarations
int32_t readEncoderCount();
void resetEncoderSpeedState();

class DrillRunner {
public:
    DrillRunner() : state(DRILL_IDLE), cmd(), startTime(0), startPosition(0), 
                    integral(0.0f), lastError(0.0f), lastControlTime(0) {}
    
    void start(const DrillCommand& command) {
        cmd = command;
        state = DRILL_RAMP;
        startTime = millis();
        startPosition = readEncoderCount();
        integral = 0.0f;
        lastError = 0.0f;
        lastControlTime = millis();
        
        // Reset encoder speed calculation state
        resetEncoderSpeedState();
        
        // Set motor direction
        motorDriver.setDirection(cmd.direction);
        
        Serial.print("Drill started: ID=");
        Serial.print(cmd.id);
        Serial.print(", targetSpeed=");
        Serial.print(cmd.targetSpeed);
        Serial.print(" m/s, direction=");
        Serial.println(cmd.direction);
    }
    
    void abort() {
        if (state != DRILL_IDLE && state != DRILL_DONE) {
            state = DRILL_ABORT;
            motorDriver.stop();
            Serial.println("Drill aborted");
        }
    }
    
    void update(unsigned long nowMs, float encoderSpeedMps, int32_t encoderPosition) {
        if (state == DRILL_IDLE || state == DRILL_DONE || state == DRILL_ABORT) {
            return;
        }
        
        unsigned long elapsedMs = nowMs - startTime;
        int32_t positionDelta = encoderPosition - startPosition;
        float distanceM = positionDelta * COUNTS_TO_DISTANCE_M;
        
        // Check completion conditions
        bool timeComplete = (cmd.durationMs > 0 && elapsedMs >= cmd.durationMs);
        bool distanceComplete = (cmd.targetDistance > 0 && distanceM >= cmd.targetDistance);
        
        if (timeComplete || distanceComplete) {
            state = DRILL_DONE;
            motorDriver.stop();
            Serial.println("Drill completed");
            return;
        }
        
        // Simplified motor control for testing (motor is too small for actual drills)
        // Map forcePercent (0-100) directly to PWM duty for testing
        // This allows testing different PWM levels even though actual force isn't meaningful
        float maxDuty = (cmd.forcePercent / 100.0f) * MAX_DUTY_SAFETY; // Clamp to safety limit
        
        // Apply ramp profile: ramp up to maxDuty over rampMs
        float dutyCmd = maxDuty;
        if (elapsedMs < cmd.rampMs && cmd.rampMs > 0) {
            dutyCmd = maxDuty * ((float)elapsedMs / (float)cmd.rampMs);
        }
        
        // Apply duty directly (no PI control for small motor testing)
        motorDriver.setDuty01(dutyCmd);
        
        // Transition RAMP -> HOLD when ramp complete
        if (state == DRILL_RAMP && elapsedMs >= cmd.rampMs) {
            state = DRILL_HOLD;
        }
    }
    
    DrillState getState() const { return state; }
    DrillCommand getCommand() const { return cmd; }
    unsigned long getStartTime() const { return startTime; }
    int32_t getStartPosition() const { return startPosition; }
    
    void reset() {
        state = DRILL_IDLE;
        motorDriver.stop();
    }
    
private:
    DrillState state;
    DrillCommand cmd;
    unsigned long startTime;
    int32_t startPosition;
    float integral;
    float lastError;
    unsigned long lastControlTime;
};

DrillRunner drillRunner;

// ============== ENCODER SPEED CALCULATION ==============

int32_t lastEncoderCount = 0;
unsigned long lastSpeedCalcTime = 0;
float lastSpeedMps = 0.0f;

void resetEncoderSpeedState() {
    lastEncoderCount = 0;
    lastSpeedCalcTime = 0;
    lastSpeedMps = 0.0f;
}

float calculateEncoderSpeedMps(unsigned long nowMs, int32_t currentCount) {
    if (lastSpeedCalcTime == 0) {
        lastEncoderCount = currentCount;
        lastSpeedCalcTime = nowMs;
        lastSpeedMps = 0.0f;
        return 0.0f;
    }
    
    unsigned long dtMs = nowMs - lastSpeedCalcTime;
    if (dtMs < 5) {
        return lastSpeedMps; // Too soon, return previous speed
    }
    
    int32_t deltaCount = currentCount - lastEncoderCount;
    float deltaDistanceM = deltaCount * COUNTS_TO_DISTANCE_M;
    float dtSec = dtMs / 1000.0f;
    float speedMps = deltaDistanceM / dtSec;
    
    lastEncoderCount = currentCount;
    lastSpeedCalcTime = nowMs;
    lastSpeedMps = speedMps;
    
    return speedMps;
}

// ============== STATE MACHINE (Legacy Trial System) ==============

enum State { IDLE, RUNNING };
State currentState = IDLE;

unsigned long trialStartTime = 0;
unsigned long lastSampleTime = 0;
unsigned long lastControlTime = 0;
unsigned long lastTelemetryTime = 0;

// ============== PCNT OVERFLOW ISR ==============

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

// ============== PCNT SETUP ==============

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

// ============== ENCODER READ (32-bit safe) ==============

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

// ============== JSON PARSING (Simple parser for specific commands) ==============

// Simple JSON value extractor for our specific format
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
        // String value
        startPos++;
        endPos = json.indexOf('"', startPos);
    } else {
        // Number value
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

bool parseDrillCommand(String json, DrillCommand& cmd) {
    String type = extractJSONValue(json, "type");
    if (type != "drillStart") return false;
    
    String idStr = extractJSONValue(json, "id");
    String targetSpeedStr = extractJSONValue(json, "targetSpeed");
    String durationMsStr = extractJSONValue(json, "durationMs");
    String targetDistanceStr = extractJSONValue(json, "targetDistance");
    String forcePercentStr = extractJSONValue(json, "forcePercent");
    String rampMsStr = extractJSONValue(json, "rampMs");
    String directionStr = extractJSONValue(json, "direction");
    
    if (idStr.length() == 0 || targetSpeedStr.length() == 0) return false;
    
    cmd.id = idStr.toInt();
    cmd.targetSpeed = targetSpeedStr.toFloat();
    cmd.durationMs = (durationMsStr.length() > 0) ? durationMsStr.toInt() : 0;
    cmd.targetDistance = (targetDistanceStr.length() > 0) ? targetDistanceStr.toFloat() : 0.0f;
    cmd.forcePercent = (forcePercentStr.length() > 0) ? forcePercentStr.toFloat() : 100.0f;
    cmd.rampMs = (rampMsStr.length() > 0) ? rampMsStr.toInt() : 0;
    cmd.direction = (directionStr.length() > 0) ? directionStr.toInt() : 1;
    
    // Clamp forcePercent to [0, 100]
    if (cmd.forcePercent < 0.0f) cmd.forcePercent = 0.0f;
    if (cmd.forcePercent > 100.0f) cmd.forcePercent = 100.0f;
    
    return true;
}

// ============== JSON GENERATION (Simple builder) ==============

String createDrillAck(uint32_t id, String status) {
    return "{\"type\":\"drillAck\",\"id\":" + String(id) + ",\"status\":\"" + status + "\"}";
}

String createTelemetryJSON(uint32_t id, unsigned long t, float speed, int32_t position, 
                           float distance, float duty, String state) {
    String json = "{\"type\":\"telemetry\",\"id\":" + String(id) + 
                  ",\"t\":" + String(t) + 
                  ",\"speed\":" + String(speed, 3) + 
                  ",\"position\":" + String(position) + 
                  ",\"distance\":" + String(distance, 3) + 
                  ",\"duty\":" + String(duty, 3) + 
                  ",\"state\":\"" + state + "\"}";
    return json;
}

// ============== BLE CALLBACKS ==============

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.println("Device connected");
        // Send pairing confirmation message
        delay(100); // Small delay to ensure connection is fully established
        sendBLEMessage("ESP32 Paired correctly\n");
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        Serial.println("Device disconnected");
        // Safety: abort any active drill on disconnect
        if (drillRunner.getState() != DRILL_IDLE && drillRunner.getState() != DRILL_DONE) {
            drillRunner.abort();
        }
    }
};

class MyCharacteristicCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pCharacteristic) {
        String value = pCharacteristic->getValue();
        
        if (value.length() > 0) {
            value.trim();
            
            // Try JSON parsing first (drill commands)
            if (value.startsWith("{")) {
                String type = extractJSONValue(value, "type");
                
                if (type == "drillStart") {
                    DrillCommand cmd;
                    if (parseDrillCommand(value, cmd)) {
                        if (drillRunner.getState() == DRILL_IDLE || drillRunner.getState() == DRILL_DONE) {
                            drillRunner.start(cmd);
                            String ack = createDrillAck(cmd.id, "started");
                            sendBLEMessage(ack);
                        } else {
                            String ack = createDrillAck(cmd.id, "busy");
                            sendBLEMessage(ack);
                        }
                    } else {
                        Serial.println("Failed to parse drill command");
                    }
                } else if (type == "drillAbort") {
                    drillRunner.abort();
                    sendBLEMessage("{\"type\":\"drillAck\",\"status\":\"aborted\"}");
                }
                return;
            }
            
            // Legacy text commands (backward compatibility)
            value.trim();
            String valueUpper = value;
            valueUpper.toUpperCase();
            Serial.print("Received command: ");
            Serial.println(value);
            
            if (valueUpper == "START" && currentState == IDLE) {
                startTrial();
            }
            else if (valueUpper == "STOP") {
                stopTrial();
            }
            else if (valueUpper == "RESET") {
                resetEncoder();
                sendBLEMessage("RESET_OK\n");
            }
            else if (valueUpper == "TEST" || value == "test") {
                sendBLEMessage("successful\n");
                Serial.println("Test command received and responded");
            }
        }
    }
};

// ============== TRIAL CONTROL (Legacy) ==============

void startTrial() {
    resetEncoder();
    trialStartTime = millis();
    lastSampleTime = millis();
    currentState = RUNNING;
    
    Serial.println("Trial started");
    sendBLEMessage("TRIAL_STARTED\n");
}

void stopTrial() {
    currentState = IDLE;
    Serial.println("Trial stopped");
    sendBLEMessage("TRIAL_STOPPED\n");
}

void sendBLEMessage(String message) {
    if (deviceConnected && pCharacteristic != NULL) {
        pCharacteristic->setValue(message.c_str());
        pCharacteristic->notify();
    }
}

void sendEncoderData() {
    if (deviceConnected && pCharacteristic != NULL && currentState == RUNNING) {
        unsigned long elapsedTime = millis() - trialStartTime;
        int32_t counts = readEncoderCount();
        
        // Send data as CSV: time_ms,counts
        String dataLine = String(elapsedTime) + "," + String(counts) + "\n";
        pCharacteristic->setValue(dataLine.c_str());
        pCharacteristic->notify();
    }
}

void sendDrillTelemetry() {
    if (!deviceConnected || pCharacteristic == NULL) return;
    
    DrillState state = drillRunner.getState();
    if (state == DRILL_IDLE || state == DRILL_DONE || state == DRILL_ABORT) return;
    
    unsigned long nowMs = millis();
    DrillCommand cmd = drillRunner.getCommand();
    int32_t currentPos = readEncoderCount();
    int32_t startPos = drillRunner.getStartPosition();
    float distanceM = (currentPos - startPos) * COUNTS_TO_DISTANCE_M;
    float speedMps = calculateEncoderSpeedMps(nowMs, currentPos);
    float duty = motorDriver.getDuty();
    
    String stateStr;
    switch (state) {
        case DRILL_RAMP: stateStr = "RAMP"; break;
        case DRILL_HOLD: stateStr = "HOLD"; break;
        default: stateStr = "IDLE"; break;
    }
    
    unsigned long elapsedMs = nowMs - drillRunner.getStartTime();
    String telemetry = createTelemetryJSON(cmd.id, elapsedMs, speedMps, currentPos, 
                                          distanceM, duty, stateStr);
    pCharacteristic->setValue(telemetry.c_str());
    pCharacteristic->notify();
}

// ============== MAIN SETUP ==============

void setup() {
    Serial.begin(115200);
    while (!Serial) { delay(10); }
    
    Serial.println("Starting Quikburst BLE + Encoder + Motor Control Server...");
    
    // Initialize motor driver (ensures EN pin starts LOW)
    motorDriver.begin();
    
    // Initialize BLE device
    BLEDevice::init(DEVICE_NAME);
    
    // Create BLE Server
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());

    // Create BLE Service with UUID FFE0
    BLEService* pService = pServer->getServiceByUUID(BLEUUID(SERVICE_UUID));
    if (pService == nullptr) {
        pService = pServer->createService(BLEUUID(SERVICE_UUID));
    }

    // Create BLE Characteristic with UUID FFE1
    pCharacteristic = pService->createCharacteristic(
        BLEUUID(CHARACTERISTIC_UUID),
        BLECharacteristic::PROPERTY_READ |
        BLECharacteristic::PROPERTY_NOTIFY |
        BLECharacteristic::PROPERTY_WRITE
    );

    // Add descriptor for notifications (required for iOS)
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
    
    // Setup encoder
    setupPCNT();
    
    Serial.println("BLE Server started! Waiting for connection...");
    Serial.print("Device name: ");
    Serial.println(DEVICE_NAME);
    Serial.print("Service UUID: ");
    Serial.println(SERVICE_UUID);
    Serial.print("Characteristic UUID: ");
    Serial.println(CHARACTERISTIC_UUID);
    Serial.println("Commands: JSON drillStart/drillAbort, or legacy START/STOP/RESET");
}

// ============== MAIN LOOP ==============

void loop() {
    unsigned long nowMs = millis();
    
    // Handle connection state changes
    if (!deviceConnected && oldDeviceConnected) {
        // Device just disconnected, restart advertising
        delay(500);
        pServer->startAdvertising();
        Serial.println("Restarting advertising...");
        oldDeviceConnected = deviceConnected;
    }
    
    if (deviceConnected && !oldDeviceConnected) {
        // Device just connected
        oldDeviceConnected = deviceConnected;
        // Pairing message already sent in onConnect callback
    }
    
    // Control loop for drill execution
    if (nowMs - lastControlTime >= CONTROL_INTERVAL_MS) {
        lastControlTime = nowMs;
        
        DrillState state = drillRunner.getState();
        if (state != DRILL_IDLE && state != DRILL_DONE && state != DRILL_ABORT) {
            int32_t encoderPos = readEncoderCount();
            float encoderSpeed = calculateEncoderSpeedMps(nowMs, encoderPos);
            drillRunner.update(nowMs, encoderSpeed, encoderPos);
            
            // Check if drill completed
            if (drillRunner.getState() == DRILL_DONE || drillRunner.getState() == DRILL_ABORT) {
                // Optionally send completion message
                drillRunner.reset();
            }
        }
    }
    
    // Telemetry streaming
    if (nowMs - lastTelemetryTime >= TELEMETRY_INTERVAL_MS) {
        lastTelemetryTime = nowMs;
        sendDrillTelemetry();
    }
    
    // Legacy state machine for encoder sampling (backward compatibility)
    if (currentState == RUNNING) {
        // Sample at fixed intervals
        if (nowMs - lastSampleTime >= 100) {
            lastSampleTime = nowMs;
            sendEncoderData();
        }
    }
    
    delay(1); // Small delay to prevent watchdog issues
}
