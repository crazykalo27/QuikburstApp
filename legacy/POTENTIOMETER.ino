/*
 * PWM Motor Control + Encoder for ESP32
 *
 * Combines workingPWM.ino motor control with encoder reading.
 * Potentiometer (GPIO 35) controls motor speed.
 * Controlled via serial: "F 5" (forward 5s), "B 5" (backward 5s).
 *
 * Motor: PWM1=26, PWM2=25, EN=27. EN always LOW.
 * Idle: both PWM1 and PWM2 HIGH. Forward: PWM1=pwm, PWM2=HIGH. Backward: PWM1=HIGH, PWM2=pwm.
 */

 #include "driver/pcnt.h"

 #define PWM1_PIN 26
 #define PWM2_PIN 25
 #define EN_PIN 27
 #define POT_PIN 35
 
 #define ENCODER_PIN_A 12
 #define ENCODER_PIN_B 13
 
 const int PWM_CHANNEL_1 = 0;
 const int PWM_CHANNEL_2 = 1;
 const int PWM_FREQ = 5000;
 const int PWM_RESOLUTION = 10;  // 0-1023
 
 const unsigned long SAMPLE_INTERVAL_MS = 10;
 const int COUNTS_PER_REV = 2400;
 const float SPOOL_RADIUS_M = 0.003f;
 
 const int MAX_SAMPLES = 1200;  // 10s * 100 Hz + margin
 
 const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
 const int16_t PCNT_HIGH_LIMIT = 32767;
 const int16_t PCNT_LOW_LIMIT = -32768;
 
 int32_t countBuffer[MAX_SAMPLES];
 unsigned long timeBuffer[MAX_SAMPLES];
 int sampleIndex = 0;
 volatile int32_t overflowCount = 0;
 
 enum Direction { DIR_NONE, DIR_FORWARD, DIR_BACKWARD };
 enum State { IDLE, RUNNING, TRANSMITTING };
 State currentState = IDLE;
 Direction trialDirection = DIR_NONE;
 unsigned long trialStartTime = 0;
 unsigned long trialDurationMs = 0;
 unsigned long lastSampleTime = 0;
 
 int pwmValue = 0;  // From potentiometer
 
 void IRAM_ATTR pcntOverflowISR(void *arg) {
     uint32_t status = 0;
     pcnt_get_event_status(PCNT_UNIT, &status);
     if (status & PCNT_EVT_H_LIM) overflowCount += PCNT_HIGH_LIMIT;
     if (status & PCNT_EVT_L_LIM) overflowCount += PCNT_LOW_LIMIT;
 }
 
 void setupPCNT() {
     pcnt_config_t config = {
         .pulse_gpio_num = ENCODER_PIN_A,
         .ctrl_gpio_num  = ENCODER_PIN_B,
         .lctrl_mode     = PCNT_MODE_REVERSE,
         .hctrl_mode     = PCNT_MODE_KEEP,
         .pos_mode       = PCNT_COUNT_INC,
         .neg_mode       = PCNT_COUNT_DEC,
         .counter_h_lim  = PCNT_HIGH_LIMIT,
         .counter_l_lim  = PCNT_LOW_LIMIT,
         .unit           = PCNT_UNIT,
         .channel        = PCNT_CHANNEL_0
     };
     pcnt_unit_config(&config);
 
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
 
     pcnt_set_filter_value(PCNT_UNIT, 100);
     pcnt_filter_enable(PCNT_UNIT);
     pcnt_event_enable(PCNT_UNIT, PCNT_EVT_H_LIM);
     pcnt_event_enable(PCNT_UNIT, PCNT_EVT_L_LIM);
     pcnt_isr_service_install(0);
     pcnt_isr_handler_add(PCNT_UNIT, pcntOverflowISR, NULL);
     pcnt_counter_pause(PCNT_UNIT);
     pcnt_counter_clear(PCNT_UNIT);
     pcnt_counter_resume(PCNT_UNIT);
 }
 
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
 
 void setMotorIdle() {
     ledcWriteChannel(PWM_CHANNEL_1, 1023);  // PWM1 HIGH
     ledcWriteChannel(PWM_CHANNEL_2, 1023);  // PWM2 HIGH
 }
 
 void setMotorForward(int pwm) {
     ledcWriteChannel(PWM_CHANNEL_1, pwm);
     ledcWriteChannel(PWM_CHANNEL_2, 1023);  // PWM2 HIGH
 }
 
 void setMotorBackward(int pwm) {
     ledcWriteChannel(PWM_CHANNEL_1, 1023);  // PWM1 HIGH
     ledcWriteChannel(PWM_CHANNEL_2, pwm);
 }
 
 void startTrial(Direction dir, unsigned long durationMs) {
     trialDirection = dir;
     trialDurationMs = durationMs;
     sampleIndex = 0;
     resetEncoder();
     trialStartTime = millis();
     lastSampleTime = millis();
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
     Serial.println("DATA_START");
     Serial.print("COUNTS_PER_REV:");
     Serial.println(COUNTS_PER_REV);
     Serial.print("SPOOL_RADIUS_M:");
     Serial.println(SPOOL_RADIUS_M, 6);
     Serial.print("SAMPLE_INTERVAL_MS:");
     Serial.println(SAMPLE_INTERVAL_MS);
     Serial.println("time_ms,counts");
     for (int i = 0; i < sampleIndex; i++) {
         Serial.print(timeBuffer[i]);
         Serial.print(",");
         Serial.println(countBuffer[i]);
     }
     Serial.println("DATA_END");
     trialDirection = DIR_NONE;
     currentState = IDLE;
 }
 
 void setup() {
     Serial.begin(115200);
     analogSetAttenuation(ADC_11db);
 
     pinMode(EN_PIN, OUTPUT);
     digitalWrite(EN_PIN, LOW);
 
     ledcAttachChannel(PWM1_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_1);
     ledcAttachChannel(PWM2_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL_2);
     setMotorIdle();
 
     setupPCNT();
 
     Serial.println("QUICKBURST_READY");
     Serial.println("Commands: F <1-10> (forward), B <1-10> (backward), RESET");
 }
 
 void loop() {
     // Read potentiometer (always, for when trial is running)
     int analogValue = analogRead(POT_PIN);
     pwmValue = map(analogValue, 0, 4095, 0, 1023);
 
     // Handle serial commands
     if (Serial.available() && currentState == IDLE) {
         String line = Serial.readStringUntil('\n');
         line.trim();
         line.toUpperCase();
 
         if (line == "RESET") {
             Serial.println("RESET_OK");
         } else if (line.length() >= 3) {
             char dir = line.charAt(0);
             int spaceIdx = line.indexOf(' ');
             if (spaceIdx > 0 && spaceIdx < (int)line.length() - 1) {
                 int duration = line.substring(spaceIdx + 1).toInt();
                 if (duration >= 1 && duration <= 10) {
                     if (dir == 'F') {
                         startTrial(DIR_FORWARD, (unsigned long)duration * 1000);
                     } else if (dir == 'B') {
                         startTrial(DIR_BACKWARD, (unsigned long)duration * 1000);
                     }
                 }
             }
         }
     }
 
     switch (currentState) {
         case IDLE:
             setMotorIdle();
             break;
 
         case RUNNING:
             if (trialDirection == DIR_FORWARD) {
                 setMotorForward(pwmValue);
             } else if (trialDirection == DIR_BACKWARD) {
                 setMotorBackward(pwmValue);
             }
 
             if (millis() - lastSampleTime >= SAMPLE_INTERVAL_MS) {
                 lastSampleTime = millis();
                 sampleData();
             }
 
             if (millis() - trialStartTime >= trialDurationMs) {
                 setMotorIdle();
                 transmitData();
             }
             break;
 
         case TRANSMITTING:
             break;
     }
 }
 