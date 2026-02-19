/*
 * ============================================================================
 * QuickBurst BLE Encoder Measurement System — ESP32 Firmware
 * ============================================================================
 *
 * PURPOSE:
 *   State-driven encoder measurement pipeline using BLE Nordic UART Service.
 *   Samples rotary encoder at fixed interval, processes kinematics on-board,
 *   and transmits smoothed position/velocity/acceleration over BLE.
 *
 * HARDWARE:
 *   - ESP32 DevKit (any variant with BLE)
 *   - Taiss 600 PPR incremental rotary encoder
 *   - x4 quadrature decoding via ESP32 PCNT hardware peripheral
 *
 * WIRING:
 *   Encoder A   → GPIO 25
 *   Encoder B   → GPIO 26
 *   Encoder VCC → 5V
 *   Encoder GND → GND
 *
 * BLE SERVICE:
 *   Nordic UART Service (NUS)
 *   Service UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *   RX UUID:      6E400002-B5A3-F393-E0A9-E50E24DCCA9E  (App → ESP32)
 *   TX UUID:      6E400003-B5A3-F393-E0A9-E50E24DCCA9E  (ESP32 → App)
 *
 * ARCHITECTURE:
 *   Single-loop, no FreeRTOS tasks. micros()-based deterministic sampling.
 *   Dynamic memory via std::vector — no fixed buffer cap.
 *
 * ============================================================================
 * HARDWARE MATH
 * ============================================================================
 *
 * Encoder:
 *   PPR          = 600 pulses/rev (per channel)
 *   Quadrature   = x4 decoding
 *   CPR          = 600 × 4 = 2400 counts/rev
 *
 * Spool:
 *   Diameter     = 0.5 inches
 *   Circumference = π × 0.5 in = 1.570796... in
 *   In meters:     1.570796 in × 0.0254 m/in = 0.039898 m
 *
 * Resolution:
 *   meters_per_count = 0.039898 m / 2400 counts = 1.66243e-5 m/count
 *   Position quantum ≈ 0.0166 mm/count
 *
 * At 100 Hz sampling:
 *   Velocity quantum = 1.66243e-5 m / 0.01 s = 1.66243e-3 m/s ≈ 1.66 mm/s
 *
 * ============================================================================
 * MEMORY STRATEGY
 * ============================================================================
 *
 * std::vector<Sample> grows dynamically during RUNNING state.
 * On DRILL command, we reserve (duration_s × SAMPLE_HZ + 128) entries.
 *
 * Per-sample storage:
 *   uint32_t timestamp_us  (4 bytes)
 *   int32_t  count         (4 bytes)
 *   ─────────────────────────────
 *   Total: 8 bytes/sample
 *
 * ESP32 free heap ≈ 280 KB usable with BLE active.
 *   280,000 / 8 = 35,000 samples = 350 seconds at 100 Hz.
 *
 * If allocation fails, firmware reports ERROR via BLE and returns to IDLE.
 * Processed arrays (position, velocity, acceleration as float) are computed
 * in-place after acquisition, reusing the same vector storage pattern.
 *
 * ============================================================================
 */

 #include <BLEDevice.h>
 #include <BLEServer.h>
 #include <BLEUtils.h>
 #include <BLE2902.h>
 #include "driver/pcnt.h"
 #include <vector>
 #include <algorithm>
 
 // ============================================================================
 // CONFIGURATION — ALL TUNEABLE CONSTANTS IN ONE PLACE
 // ============================================================================
 
 // --- Encoder Hardware ---
 static constexpr int      ENCODER_PIN_A       = 25;
 static constexpr int      ENCODER_PIN_B       = 26;
 static constexpr int      ENCODER_PPR         = 600;
 static constexpr int      QUADRATURE_MULT     = 4;
 static constexpr int      COUNTS_PER_REV      = ENCODER_PPR * QUADRATURE_MULT;  // 2400
 
 // --- Spool Geometry ---
 //   C = π × d = π × 0.5 in × 0.0254 m/in
 static constexpr float    SPOOL_DIA_INCHES    = 4.0f;
 static constexpr float    SPOOL_CIRCUMF_M     = 3.14159265f * SPOOL_DIA_INCHES * 0.0254f;  // 0.039898 m
 static constexpr float    METERS_PER_COUNT    = SPOOL_CIRCUMF_M / (float)COUNTS_PER_REV;   // 1.66243e-5 m
 
 // --- Sampling ---
 static constexpr uint32_t SAMPLE_HZ           = 100;   // Easily adjustable
 static constexpr uint32_t SAMPLE_INTERVAL_US  = 1000000UL / SAMPLE_HZ;  // 10000 µs = 10 ms
 
 // --- Signal Processing ---
 static constexpr int      MEDIAN_WINDOW       = 5;     // Must be odd
 static constexpr int      MA_WINDOW           = 9;     // Moving average kernel size
 
 // --- BLE ---
 static constexpr uint16_t BLE_MTU             = 256;
 static constexpr uint32_t BLE_TX_PACE_MS      = 12;    // ms between notifications (BLE throughput limiter)
 static const char*        DEVICE_NAME         = "QuickBurst";
 
 // --- PCNT ---
 static constexpr pcnt_unit_t PCNT_UNIT        = PCNT_UNIT_0;
 static constexpr int16_t  PCNT_H_LIM          = 32767;
 static constexpr int16_t  PCNT_L_LIM          = -32768;
 
 // --- PCNT Glitch Filter ---
 //   Filter value in APB_CLK cycles (80 MHz → 12.5 ns/cycle)
 //   100 cycles = 1.25 µs — rejects pulses shorter than 1.25 µs
 static constexpr uint16_t PCNT_FILTER_VAL     = 100;
 
 // ============================================================================
 // BLE UUIDs — Nordic UART Service
 // ============================================================================
 
 #define NUS_SERVICE_UUID  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
 #define NUS_RX_UUID       "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
 #define NUS_TX_UUID       "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
 
 // ============================================================================
 // STATE MACHINE
 // ============================================================================
 
 enum class State : uint8_t {
     IDLE,          // Waiting for DRILL command
     ARMED,         // DRILL received, waiting for GO
     RUNNING,       // Sampling encoder at SAMPLE_HZ
     PROCESSING,    // Computing kinematics + smoothing
     SENDING        // Transmitting processed data over BLE
 };
 
 static const char* stateToString(State s) {
     switch (s) {
         case State::IDLE:       return "IDLE";
         case State::ARMED:      return "ARMED";
         case State::RUNNING:    return "RUNNING";
         case State::PROCESSING: return "PROCESSING";
         case State::SENDING:    return "SENDING";
         default:                return "UNKNOWN";
     }
 }
 
 // ============================================================================
 // DATA STRUCTURES
 // ============================================================================
 
 struct RawSample {
     uint32_t timestamp_us;
     int32_t  count;
 };
 
 struct ProcessedSample {
     float time_s;
     float position_m;
     float velocity_mps;
     float accel_mps2;
 };
 
 // ============================================================================
 // GLOBAL STATE
 // ============================================================================
 
 // --- State Machine ---
 static volatile State g_state = State::IDLE;
 static uint32_t       g_drill_duration_s = 0;
 
 // --- Encoder PCNT ---
 static volatile int32_t  g_overflowAccum     = 0;
 static volatile uint32_t g_overflowEventCount = 0;
 
 // --- Data Buffers (dynamic) ---
 static std::vector<RawSample>       g_rawSamples;
 static std::vector<ProcessedSample> g_processed;
 
 // --- Sampling Timing ---
 static uint32_t g_nextSampleUs   = 0;
 static uint32_t g_drillStartUs   = 0;
 static uint32_t g_drillEndUs     = 0;
 static int32_t  g_countAtGo      = 0;
 
 // --- BLE ---
 static BLECharacteristic* g_txChar = nullptr;
 static BLECharacteristic* g_rxChar = nullptr;
 static bool               g_bleConnected = false;
 static String             g_rxBuffer = "";   // Accumulates partial BLE writes
 
 // --- Sending ---
 static size_t g_sendIndex = 0;
 
 // ============================================================================
 // PCNT INTERRUPT SERVICE ROUTINE
 // ============================================================================
 
 void IRAM_ATTR pcntOverflowISR(void* arg) {
     uint32_t status = 0;
     pcnt_get_event_status(PCNT_UNIT, &status);
     if (status & PCNT_EVT_H_LIM) {
         g_overflowAccum += PCNT_H_LIM;
         g_overflowEventCount++;
     }
     if (status & PCNT_EVT_L_LIM) {
         g_overflowAccum += PCNT_L_LIM;
         g_overflowEventCount++;
     }
 }
 
 // ============================================================================
 // ENCODER — ATOMIC READ
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
 // BLE HELPERS
 // ============================================================================
 
 static void bleSend(const char* msg) {
     if (!g_bleConnected || g_txChar == nullptr) return;
     g_txChar->setValue((uint8_t*)msg, strlen(msg));
     g_txChar->notify();
 }
 
 static void bleSendFormatted(const char* fmt, ...) {
     char buf[200];
     va_list args;
     va_start(args, fmt);
     vsnprintf(buf, sizeof(buf), fmt, args);
     va_end(args);
     bleSend(buf);
 }
 
 // ============================================================================
 // BLE CALLBACKS
 // ============================================================================
 
 class ServerCallbacks : public BLEServerCallbacks {
     void onConnect(BLEServer* pServer) override {
         g_bleConnected = true;
         Serial.println("[BLE] Client connected");
     }
 
     void onDisconnect(BLEServer* pServer) override {
         g_bleConnected = false;
         Serial.println("[BLE] Client disconnected");
         // If running, abort
         if (g_state == State::RUNNING || g_state == State::ARMED) {
             g_state = State::IDLE;
             Serial.println("[STATE] → IDLE (disconnect abort)");
         }
         // Restart advertising
         pServer->startAdvertising();
     }
 };
 
 class RxCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic* pChar) override {
        String val = pChar->getValue();
        g_rxBuffer += val;
 
         // Process complete lines (terminated by \n)
         int newlineIdx;
         while ((newlineIdx = g_rxBuffer.indexOf('\n')) >= 0) {
             String line = g_rxBuffer.substring(0, newlineIdx);
             g_rxBuffer = g_rxBuffer.substring(newlineIdx + 1);
             line.trim();
             if (line.length() > 0) {
                 processCommand(line);
             }
         }
     }
 
     void processCommand(const String& cmd) {
         Serial.print("[BLE RX] ");
         Serial.println(cmd);
 
         // ---- DRILL,<seconds> ----
         if (cmd.startsWith("DRILL,")) {
             if (g_state != State::IDLE) {
                 bleSend("ERROR,NOT_IDLE\n");
                 return;
             }
             int commaIdx = cmd.indexOf(',');
             g_drill_duration_s = cmd.substring(commaIdx + 1).toInt();
             if (g_drill_duration_s == 0) {
                 bleSend("ERROR,INVALID_DURATION\n");
                 return;
             }
 
             // Pre-allocate memory
             size_t expectedSamples = (size_t)g_drill_duration_s * SAMPLE_HZ + 128;
             g_rawSamples.clear();
             g_processed.clear();
             try {
                 g_rawSamples.reserve(expectedSamples);
             } catch (...) {
                 bleSend("ERROR,OUT_OF_MEMORY\n");
                 Serial.println("[ERROR] Failed to allocate sample buffer");
                 return;
             }
 
             g_state = State::ARMED;
             Serial.print("[STATE] → ARMED (duration=");
             Serial.print(g_drill_duration_s);
             Serial.println("s)");
 
             bleSendFormatted("READY,%u\n", g_drill_duration_s);
             return;
         }
 
         // ---- GO ----
         if (cmd == "GO") {
             if (g_state != State::ARMED) {
                 bleSend("ERROR,NOT_ARMED\n");
                 return;
             }
             g_countAtGo    = readEncoderCount();
             g_drillStartUs = micros();
             g_drillEndUs   = g_drillStartUs + (g_drill_duration_s * 1000000UL);
             g_nextSampleUs = g_drillStartUs;  // First sample immediately
             g_rawSamples.clear();
 
             g_state = State::RUNNING;
             Serial.println("[STATE] → RUNNING");
             bleSend("RUNNING\n");
             return;
         }
 
         // ---- ABORT ----
         if (cmd == "ABORT") {
             if (g_state == State::RUNNING || g_state == State::ARMED ||
                 g_state == State::PROCESSING || g_state == State::SENDING) {
                 g_rawSamples.clear();
                 g_processed.clear();
                 g_state = State::IDLE;
                 Serial.println("[STATE] → IDLE (aborted)");
                 bleSend("ABORTED\n");
             }
             return;
         }
 
         Serial.print("[BLE] Unknown command: ");
         Serial.println(cmd);
         bleSend("ERROR,UNKNOWN_CMD\n");
     }
 };
 
 // ============================================================================
 // PCNT HARDWARE SETUP
 // ============================================================================
 
 static void setupPCNT() {
     // Channel 0: pulse on A, control on B
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
 
     // Channel 1: pulse on B, control on A (completes x4 quadrature)
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
 
     // Glitch filter
     pcnt_set_filter_value(PCNT_UNIT, PCNT_FILTER_VAL);
     pcnt_filter_enable(PCNT_UNIT);
 
     // Overflow interrupts
     pcnt_event_enable(PCNT_UNIT, PCNT_EVT_H_LIM);
     pcnt_event_enable(PCNT_UNIT, PCNT_EVT_L_LIM);
     pcnt_isr_service_install(0);
     pcnt_isr_handler_add(PCNT_UNIT, pcntOverflowISR, NULL);
 
     pcnt_counter_pause(PCNT_UNIT);
     pcnt_counter_clear(PCNT_UNIT);
     pcnt_counter_resume(PCNT_UNIT);
 
     Serial.println("[PCNT] Initialized — x4 quadrature, 2400 CPR");
 }
 
 // ============================================================================
 // BLE SETUP
 // ============================================================================
 
 static void setupBLE() {
     BLEDevice::init(DEVICE_NAME);
     BLEDevice::setMTU(BLE_MTU);
 
     BLEServer* pServer = BLEDevice::createServer();
     pServer->setCallbacks(new ServerCallbacks());
 
     BLEService* pService = pServer->createService(NUS_SERVICE_UUID);
 
     // TX characteristic (ESP32 → App): notify
     g_txChar = pService->createCharacteristic(
         NUS_TX_UUID,
         BLECharacteristic::PROPERTY_NOTIFY
     );
     g_txChar->addDescriptor(new BLE2902());
 
     // RX characteristic (App → ESP32): write
     g_rxChar = pService->createCharacteristic(
         NUS_RX_UUID,
         BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
     );
     g_rxChar->setCallbacks(new RxCallbacks());
 
     pService->start();
 
     BLEAdvertising* pAdv = BLEDevice::getAdvertising();
     pAdv->addServiceUUID(NUS_SERVICE_UUID);
     pAdv->setScanResponse(true);
     pAdv->setMinPreferred(0x06);
     pAdv->setMinPreferred(0x12);
     BLEDevice::startAdvertising();
 
     Serial.printf("[BLE] Advertising as '%s'\n", DEVICE_NAME);
 }
 
 // ============================================================================
 // SIGNAL PROCESSING — MEDIAN FILTER
 // ============================================================================
 
 /*
  * In-place median filter, window = MEDIAN_WINDOW (5).
  * For boundary samples (first/last 2), the original value is preserved.
  *
  * Complexity: O(N × W log W) where W = 5, so effectively O(N).
  */
 static void medianFilter(std::vector<float>& data) {
     const int N = (int)data.size();
     const int halfW = MEDIAN_WINDOW / 2;  // 2 for window=5
     if (N < MEDIAN_WINDOW) return;
 
     // Work on a copy to avoid read-after-write issues
     std::vector<float> out(data);
     float window[MEDIAN_WINDOW];
 
     for (int i = halfW; i < N - halfW; i++) {
         for (int j = 0; j < MEDIAN_WINDOW; j++) {
             window[j] = data[i - halfW + j];
         }
         // Insertion sort for 5 elements (fast, branch-predictor friendly)
         for (int a = 1; a < MEDIAN_WINDOW; a++) {
             float key = window[a];
             int b = a - 1;
             while (b >= 0 && window[b] > key) {
                 window[b + 1] = window[b];
                 b--;
             }
             window[b + 1] = key;
         }
         out[i] = window[halfW];  // Median is middle element
     }
     data = out;
 }
 
 // ============================================================================
 // SIGNAL PROCESSING — MOVING AVERAGE FILTER
 // ============================================================================
 
 /*
  * Symmetric moving average, window = MA_WINDOW (9).
  * Boundary samples (first/last 4) preserve original value.
  * Uses running sum for O(N) performance.
  */
 static void movingAverage(std::vector<float>& data) {
     const int N = (int)data.size();
     const int halfW = MA_WINDOW / 2;  // 4 for window=9
     if (N < MA_WINDOW) return;
 
     std::vector<float> out(data);
 
     // Initial window sum
     float sum = 0.0f;
     for (int j = 0; j < MA_WINDOW; j++) {
         sum += data[j];
     }
     out[halfW] = sum / (float)MA_WINDOW;
 
     // Slide window
     for (int i = halfW + 1; i < N - halfW; i++) {
         sum += data[i + halfW] - data[i - halfW - 1];
         out[i] = sum / (float)MA_WINDOW;
     }
     data = out;
 }
 
 // ============================================================================
 // DATA PROCESSING — FULL PIPELINE
 // ============================================================================
 
 /*
  * Pipeline (executed in PROCESSING state):
  *   1. Convert raw counts → position (meters)
  *   2. Apply median filter (window=5) to position
  *   3. Apply moving average (window=9) to position
  *   4. Compute velocity via central difference on smoothed position
  *   5. Compute acceleration via central difference on velocity
  *
  * Central difference formula:
  *   v[i] = (x[i+1] - x[i-1]) / (2·Δt)
  *   a[i] = (v[i+1] - v[i-1]) / (2·Δt)
  *
  * Boundary handling:
  *   v[0]   = (x[1] - x[0]) / Δt           (forward difference)
  *   v[N-1] = (x[N-1] - x[N-2]) / Δt       (backward difference)
  *   Same pattern for acceleration from velocity.
  *
  * Δt is the nominal sample interval: 1.0 / SAMPLE_HZ
  *   This is valid because sampling uses deterministic micros() timing.
  *   Any residual jitter is sub-ms and negligible for the smoothed signal.
  */
 static bool processData() {
     const size_t N = g_rawSamples.size();
     if (N < (size_t)MA_WINDOW + 2) {
         Serial.println("[PROC] Insufficient samples for processing");
         return false;
     }
 
     const float dt = 1.0f / (float)SAMPLE_HZ;
     const float dt2 = 2.0f * dt;
 
     Serial.print("[PROC] Processing ");
     Serial.print(N);
     Serial.println(" samples...");
 
     // --- Step 1: Raw counts → position (meters) ---
     std::vector<float> pos(N);
     for (size_t i = 0; i < N; i++) {
         pos[i] = (float)(g_rawSamples[i].count - g_countAtGo) * METERS_PER_COUNT;
     }
 
     // --- Step 2: Median filter on position ---
     medianFilter(pos);
 
     // --- Step 3: Moving average on position ---
     movingAverage(pos);
 
     // --- Step 4: Velocity via central difference ---
     std::vector<float> vel(N);
     vel[0]     = (pos[1] - pos[0]) / dt;               // Forward difference
     vel[N - 1] = (pos[N - 1] - pos[N - 2]) / dt;       // Backward difference
     for (size_t i = 1; i < N - 1; i++) {
         vel[i] = (pos[i + 1] - pos[i - 1]) / dt2;      // Central difference
     }
 
     // --- Step 5: Acceleration via central difference on velocity ---
     std::vector<float> acc(N);
     acc[0]     = (vel[1] - vel[0]) / dt;
     acc[N - 1] = (vel[N - 1] - vel[N - 2]) / dt;
     for (size_t i = 1; i < N - 1; i++) {
         acc[i] = (vel[i + 1] - vel[i - 1]) / dt2;
     }
 
     // --- Build output ---
     g_processed.resize(N);
     for (size_t i = 0; i < N; i++) {
         float t_s = (float)(g_rawSamples[i].timestamp_us - g_rawSamples[0].timestamp_us) / 1e6f;
         g_processed[i].time_s       = t_s;
         g_processed[i].position_m   = pos[i];
         g_processed[i].velocity_mps = vel[i];
         g_processed[i].accel_mps2   = acc[i];
     }
 
     // Free raw buffer — no longer needed
     g_rawSamples.clear();
     g_rawSamples.shrink_to_fit();
 
     Serial.print("[PROC] Done. Output samples: ");
     Serial.println(N);
     return true;
 }
 
 // ============================================================================
 // SETUP
 // ============================================================================
 
 void setup() {
     Serial.begin(115200);
     while (!Serial) delay(10);
 
     Serial.println("============================================");
     Serial.println("QuickBurst BLE Encoder — Firmware");
     Serial.println("============================================");
     Serial.print("  Encoder CPR:       "); Serial.println(COUNTS_PER_REV);
     Serial.print("  Spool circumf:     "); Serial.print(SPOOL_CIRCUMF_M * 1000.0f, 3);
                                             Serial.println(" mm");
     Serial.print("  Meters/count:      "); Serial.println(METERS_PER_COUNT, 8);
     Serial.print("  Position quantum:  "); Serial.print(METERS_PER_COUNT * 1000.0f, 4);
                                             Serial.println(" mm");
     Serial.print("  Sample rate:       "); Serial.print(SAMPLE_HZ);
                                             Serial.println(" Hz");
     Serial.print("  Median window:     "); Serial.println(MEDIAN_WINDOW);
     Serial.print("  MA window:         "); Serial.println(MA_WINDOW);
     Serial.print("  Free heap:         "); Serial.print(ESP.getFreeHeap());
                                             Serial.println(" bytes");
     Serial.println("--------------------------------------------");
 
     setupPCNT();
     setupBLE();
 
     Serial.println("[READY] Waiting for BLE connection...");
 }
 
 // ============================================================================
 // MAIN LOOP — SINGLE-LOOP ARCHITECTURE
 // ============================================================================
 
 void loop() {
     uint32_t nowUs = micros();
 
     switch (g_state) {
 
         // ================================================================
         // IDLE: Do nothing. Commands handled in BLE callback.
         // ================================================================
         case State::IDLE:
             delay(10);  // Yield CPU, nothing time-critical here
             break;
 
         // ================================================================
         // ARMED: Waiting for GO. Commands handled in BLE callback.
         // ================================================================
         case State::ARMED:
             delay(10);
             break;
 
         // ================================================================
         // RUNNING: Sample encoder at deterministic interval.
         // ================================================================
         case State::RUNNING: {
             // Check for drill completion
             if (nowUs >= g_drillEndUs) {
                 Serial.print("[STATE] → PROCESSING (");
                 Serial.print(g_rawSamples.size());
                 Serial.println(" samples collected)");
                 g_state = State::PROCESSING;
                 bleSend("DONE\n");
                 break;
             }
 
             // Check for disconnect
             if (!g_bleConnected) {
                 g_state = State::IDLE;
                 g_rawSamples.clear();
                 Serial.println("[STATE] → IDLE (disconnect during run)");
                 break;
             }
 
             // Deterministic sampling: wait for next interval
             if ((int32_t)(nowUs - g_nextSampleUs) >= 0) {
                 RawSample s;
                 s.timestamp_us = nowUs;
                 s.count        = readEncoderCount();
                 g_rawSamples.push_back(s);
 
                 // Schedule next sample (absolute time to prevent drift)
                 g_nextSampleUs += SAMPLE_INTERVAL_US;
 
                 // If we've fallen behind by more than 2 intervals, resync
                 if ((int32_t)(nowUs - g_nextSampleUs) > (int32_t)(2 * SAMPLE_INTERVAL_US)) {
                     g_nextSampleUs = nowUs + SAMPLE_INTERVAL_US;
                 }
             }
             break;
         }
 
         // ================================================================
         // PROCESSING: Run smoothing + derivative pipeline.
         // ================================================================
         case State::PROCESSING: {
             bool ok = processData();
             if (ok) {
                 g_sendIndex = 0;
                 g_state = State::SENDING;
                 Serial.println("[STATE] → SENDING");
             } else {
                 bleSend("ERROR,PROCESSING_FAILED\n");
                 g_state = State::IDLE;
                 Serial.println("[STATE] → IDLE (processing failed)");
             }
             break;
         }
 
         // ================================================================
         // SENDING: Transmit processed data over BLE, paced.
         // ================================================================
         case State::SENDING: {
             if (!g_bleConnected) {
                 g_state = State::IDLE;
                 g_processed.clear();
                 Serial.println("[STATE] → IDLE (disconnect during send)");
                 break;
             }
 
             if (g_sendIndex < g_processed.size()) {
                 const ProcessedSample& s = g_processed[g_sendIndex];
 
                 // Compute time_ms as integer for compact BLE message
                 uint32_t time_ms = (uint32_t)(s.time_s * 1000.0f + 0.5f);
 
                 // Format: DATA,index,time_ms,position_m,velocity_mps,acceleration_mps2
                 char buf[128];
                 snprintf(buf, sizeof(buf), "DATA,%u,%u,%.5f,%.4f,%.3f\n",
                          (unsigned)g_sendIndex,
                          time_ms,
                          s.position_m,
                          s.velocity_mps,
                          s.accel_mps2);
                 bleSend(buf);
                 g_sendIndex++;
 
                 // Pace BLE notifications to avoid stack overflow
                 delay(BLE_TX_PACE_MS);
             } else {
                 bleSend("END\n");
                 Serial.print("[STATE] → IDLE (sent ");
                 Serial.print(g_processed.size());
                 Serial.println(" samples)");
                 g_processed.clear();
                 g_processed.shrink_to_fit();
                 g_state = State::IDLE;
             }
             break;
         }
     }
 }
 