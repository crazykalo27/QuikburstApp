/*
 * This is working PWM code for the ESP32
  It should be used as a reference for the PWM code for the ESP32
 */

 #define PWM1_PIN 26  // Changed from 34 (input-only) to 26 (supports PWM output)
 #define PWM2_PIN 25  // Changed to avoid conflict with PWM1_PIN
 #define EN_PIN 27
 
 const int PWM_CHANNEL = 0;
 const int PWM_FREQ = 5000;        // 5kHz PWM frequency (1-10kHz recommended for Teyleten motor driver)
 const int PWM_RESOLUTION = 10;    // 10-bit resolution (0-1023)
 
 float floatMap(float x, float in_min, float in_max, float out_min, float out_max) {
   return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
 }
 
 // the setup routine runs once when you press reset:
 void setup() {
   // initialize serial communication at 9600 bits per second:
   Serial.begin(9600);
   // set the ADC attenuation to 11 dB (up to ~3.3V input)
   analogSetAttenuation(ADC_11db);
 
   pinMode(PWM2_PIN, OUTPUT);
   pinMode(EN_PIN, OUTPUT);
 
   // Setup PWM using LEDC (required for ESP32) - using newer API
   ledcAttachChannel(PWM1_PIN, PWM_FREQ, PWM_RESOLUTION, PWM_CHANNEL);
   ledcWriteChannel(PWM_CHANNEL, 0);  // Start with PWM off
 
   //SET PWM MODE ON MOTOR CONTROLLER
   digitalWrite(EN_PIN, LOW);
   digitalWrite(PWM2_PIN, HIGH);
 }
 
 void loop() {
   // read the input on analog pin GPIO36:
   int analogValue = analogRead(35);
   // Rescale to potentiometer's voltage (from 0V to 3.3V):
   float voltage = floatMap(analogValue, 0, 4095, 0, 3.3);
 
   //sets motor speed (map to 0-1023 for 10-bit PWM)
   int pwm = map(analogValue, 0, 4095, 0, 1023);
 
   ledcWriteChannel(PWM_CHANNEL, pwm);
 
   // print out the value you read:
   Serial.print("Analog: ");
   Serial.print(analogValue);
   Serial.print(", Voltage: ");
   Serial.print(voltage);
   Serial.print(", PWM (0-1023): ");
   Serial.println(pwm);
   //delay(1000);
 }
 