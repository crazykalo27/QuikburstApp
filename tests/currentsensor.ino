/*
 * Current Sensor + Supply Monitor
 *
 * Current sensor:
 *   - Output on GPIO34
 *   - Sensitivity: 66 mV/A
 *   - Zero current output assumed to be Vcc / 2
 *
 * Supply measurement:
 *   - Supply sensed on GPIO4 through 10k / 10k divider
 *   - Divider output = actual supply / 2
 *
 * Notes:
 *   - GPIO4 is ADC2 on ESP32
 *   - ADC2 can be less reliable, especially if Wi-Fi is active
 *   - This code averages samples to reduce noise
 *
 * Zero override: GPIO0 (boot button). Press when 0A to set zero point.
 */

 #define CURRENT_SENSOR_PIN 34
 #define SUPPLY_SENSOR_PIN  4
 #define ZERO_OVERRIDE_PIN 0
 
 #define ADC_BITS 12
 #define ADC_MAX  4095.0
 #define VREF     3.3
 
 #define SENSITIVITY_MV_PER_A 66.0
 #define DIVIDER_RATIO        2.0
 
 #define NUM_SAMPLES 32

 // Zero override: set when button pressed with 0A. -1 = use supply-based zero.
 float overrideZeroMV = -1.0;
 bool lastButtonState = true;  // HIGH = not pressed (pullup)

 // ---------------------------
 // Helper: read averaged raw ADC
 // ---------------------------
 uint32_t readAverageRaw(int pin, int samples = NUM_SAMPLES) {
   uint32_t sum = 0;
 
   for (int i = 0; i < samples; i++) {
     sum += analogRead(pin);
     delayMicroseconds(200);
   }
 
   return sum / samples;
 }
 
 // ---------------------------
 // Helper: convert raw ADC to pin voltage
 // ---------------------------
 float rawToVoltage(uint32_t raw) {
   return (raw / ADC_MAX) * VREF;
 }
 
 // ---------------------------
 // Helper: read averaged pin voltage
 // ---------------------------
 float readAverageVoltage(int pin, int samples = NUM_SAMPLES) {
   uint32_t raw = readAverageRaw(pin, samples);
   return rawToVoltage(raw);
 }
 
 void setup() {
   Serial.begin(115200);
   delay(500);
 
   analogReadResolution(ADC_BITS);
   analogSetAttenuation(ADC_11db);   // widest input range
 
   pinMode(CURRENT_SENSOR_PIN, INPUT);
   pinMode(SUPPLY_SENSOR_PIN, INPUT);
   pinMode(ZERO_OVERRIDE_PIN, INPUT_PULLUP);

   Serial.println();
   Serial.println("ESP32 Current Sensor Test");
   Serial.println("Current sensor on GPIO34");
   Serial.println("Supply divider on GPIO4 (ADC2)");
   Serial.println("Zero override: GPIO0 - press when 0A to calibrate");
   Serial.println("--------------------------------");
 }
 
 void loop() {
   // 1) Measure divider node voltage at GPIO4
   float supplyDividerVoltage = readAverageVoltage(SUPPLY_SENSOR_PIN);
 
   // 2) Reconstruct actual supply voltage from 10k/10k divider
   float supplyVoltage = supplyDividerVoltage * DIVIDER_RATIO;
 
   // 3) Measure current sensor output voltage at GPIO34
   float sensorVoltage = readAverageVoltage(CURRENT_SENSOR_PIN);
   float sensorMilliVolts = sensorVoltage * 1000.0;
 
   // 4) Zero-current output: override if button was pressed, else supply/2
   bool buttonPressed = (digitalRead(ZERO_OVERRIDE_PIN) == LOW);
   if (buttonPressed && !lastButtonState) {
     overrideZeroMV = sensorMilliVolts;
     Serial.println(">>> ZERO OVERRIDE: zero set to current reading <<<");
   }
   lastButtonState = buttonPressed;

   float zeroCurrentMilliVolts = (overrideZeroMV >= 0) ? overrideZeroMV : (supplyVoltage * 1000.0) / 2.0;

   // 5) Convert sensor delta voltage to current
   float amps = (sensorMilliVolts - zeroCurrentMilliVolts) / SENSITIVITY_MV_PER_A;
 
   // 6) Print results
   Serial.print("Supply pin: ");
   Serial.print(supplyDividerVoltage, 3);
   Serial.print(" V  |  Supply actual: ");
   Serial.print(supplyVoltage, 3);
   Serial.print(" V  |  Sensor: ");
   Serial.print(sensorMilliVolts, 1);
   Serial.print(" mV  |  Zero: ");
   Serial.print(zeroCurrentMilliVolts, 1);
   if (overrideZeroMV >= 0) Serial.print(" (override)");
   Serial.print(" mV  |  Current: ");
   Serial.print(amps, 3);
   Serial.println(" A");
 
   delay(200);
 }