// dorm lock esp32 - BLE version (wip)
// the mac does all the internet stuff now and talks to this over bluetooth.
// no wifi, no tls, no worker secret on the board.
// cmds have to be signed (hmac w/ BLE_KEY + a nonce that changes every time),
// otherwise anyone in bluetooth range could unlock the door with a phone app
// board: ESP32 Dev Module. serial 9600. servo on gpio 13, same wiring as before
// if it says sketch too big: Tools > Partition Scheme > Huge APP

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "mbedtls/md.h"
#include "esp_random.h"
#include "secrets.h"  // BLE_KEY_HEX, copy secrets.example.h

// has to match bridge.py
#define BLE_NAME    "dorm-lock"
#define SVC_UUID    "7a1c0001-5e2b-4d8f-9c3a-1b6e2f4d8a90"
#define NONCE_UUID  "7a1c0002-5e2b-4d8f-9c3a-1b6e2f4d8a90"
#define CMD_UUID    "7a1c0003-5e2b-4d8f-9c3a-1b6e2f4d8a90"
#define STATUS_UUID "7a1c0004-5e2b-4d8f-9c3a-1b6e2f4d8a90"

// still not calibrated, guesses
static int ANGLE_LOCKED   = 20;
static int ANGLE_UNLOCKED = 110;

// 1 = no bluetooth, type angles into serial to find the positions
#define CALIBRATE_MODE 0

static const int SERVO_PIN      = 13;
static const int SERVO_FREQ_HZ  = 50;
static const int SERVO_RES_BITS = 16;
static const int PULSE_MIN_US   = 500;
static const int PULSE_MAX_US   = 2500;
static const uint32_t PERIOD_US = 1000000UL / SERVO_FREQ_HZ;
static const uint32_t SERVO_TRAVEL_MS = 800;

static uint32_t angleToDuty(int angle) {
  if (angle < 0) angle = 0;
  if (angle > 180) angle = 180;
  uint32_t us = PULSE_MIN_US + ((uint32_t)(PULSE_MAX_US - PULSE_MIN_US) * (uint32_t)angle) / 180;
  uint32_t fullScale = (1UL << SERVO_RES_BITS) - 1;
  return (uint32_t)(((uint64_t)us * fullScale) / PERIOD_US);
}

static void servoBegin() {
  ledcAttach(SERVO_PIN, SERVO_FREQ_HZ, SERVO_RES_BITS);
  ledcWrite(SERVO_PIN, 0);
}

static void servoGoTo(int angle) {
  ledcWrite(SERVO_PIN, angleToDuty(angle));
  delay(SERVO_TRAVEL_MS);
  ledcWrite(SERVO_PIN, 0);  // go limp so the lock still turns by hand
}

#if !CALIBRATE_MODE

static uint8_t bleKey[32];
static uint8_t nonce[16];
static BLECharacteristic* nonceCh;
static BLECharacteristic* statusCh;

// the BLE callback runs on the bluetooth task, so it just stashes the cmd
// and loop() does the actual servo move
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool havePending = false;
static char pendingBuf[128];

static bool parseKey() {
  if (strlen(BLE_KEY_HEX) != 64) return false;
  for (int i = 0; i < 32; i++) {
    char hx[3] = { BLE_KEY_HEX[2 * i], BLE_KEY_HEX[2 * i + 1], 0 };
    bleKey[i] = (uint8_t)strtol(hx, nullptr, 16);
  }
  return true;
}

static void newNonce() {
  esp_fill_random(nonce, sizeof(nonce));
  nonceCh->setValue(nonce, sizeof(nonce));
}

// hmac-sha256(key, nonce + msg) has to match the hex the mac sent
static bool sigOk(const String& msg, const String& sigHex) {
  if (sigHex.length() != 64) return false;
  uint8_t out[32];
  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 1);
  mbedtls_md_hmac_starts(&ctx, bleKey, sizeof(bleKey));
  mbedtls_md_hmac_update(&ctx, nonce, sizeof(nonce));
  mbedtls_md_hmac_update(&ctx, (const uint8_t*)msg.c_str(), msg.length());
  mbedtls_md_hmac_finish(&ctx, out);
  mbedtls_md_free(&ctx);

  uint8_t diff = 0;  // no early exit
  for (int i = 0; i < 32; i++) {
    char hx[3] = { sigHex[2 * i], sigHex[2 * i + 1], 0 };
    diff |= out[i] ^ (uint8_t)strtol(hx, nullptr, 16);
  }
  return diff == 0;
}

