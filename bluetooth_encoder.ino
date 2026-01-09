/*
 * QuickBurst Rotary Encoder + Bluetooth Arduino Code
 * 
 * Hardware: ESP32 + Incremental Optical Encoder (600 PPR, quadrature)
 * Communication: BLE (Service UUID: FFE0, Characteristic UUID: FFE1)
 * 
 * Workflow:
 *   1. App connects via BLE
 *   2. App sends "START" command
 *   3. ESP32 samples encoder at SAMPLE_INTERVAL_MS and sends data live over BLE
 *   4. App sends "STOP" to stop sampling
 *   5. App sends "RESET" to reset encoder counter
 * 
 * Required Libraries:
 *   - ESP32 Arduino Core (built-in PCNT support)
 *   - BLE libraries (BLEDevice, BLEServer, BLEUtils, BLE2902)
 * 
 * Wiring:
 *   Encoder A  -> GPIO 12 (ENCODER_PIN_A)
 *   Encoder B  -> GPIO 13 (ENCODER_PIN_B)
 *   Encoder VCC -> 5V
 *   Encoder GND -> GND
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "driver/pcnt.h"

// ============== BLE CONFIGURATION ==============

#define SERVICE_UUID        "FFE0"
#define CHARACTERISTIC_UUID "FFE1"
#define DEVICE_NAME "Quikburst"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// ============== CONFIGURABLE PARAMETERS ==============

const unsigned long SAMPLE_INTERVAL_MS = 100;    // Sampling period (ms)

// ============== HARDWARE CONFIGURATION ==============

const int ENCODER_PIN_A = 12;  // Quadrature channel A
const int ENCODER_PIN_B = 13;  // Quadrature channel B

// ============== ENCODER SPECIFICATIONS ==============

const int COUNTS_PER_REV = 2400;             // 600 PPR * 4 (quadrature)
const float SPOOL_RADIUS_M = 0.1016;         // 4 inches in meters

// ============== PCNT CONFIGURATION ==============

const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
const int16_t PCNT_HIGH_LIMIT = 32767;
const int16_t PCNT_LOW_LIMIT  = -32768;

// Overflow tracking (PCNT is 16-bit, we need 32-bit range)
volatile int32_t overflowCount = 0;

// ============== STATE MACHINE ==============

enum State { IDLE, RUNNING };
State currentState = IDLE;

unsigned long trialStartTime = 0;
unsigned long lastSampleTime = 0;

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

// ============== BLE CALLBACKS ==============

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.println("Device connected");
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        Serial.println("Device disconnected");
    }
};

class MyCharacteristicCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pCharacteristic) {
        String value = pCharacteristic->getValue();
        
        if (value.length() > 0) {
            value.trim();
            value.toUpperCase();
            Serial.print("Received command: ");
            Serial.println(value);
            
            if (value == "START" && currentState == IDLE) {
                startTrial();
            }
            else if (value == "STOP") {
                stopTrial();
            }
            else if (value == "RESET") {
                resetEncoder();
                sendBLEMessage("RESET_OK\n");
            }
        }
    }
};

// ============== TRIAL CONTROL ==============

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

// ============== MAIN SETUP ==============

void setup() {
    Serial.begin(115200);
    while (!Serial) { delay(10); }
    
    Serial.println("Starting Quikburst BLE + Encoder Server...");
    
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
    Serial.println("Commands: START, STOP, RESET");
}

// ============== MAIN LOOP ==============

void loop() {
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
        sendBLEMessage("QUICKBURST_READY\n");
    }
    
    // State machine for encoder sampling
    if (currentState == RUNNING) {
        // Sample at fixed intervals
        if (millis() - lastSampleTime >= SAMPLE_INTERVAL_MS) {
            lastSampleTime = millis();
            sendEncoderData();
        }
    }
    
    delay(10); // Small delay to prevent watchdog issues
}
