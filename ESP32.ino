/*
 * Quikburst ESP32 Live Mode Firmware (Dual Core)
 *
 * Core 0: BLE server + protocol handling
 * Core 1: Motor control + encoder sampling
 *
 * Protocol (newline-delimited JSON over FFE0/FFE1):
 *   App -> ESP32:
 *     {"type":"liveStart","id":123,"direction":1,"countdownMs":3000,"dutyPercent":25}
 *     {"type":"liveMode","direction":1,"dutyPercent":30}
 *     {"type":"stop"}
 *
 *   ESP32 -> App:
 *     {"type":"connectionStatus","status":"ready"}
 *     {"type":"ack","id":123,"status":"countdownStarted","countdownMs":3000}
 *     {"type":"ack","id":123,"status":"liveStarted"}
 *     {"type":"dataStart","id":123,"samples":0}
 *     {"type":"metadata","countsPerRev":2400,"spoolRadiusM":0.003000,"sampleIntervalMs":10}
 *     {"type":"dataChunk","id":123,"start":0,"data":[...]}
 *     {"type":"dataEnd","id":123}
 *     {"type":"completion","id":123,"reason":"stopped"}
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

// BLE
#define SERVICE_UUID "FFE0"
#define CHARACTERISTIC_UUID "FFE1"
#define DEVICE_NAME "Quikburst"

BLEServer* gServer = NULL;
BLECharacteristic* gCharacteristic = NULL;
bool gDeviceConnected = false;
bool gOldDeviceConnected = false;

// Hardware
const int ENCODER_PIN_A = 12;
const int ENCODER_PIN_B = 13;
const int MOTOR_EN_PIN = 25;
const int MOTOR_IN1_PIN = 26;
const int MOTOR_IN2_PIN = 27;

// PWM
const int PWM_FREQ_HZ = 20000;
const int PWM_RES_BITS = 10;
const int PWM_MAX_DUTY = (1 << PWM_RES_BITS) - 1;
const ledc_channel_t PWM_CHANNEL = LEDC_CHANNEL_0;
const ledc_timer_t PWM_TIMER = LEDC_TIMER_0;

// Encoder
const int COUNTS_PER_REV = 2400;
const float SPOOL_RADIUS_M = 0.003f;
const float COUNTS_TO_DISTANCE_M = (2.0f * PI * SPOOL_RADIUS_M) / (float)COUNTS_PER_REV;
const unsigned long SAMPLE_INTERVAL_MS = 10;

// PCNT
const pcnt_unit_t PCNT_UNIT = PCNT_UNIT_0;
const int16_t PCNT_HIGH_LIMIT = 32767;
const int16_t PCNT_LOW_LIMIT = -32768;
volatile int32_t gOverflowCount = 0;

enum CommandType {
  CMD_NONE,
  CMD_LIVE_START,
  CMD_LIVE_UPDATE,
  CMD_STOP
};

typedef struct {
  CommandType type;
  uint32_t id;
  int direction;
  uint32_t countdownMs;
  float dutyPercent;
} MotorCommand;

typedef struct {
  uint32_t id;
  unsigned long timeMs;
  int32_t counts;
  bool isComplete;
  char reason[16];
} EncoderSample;

enum ControlEventType {
  EVT_NONE,
  EVT_COUNTDOWN_STARTED,
  EVT_LIVE_STARTED,
  EVT_STOPPED
};

typedef struct {
  ControlEventType type;
  uint32_t id;
  uint32_t countdownMs;
} ControlEvent;

QueueHandle_t gCommandQueue = NULL;
QueueHandle_t gDataQueue = NULL;
QueueHandle_t gEventQueue = NULL;

enum LiveState {
  LIVE_IDLE,
  LIVE_COUNTDOWN,
  LIVE_RUNNING
};

LiveState gLiveState = LIVE_IDLE;
uint32_t gCurrentLiveId = 0;
unsigned long gCountdownEndMs = 0;
unsigned long gRunStartMs = 0;
unsigned long gLastSampleMs = 0;
int32_t gFirstCounts = 0;
int gDirection = 1;
float gRequestedPercent = 0.0f;

String extractJSONValue(const String& json, const String& key) {
  int keyPos = json.indexOf("\"" + key + "\"");
  if (keyPos == -1) return "";

  int colonPos = json.indexOf(':', keyPos);
  if (colonPos == -1) return "";

  int startPos = colonPos + 1;
  while (startPos < json.length() && (json[startPos] == ' ' || json[startPos] == '\t')) {
    startPos++;
  }
  if (startPos >= json.length()) return "";

  int endPos = startPos;
  if (json[startPos] == '"') {
    startPos++;
    endPos = json.indexOf('"', startPos);
  } else {
    while (endPos < json.length() &&
           (json[endPos] == '-' || json[endPos] == '.' || (json[endPos] >= '0' && json[endPos] <= '9'))) {
      endPos++;
    }
  }

  if (endPos > startPos && endPos <= json.length()) {
    return json.substring(startPos, endPos);
  }
  return "";
}

void sendBLEMessage(String message) {
  if (!gDeviceConnected || gCharacteristic == NULL) return;
  if (!message.endsWith("\n")) {
    message += "\n";
  }
  gCharacteristic->setValue(message.c_str());
  gCharacteristic->notify();
}

void sendAck(uint32_t id, const String& status, uint32_t countdownMs = 0) {
  String payload = "{\"type\":\"ack\",\"id\":" + String(id) + ",\"status\":\"" + status + "\"";
  if (countdownMs > 0) {
    payload += ",\"countdownMs\":" + String(countdownMs);
  }
  payload += "}";
  sendBLEMessage(payload);
}

void IRAM_ATTR pcntOverflowISR(void* arg) {
  uint32_t status = 0;
  pcnt_get_event_status(PCNT_UNIT, &status);
  if (status & PCNT_EVT_H_LIM) {
    gOverflowCount += PCNT_HIGH_LIMIT;
  }
  if (status & PCNT_EVT_L_LIM) {
    gOverflowCount += PCNT_LOW_LIMIT;
  }
}

void setupPCNT() {
  pcnt_config_t config = {
    .pulse_gpio_num = ENCODER_PIN_A,
    .ctrl_gpio_num = ENCODER_PIN_B,
    .lctrl_mode = PCNT_MODE_REVERSE,
    .hctrl_mode = PCNT_MODE_KEEP,
    .pos_mode = PCNT_COUNT_INC,
    .neg_mode = PCNT_COUNT_DEC,
    .counter_h_lim = PCNT_HIGH_LIMIT,
    .counter_l_lim = PCNT_LOW_LIMIT,
    .unit = PCNT_UNIT,
    .channel = PCNT_CHANNEL_0
  };
  pcnt_unit_config(&config);

  pcnt_config_t config2 = {
    .pulse_gpio_num = ENCODER_PIN_B,
    .ctrl_gpio_num = ENCODER_PIN_A,
    .lctrl_mode = PCNT_MODE_KEEP,
    .hctrl_mode = PCNT_MODE_REVERSE,
    .pos_mode = PCNT_COUNT_INC,
    .neg_mode = PCNT_COUNT_DEC,
    .counter_h_lim = PCNT_HIGH_LIMIT,
    .counter_l_lim = PCNT_LOW_LIMIT,
    .unit = PCNT_UNIT,
    .channel = PCNT_CHANNEL_1
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
  return gOverflowCount + count16;
}

void resetEncoder() {
  pcnt_counter_pause(PCNT_UNIT);
  pcnt_counter_clear(PCNT_UNIT);
  gOverflowCount = 0;
  pcnt_counter_resume(PCNT_UNIT);
}

void setupMotor() {
  pinMode(MOTOR_IN1_PIN, OUTPUT);
  pinMode(MOTOR_IN2_PIN, OUTPUT);
  pinMode(MOTOR_EN_PIN, OUTPUT);

  digitalWrite(MOTOR_IN1_PIN, LOW);
  digitalWrite(MOTOR_IN2_PIN, LOW);
  digitalWrite(MOTOR_EN_PIN, LOW);

  ledc_timer_config_t timerConf = {
    .speed_mode = LEDC_LOW_SPEED_MODE,
    .duty_resolution = (ledc_timer_bit_t)PWM_RES_BITS,
    .timer_num = PWM_TIMER,
    .freq_hz = PWM_FREQ_HZ,
    .clk_cfg = LEDC_AUTO_CLK
  };
  ledc_timer_config(&timerConf);

  ledc_channel_config_t channelConf = {};
  channelConf.gpio_num = MOTOR_EN_PIN;
  channelConf.speed_mode = LEDC_LOW_SPEED_MODE;
  channelConf.channel = PWM_CHANNEL;
  channelConf.intr_type = LEDC_INTR_DISABLE;
  channelConf.timer_sel = PWM_TIMER;
  channelConf.duty = 0;
  channelConf.hpoint = 0;
  ledc_channel_config(&channelConf);
}

void setDirection(int dir) {
  gDirection = (dir > 0) ? 1 : -1;
  if (gDirection > 0) {
    digitalWrite(MOTOR_IN1_PIN, HIGH);
    digitalWrite(MOTOR_IN2_PIN, LOW);
  } else {
    digitalWrite(MOTOR_IN1_PIN, LOW);
    digitalWrite(MOTOR_IN2_PIN, HIGH);
  }
}

void setDutyPercentFlipped(float requestedPercent) {
  if (requestedPercent < 0.0f) requestedPercent = 0.0f;
  if (requestedPercent > 100.0f) requestedPercent = 100.0f;

  gRequestedPercent = requestedPercent;
  float hwPercent = 100.0f - requestedPercent;
  uint32_t dutyValue = (uint32_t)((hwPercent / 100.0f) * (float)PWM_MAX_DUTY);
  ledc_set_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL, dutyValue);
  ledc_update_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL);
}

void stopMotor() {
  ledc_set_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL, 0);
  ledc_update_duty(LEDC_LOW_SPEED_MODE, PWM_CHANNEL);
  digitalWrite(MOTOR_IN1_PIN, LOW);
  digitalWrite(MOTOR_IN2_PIN, LOW);
  gRequestedPercent = 0.0f;
}

void publishControlEvent(ControlEventType type, uint32_t id, uint32_t countdownMs = 0) {
  ControlEvent evt;
  evt.type = type;
  evt.id = id;
  evt.countdownMs = countdownMs;
  xQueueSend(gEventQueue, &evt, 0);
}

void publishCompletion(const char* reason) {
  EncoderSample sample;
  sample.id = gCurrentLiveId;
  sample.timeMs = 0;
  sample.counts = 0;
  sample.isComplete = true;
  strncpy(sample.reason, reason, sizeof(sample.reason) - 1);
  sample.reason[sizeof(sample.reason) - 1] = '\0';
  xQueueSend(gDataQueue, &sample, portMAX_DELAY);
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    gDeviceConnected = true;
    BLEDevice::setMTU(512);
    sendBLEMessage("{\"type\":\"connectionStatus\",\"status\":\"ready\"}");
  }

  void onDisconnect(BLEServer* server) override {
    gDeviceConnected = false;
  }
};

class CharacteristicCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String value = characteristic->getValue();
    if (value.length() == 0) return;
    value.trim();
    if (!value.startsWith("{")) return;

    String type = extractJSONValue(value, "type");
    MotorCommand cmd;
    cmd.type = CMD_NONE;
    cmd.id = 0;
    cmd.direction = 1;
    cmd.countdownMs = 0;
    cmd.dutyPercent = 0.0f;

    if (type == "liveStart") {
      String idStr = extractJSONValue(value, "id");
      String dirStr = extractJSONValue(value, "direction");
      String countdownStr = extractJSONValue(value, "countdownMs");
      String dutyStr = extractJSONValue(value, "dutyPercent");

      if (idStr.length() > 0 && dutyStr.length() > 0) {
        cmd.type = CMD_LIVE_START;
        cmd.id = (uint32_t)idStr.toInt();
        cmd.direction = (dirStr.toInt() > 0) ? 1 : -1;
        cmd.countdownMs = (countdownStr.length() > 0) ? (uint32_t)countdownStr.toInt() : 3000;
        cmd.dutyPercent = constrain(dutyStr.toFloat(), 0.0f, 100.0f);
      }
    } else if (type == "liveMode") {
      String dirStr = extractJSONValue(value, "direction");
      String dutyStr = extractJSONValue(value, "dutyPercent");
      if (dutyStr.length() > 0) {
        cmd.type = CMD_LIVE_UPDATE;
        cmd.direction = (dirStr.toInt() > 0) ? 1 : -1;
        cmd.dutyPercent = constrain(dutyStr.toFloat(), 0.0f, 100.0f);
      }
    } else if (type == "stop") {
      cmd.type = CMD_STOP;
    }

    if (cmd.type != CMD_NONE) {
      xQueueSend(gCommandQueue, &cmd, portMAX_DELAY);
      if (cmd.type == CMD_LIVE_START) {
        sendAck(cmd.id, "startRequested");
      } else if (cmd.type == CMD_STOP) {
        sendBLEMessage("{\"type\":\"ack\",\"status\":\"stopRequested\"}");
      }
    }
  }
};

void motorControlTask(void* pvParameters) {
  setupMotor();
  setupPCNT();

  MotorCommand cmd;
  while (1) {
    if (xQueueReceive(gCommandQueue, &cmd, 0) == pdTRUE) {
      if (cmd.type == CMD_LIVE_START) {
        stopMotor();
        resetEncoder();
        setDirection(cmd.direction);

        gCurrentLiveId = cmd.id;
        gCountdownEndMs = millis() + cmd.countdownMs;
        gLiveState = LIVE_COUNTDOWN;
        gRequestedPercent = cmd.dutyPercent;
        publishControlEvent(EVT_COUNTDOWN_STARTED, gCurrentLiveId, cmd.countdownMs);
      } else if (cmd.type == CMD_LIVE_UPDATE) {
        setDirection(cmd.direction);
        gRequestedPercent = cmd.dutyPercent;
        if (gLiveState == LIVE_RUNNING) {
          setDutyPercentFlipped(gRequestedPercent);
        }
      } else if (cmd.type == CMD_STOP) {
        bool wasRunning = (gLiveState == LIVE_RUNNING);
        gLiveState = LIVE_IDLE;
        stopMotor();
        publishControlEvent(EVT_STOPPED, gCurrentLiveId, 0);
        if (wasRunning && gCurrentLiveId != 0) {
          publishCompletion("stopped");
        }
        gCurrentLiveId = 0;
      }
    }

    unsigned long nowMs = millis();
    if (gLiveState == LIVE_COUNTDOWN && nowMs >= gCountdownEndMs) {
      gRunStartMs = nowMs;
      gLastSampleMs = 0;
      gFirstCounts = readEncoderCount();
      setDutyPercentFlipped(gRequestedPercent);
      gLiveState = LIVE_RUNNING;
      publishControlEvent(EVT_LIVE_STARTED, gCurrentLiveId, 0);
    }

    if (gLiveState == LIVE_RUNNING && nowMs - gLastSampleMs >= SAMPLE_INTERVAL_MS) {
      gLastSampleMs = nowMs;
      EncoderSample sample;
      sample.id = gCurrentLiveId;
      sample.timeMs = nowMs - gRunStartMs;
      sample.counts = readEncoderCount();
      sample.isComplete = false;
      sample.reason[0] = '\0';
      xQueueSend(gDataQueue, &sample, 0);
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void bluetoothTask(void* pvParameters) {
  BLEDevice::init(DEVICE_NAME);

  gServer = BLEDevice::createServer();
  gServer->setCallbacks(new ServerCallbacks());

  BLEService* service = gServer->createService(BLEUUID(SERVICE_UUID));
  gCharacteristic = service->createCharacteristic(
    BLEUUID(CHARACTERISTIC_UUID),
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY |
    BLECharacteristic::PROPERTY_WRITE
  );
  gCharacteristic->addDescriptor(new BLE2902());
  gCharacteristic->setCallbacks(new CharacteristicCallbacks());
  gCharacteristic->setValue("Ready");

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLEUUID(SERVICE_UUID));
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  bool streamOpen = false;
  uint32_t streamId = 0;
  int sampleIndex = 0;
  int32_t firstCountsInStream = 0;
  unsigned long prevTime = 0;
  int32_t prevCounts = 0;
  float prevVelocity = 0.0f;

  while (1) {
    if (!gDeviceConnected && gOldDeviceConnected) {
      delay(300);
      gServer->startAdvertising();
      gOldDeviceConnected = gDeviceConnected;
    }
    if (gDeviceConnected && !gOldDeviceConnected) {
      gOldDeviceConnected = gDeviceConnected;
    }

    ControlEvent evt;
    if (xQueueReceive(gEventQueue, &evt, 0) == pdTRUE) {
      if (evt.type == EVT_COUNTDOWN_STARTED) {
        sendAck(evt.id, "countdownStarted", evt.countdownMs);
      } else if (evt.type == EVT_LIVE_STARTED) {
        sendAck(evt.id, "liveStarted");
      } else if (evt.type == EVT_STOPPED) {
        if (evt.id != 0) {
          sendAck(evt.id, "stopped");
        } else {
          sendBLEMessage("{\"type\":\"ack\",\"status\":\"stopped\"}");
        }
      }
    }

    EncoderSample sample;
    if (xQueueReceive(gDataQueue, &sample, pdMS_TO_TICKS(10)) == pdTRUE) {
      if (sample.isComplete) {
        if (streamOpen) {
          sendBLEMessage("{\"type\":\"dataEnd\",\"id\":" + String(streamId) + "}");
          sendBLEMessage("{\"type\":\"completion\",\"id\":" + String(streamId) + ",\"reason\":\"" + String(sample.reason) + "\"}");
        }
        streamOpen = false;
        streamId = 0;
        sampleIndex = 0;
        firstCountsInStream = 0;
        prevTime = 0;
        prevCounts = 0;
        prevVelocity = 0.0f;
      } else {
        if (!streamOpen) {
          streamOpen = true;
          streamId = sample.id;
          sampleIndex = 0;
          firstCountsInStream = sample.counts;
          prevTime = sample.timeMs;
          prevCounts = sample.counts;
          prevVelocity = 0.0f;
          sendBLEMessage("{\"type\":\"dataStart\",\"id\":" + String(streamId) + ",\"samples\":0}");
          sendBLEMessage("{\"type\":\"metadata\",\"countsPerRev\":" + String(COUNTS_PER_REV) +
                         ",\"spoolRadiusM\":" + String(SPOOL_RADIUS_M, 6) +
                         ",\"sampleIntervalMs\":" + String(SAMPLE_INTERVAL_MS) + "}");
        }

        int32_t relativeCounts = sample.counts - firstCountsInStream;
        float position = (float)relativeCounts * COUNTS_TO_DISTANCE_M;
        float velocity = 0.0f;
        float rpm = 0.0f;
        float acceleration = 0.0f;

        if (sampleIndex > 0) {
          int32_t deltaCounts = sample.counts - prevCounts;
          unsigned long deltaMs = sample.timeMs - prevTime;
          if (deltaMs > 0) {
            float dt = (float)deltaMs / 1000.0f;
            velocity = ((float)deltaCounts * COUNTS_TO_DISTANCE_M) / dt;
            rpm = ((float)deltaCounts / dt) * (60.0f / (float)COUNTS_PER_REV);
            if (sampleIndex > 1) {
              acceleration = (velocity - prevVelocity) / dt;
            }
          }
        }

        String chunk = "{\"type\":\"dataChunk\",\"id\":" + String(streamId) +
                       ",\"start\":" + String(sampleIndex) +
                       ",\"data\":[{\"t\":" + String(sample.timeMs) +
                       ",\"counts\":" + String(relativeCounts) +
                       ",\"position\":" + String(position, 4) +
                       ",\"velocity\":" + String(velocity, 4) +
                       ",\"rpm\":" + String(rpm, 3) +
                       ",\"acceleration\":" + String(acceleration, 4) + "}]}";
        sendBLEMessage(chunk);

        sampleIndex++;
        prevTime = sample.timeMs;
        prevCounts = sample.counts;
        prevVelocity = velocity;
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void setup() {
  Serial.begin(115200);
  delay(400);

  gCommandQueue = xQueueCreate(20, sizeof(MotorCommand));
  gDataQueue = xQueueCreate(150, sizeof(EncoderSample));
  gEventQueue = xQueueCreate(30, sizeof(ControlEvent));

  if (gCommandQueue == NULL || gDataQueue == NULL || gEventQueue == NULL) {
    Serial.println("Queue init failed");
    while (1) {
      delay(1000);
    }
  }

  xTaskCreatePinnedToCore(
    bluetoothTask,
    "BluetoothTask",
    8192,
    NULL,
    2,
    NULL,
    0
  );

  xTaskCreatePinnedToCore(
    motorControlTask,
    "MotorControlTask",
    8192,
    NULL,
    2,
    NULL,
    1
  );

  Serial.println("Quikburst Live Mode firmware started (dual-core)");
}

void loop() {
  vTaskDelay(pdMS_TO_TICKS(1000));
}
 