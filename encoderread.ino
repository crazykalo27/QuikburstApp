/*
 * QuickBurst Rotary Encoder Data Arduino Code
 * 
 * Hardware: ESP32 + Incremental Optical Encoder (600 PPR, quadrature)
 * Communication: Serial (115200 baud)
 * 
 * Workflow:
 *   1. Python sends "START" command
 *   2. ESP32 samples encoder for TRIAL_DURATION_MS
 *   3. ESP32 transmits CSV data batch
 *   4. Python sends "RESET" to repeat
 * 
 * Required Libraries:
 *   - ESP32 Arduino Core (built-in PCNT support)
 * 
 * Wiring:
 *   Encoder A  -> GPIO 34 (ENCODER_PIN_A)
 *   Encoder B  -> GPIO 35 (ENCODER_PIN_B)
 *   Encoder VCC -> 5V
 *   Encoder GND -> GND
 */

 #include "driver/pcnt.h"

 // ============== CONFIGURABLE PARAMETERS ==============
 // Adjust these as needed after viewing plots
 
 const unsigned long SAMPLE_INTERVAL_MS = 100;    // Sampling period (ms)
 const unsigned long TRIAL_DURATION_MS  = 30000;  // Total trial duration (ms)
 
 // ============== HARDWARE CONFIGURATION ==============
 
 const int ENCODER_PIN_A = 12;  // Quadrature channel A
 const int ENCODER_PIN_B = 13;  // Quadrature channel B
 
 // ============== ENCODER SPECIFICATIONS ==============
 
 const int COUNTS_PER_REV = 2400;             // 600 PPR * 4 (quadrature)
 const float SPOOL_RADIUS_M = 0.1016;         // 4 inches in meters
 
 // ============== DERIVED CONSTANTS ==============
 
 const int MAX_SAMPLES = (TRIAL_DURATION_MS / SAMPLE_INTERVAL_MS) + 10;  // Buffer with margin
 
 // ============== PCNT CONFIGURATION ==============
 
 const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
 const int16_t PCNT_HIGH_LIMIT = 32767;
 const int16_t PCNT_LOW_LIMIT  = -32768;
 
 // ============== DATA STORAGE ==============
 
 int32_t countBuffer[MAX_SAMPLES];       // Raw encoder counts
 unsigned long timeBuffer[MAX_SAMPLES];  // Timestamps (ms)
 int sampleIndex = 0;
 
 // Overflow tracking (PCNT is 16-bit, we need 32-bit range)
 volatile int32_t overflowCount = 0;
 
 // ============== STATE MACHINE ==============
 
 enum State { IDLE, RUNNING, TRANSMITTING };
 State currentState = IDLE;
 
 unsigned long trialStartTime = 0;
 
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
 
 // ============== TRIAL CONTROL ==============
 
 void startTrial() {
     // Reset state
     sampleIndex = 0;
     resetEncoder();
     trialStartTime = millis();
     currentState = RUNNING;
     
     Serial.println("TRIAL_STARTED");
 }
 
 void sampleData() {
     if (sampleIndex < MAX_SAMPLES) {
         timeBuffer[sampleIndex] = millis() - trialStartTime;
         countBuffer[sampleIndex] = readEncoderCount();
         sampleIndex++;
     }
 }
 
 void transmitData() {
     currentState = TRANSMITTING;
     
     // Header
     Serial.println("DATA_START");
     Serial.print("SAMPLES:");
     Serial.println(sampleIndex);
     Serial.print("COUNTS_PER_REV:");
     Serial.println(COUNTS_PER_REV);
     Serial.print("SPOOL_RADIUS_M:");
     Serial.println(SPOOL_RADIUS_M, 6);
     Serial.print("SAMPLE_INTERVAL_MS:");
     Serial.println(SAMPLE_INTERVAL_MS);
     
     // CSV header
     Serial.println("time_ms,counts");
     
     // Data rows
     for (int i = 0; i < sampleIndex; i++) {
         Serial.print(timeBuffer[i]);
         Serial.print(",");
         Serial.println(countBuffer[i]);
     }
     
     Serial.println("DATA_END");
     
     currentState = IDLE;
 }
 
 // ============== MAIN SETUP ==============
 
 void setup() {
     Serial.begin(115200);
     while (!Serial) { delay(10); }
     
     setupPCNT();
     
     Serial.println("QUICKBURST_READY");
     Serial.println("Commands: START, RESET");
 }
 
 // ============== MAIN LOOP ==============
 
 unsigned long lastSampleTime = 0;
 
 void loop() {
     // Handle serial commands
     if (Serial.available()) {
         String cmd = Serial.readStringUntil('\n');
         cmd.trim();
         cmd.toUpperCase();
         
         if (cmd == "START" && currentState == IDLE) {
             startTrial();
         }
         else if (cmd == "RESET" && currentState == IDLE) {
             Serial.println("RESET_OK");
         }
     }
     
     // State machine
     switch (currentState) {
         case IDLE:
             // Waiting for command
             break;
             
         case RUNNING:
             // Sample at fixed intervals
             if (millis() - lastSampleTime >= SAMPLE_INTERVAL_MS) {
                 lastSampleTime = millis();
                 sampleData();
             }
             
             // Check if trial complete
             if (millis() - trialStartTime >= TRIAL_DURATION_MS) {
                 transmitData();
             }
             break;
             
         case TRANSMITTING:
             // Handled in transmitData()
             break;
     }
 }