static void sendStatus(const String& s) {
  statusCh->setValue((uint8_t*)s.c_str(), s.length());
  statusCh->notify();
}

class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    Serial.println("[ble] mac connected");
  }
  void onDisconnect(BLEServer* s) override {
    Serial.println("[ble] disconnected, advertising again");
    BLEDevice::startAdvertising();
  }
};

class CmdCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = String(c->getValue().c_str());
    portENTER_CRITICAL(&mux);
    if (!havePending) {
      strncpy(pendingBuf, v.c_str(), sizeof(pendingBuf) - 1);
      pendingBuf[sizeof(pendingBuf) - 1] = 0;
      havePending = true;
    }
    portEXIT_CRITICAL(&mux);
  }
};

#endif

void setup() {
  Serial.begin(9600);
  delay(500);
  Serial.println();
  Serial.println("=== dorm-lock (ble) ===");
  servoBegin();

#if CALIBRATE_MODE
  Serial.println("CALIBRATE MODE - type an angle 0-180 and press Enter.");
#else
  if (!parseKey()) {
    Serial.println("BLE_KEY_HEX in secrets.h has to be 64 hex chars. stopping.");
    while (true) delay(1000);
  }

  BLEDevice::init(BLE_NAME);
  BLEServer* srv = BLEDevice::createServer();
  srv->setCallbacks(new ServerCb());
  BLEService* svc = srv->createService(SVC_UUID);

  nonceCh = svc->createCharacteristic(NONCE_UUID, BLECharacteristic::PROPERTY_READ);
  BLECharacteristic* cmdCh = svc->createCharacteristic(CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
  cmdCh->setCallbacks(new CmdCb());
  statusCh = svc->createCharacteristic(STATUS_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  statusCh->addDescriptor(new BLE2902());  // if this errors on a newer core just delete the line

  newNonce();
  svc->start();
  BLEDevice::startAdvertising();
  Serial.println("[ble] advertising as " BLE_NAME ", waiting for the mac");
#endif
}

#if CALIBRATE_MODE

void loop() {
  if (!Serial.available()) return;
  String line = Serial.readStringUntil('\n');
  line.trim();
  if (!line.length()) return;
  int angle = line.toInt();
  Serial.printf("-> %d deg\n", angle);
  servoGoTo(angle);
}

#else

void loop() {
  if (!havePending) {
    delay(10);
    return;
  }
  char raw[sizeof(pendingBuf)];
  portENTER_CRITICAL(&mux);
  memcpy(raw, pendingBuf, sizeof(raw));
  havePending = false;
  portEXIT_CRITICAL(&mux);

  // U|<id>|<sig>  or  L|<id>|<sig>
  String s(raw);
  int p1 = s.indexOf('|');
  int p2 = s.indexOf('|', p1 + 1);
  if (p1 != 1 || p2 < 0) {
    newNonce();
    sendStatus("err|?|bad_format");
    return;
  }
  char letter = s[0];
  String id = s.substring(p1 + 1, p2);
  bool ok = sigOk(s.substring(0, p2), s.substring(p2 + 1));
  newNonce();  // burn it either way

  if (!ok || (letter != 'U' && letter != 'L')) {
    Serial.println("[ble] rejected a cmd (bad signature)");
    sendStatus("err|" + id + "|bad_auth");
    return;
  }

  const char* state = (letter == 'U') ? "unlocked" : "locked";
  Serial.printf("[cmd] #%s -> %s\n", id.c_str(), state);
  servoGoTo(letter == 'U' ? ANGLE_UNLOCKED : ANGLE_LOCKED);
  sendStatus("ok|" + id + "|" + state);
}

#endif
