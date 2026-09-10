// dorm lock esp32 firmware (wip)
// long polls the worker, moves the servo, confirms back
// board: ESP32 Dev Module. serial is 9600 (ide wont let me change the baud)
// wiring: servo red/brown -> 5v supply +/-, orange -> gpio 13, supply - to esp GND
// no extra libraries

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "esp_task_wdt.h"

// wifi + worker host + secret are in secrets.h (gitignored), copy secrets.example.h
#include "secrets.h"

// servo angles. NOT calibrated yet, these are guesses
static int ANGLE_LOCKED   = 20;
static int ANGLE_UNLOCKED = 110;

// 1 = no wifi, type angles into serial to find the lock/unlock positions
#define CALIBRATE_MODE 0

static const int SERVO_PIN       = 13;
static const int SERVO_FREQ_HZ   = 50;
static const int SERVO_RES_BITS  = 16;
static const int PULSE_MIN_US    = 500;   // 0 deg
static const int PULSE_MAX_US    = 2500;  // 180
static const uint32_t PERIOD_US  = 1000000UL / SERVO_FREQ_HZ;  // 20000

static const uint32_t SERVO_TRAVEL_MS = 800; // guess, tune once its on the lock

// shorter polls bc the wifi here is like -85 and the 25s ones kept hanging.
// more requests but still way under the free tier
static const uint32_t POLL_WAIT_MS    = 8000;
static const uint16_t POLL_HTTP_MS    = 15000;   // has to be > POLL_WAIT_MS

// watchdog - if a request hangs forever the board just reboots
static const uint32_t WDT_TIMEOUT_MS  = 40000;

static const int FAILS_BEFORE_RECONNECT = 4;
static const int FAILS_BEFORE_REBOOT    = 10;

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

  // stop pulsing so the servo goes limp -> can still turn the lock by hand
  ledcWrite(SERVO_PIN, 0);
}

// GTS Root R4, what workers.dev uses rn (valid till 2028). pinned so nobody on
// the dorm wifi can MITM the secret. if everything starts failing with -1 check
// if cloudflare changed CA:
//   openssl s_client -connect dorm-lock.your-subdomain.workers.dev:443 -showcerts
static const char* ROOT_CA = R"CERT(
-----BEGIN CERTIFICATE-----
MIIDejCCAmKgAwIBAgIQf+UwvzMTQ77dghYQST2KGzANBgkqhkiG9w0BAQsFADBX
MQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFsU2lnbiBudi1zYTEQMA4GA1UE
CxMHUm9vdCBDQTEbMBkGA1UEAxMSR2xvYmFsU2lnbiBSb290IENBMB4XDTIzMTEx
NTAzNDMyMVoXDTI4MDEyODAwMDA0MlowRzELMAkGA1UEBhMCVVMxIjAgBgNVBAoT
GUdvb2dsZSBUcnVzdCBTZXJ2aWNlcyBMTEMxFDASBgNVBAMTC0dUUyBSb290IFI0
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE83Rzp2iLYK5DuDXFgTB7S0md+8Fhzube
Rr1r1WEYNa5A3XP3iZEwWus87oV8okB2O6nGuEfYKueSkWpz6bFyOZ8pn6KY019e
WIZlD6GEZQbR3IvJx3PIjGov5cSr0R2Ko4H/MIH8MA4GA1UdDwEB/wQEAwIBhjAd
BgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwDwYDVR0TAQH/BAUwAwEB/zAd
BgNVHQ4EFgQUgEzW63T/STaj1dj8tT7FavCUHYwwHwYDVR0jBBgwFoAUYHtmGkUN
l8qJUC99BM00qP/8/UswNgYIKwYBBQUHAQEEKjAoMCYGCCsGAQUFBzAChhpodHRw
Oi8vaS5wa2kuZ29vZy9nc3IxLmNydDAtBgNVHR8EJjAkMCKgIKAehhxodHRwOi8v
Yy5wa2kuZ29vZy9yL2dzcjEuY3JsMBMGA1UdIAQMMAowCAYGZ4EMAQIBMA0GCSqG
SIb3DQEBCwUAA4IBAQAYQrsPBtYDh5bjP2OBDwmkoWhIDDkic574y04tfzHpn+cJ
odI2D4SseesQ6bDrarZ7C30ddLibZatoKiws3UL9xnELz4ct92vID24FfVbiI1hY
+SW6FoVHkNeWIP0GCbaM4C6uVdF5dTUsMVs/ZbzNnIdCp5Gxmx5ejvEau8otR/Cs
kGN+hr/W5GvT1tMBjgWKZ1i4//emhA1JG1BbPzoLJQvyEotc03lXjTaCzv8mEbep
8RqZ7a2CPsgRbuvTPBwcOMBBmuFeU88+FSBX6+7iP0il8b4Z0QFqIwwMHfs/L6K1
vepuoxtGzi4CZ68zJpiq1UvSqTbFJjtbD4seiMHl
-----END CERTIFICATE-----
)CERT";

static WiFiClientSecure tls;
static HTTPClient http;

// ---- wifi ----

// signal is bad here, the handshake fails a few times (reason 15) before it
// connects. just keep retrying
static bool wifiConnect(uint32_t perAttemptMs = 12000, int attempts = 8) {
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);                      // helps w/ weak signal
  WiFi.setTxPower(WIFI_POWER_19_5dBm);
  WiFi.setAutoReconnect(true);

  for (int a = 1; a <= attempts; a++) {
    Serial.printf("[wifi] attempt %d/%d -> %s\n", a, attempts, WIFI_SSID);
    WiFi.disconnect(true, true);
    delay(300);
    WiFi.begin(WIFI_SSID, WIFI_PASS);

    uint32_t start = millis();
    while (millis() - start < perAttemptMs) {
      if (WiFi.status() == WL_CONNECTED) {
        Serial.printf("[wifi] up: ip=%s rssi=%d dBm\n",
                      WiFi.localIP().toString().c_str(), WiFi.RSSI());
        return true;
      }
      delay(200);
    }
    Serial.println("[wifi] timed out (handshake timeouts are expected here, retrying)");
  }
  Serial.println("[wifi] all attempts failed");
  return false;
}

static void httpInit() {
  tls.setCACert(ROOT_CA);
  tls.setTimeout(20);      // seconds
  http.setReuse(true);     // reuse the connection, handshakes are slow on this wifi
  http.setConnectTimeout(8000);
}

static int httpGet(const String& path, String& out, uint16_t timeoutMs) {
  String url = String("https://") + HOST + path;
  if (!http.begin(tls, url)) return -1;
  http.addHeader("X-Lock-Secret", SECRET);
  http.setTimeout(timeoutMs);   // ms here, not seconds like tls.setTimeout. fun
  int code = http.GET();
  if (code > 0) out = http.getString();
  http.end();
  if (code <= 0) tls.stop(); // only reset the connection if it failed
  return code;
}

static int httpPostJson(const String& path, const String& json, String& out, uint16_t timeoutMs) {
  String url = String("https://") + HOST + path;
  if (!http.begin(tls, url)) return -1;
  http.addHeader("X-Lock-Secret", SECRET);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(timeoutMs);
  int code = http.POST(json);
  if (code > 0) out = http.getString();
  http.end();
  if (code <= 0) tls.stop();
  return code;
}

// janky json parsing. the responses are always the same shape so no library

static String jsonStr(const String& body, const char* key) {
  String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return "";
  int c = body.indexOf(':', k + needle.length());
  if (c < 0) return "";
  int q1 = body.indexOf('"', c);
  if (q1 < 0) return "";
  int q2 = body.indexOf('"', q1 + 1);
  if (q2 < 0) return "";
  return body.substring(q1 + 1, q2);
}

static long jsonNum(const String& body, const char* key, long fallback) {
  String needle = String("\"") + key + "\"";
  int k = body.indexOf(needle);
  if (k < 0) return fallback;
  int c = body.indexOf(':', k + needle.length());
  if (c < 0) return fallback;
  int i = c + 1;
  while (i < (int)body.length() && body[i] == ' ') i++;
  int start = i;
  if (i < (int)body.length() && body[i] == '-') i++;
  while (i < (int)body.length() && isdigit((unsigned char)body[i])) i++;
  if (i == start) return fallback;
  return body.substring(start, i).toInt();
}

static long   lastSeenId  = 0;         // last cmd id we confirmed
static String doorState   = "locked";
static uint32_t pollCount = 0;

static void applyState(const String& state) {
  servoGoTo(state == "unlocked" ? ANGLE_UNLOCKED : ANGLE_LOCKED);
  doorState = state;
}

// on boot match whatever the worker says, so a reboot doesnt redo old commands
static void bootSync() {
  String body;
  int code = httpGet("/state", body, 15000);
  if (code != 200) {
    Serial.printf("[boot] /state http=%d — starting from id 0\n", code);
    return;
  }
  String st = jsonStr(body, "state");
  long confirmed = jsonNum(body, "lastConfirmedId", 0);
  if (st.length()) {
    Serial.printf("[boot] worker says '%s', lastConfirmedId=%ld\n", st.c_str(), confirmed);
    applyState(st);
  }
  lastSeenId = confirmed;
}

static bool confirmCommand(long id, const String& state, bool ok, const char* detail) {
  String json = String("{\"commandId\":") + id +
                ",\"ok\":" + (ok ? "true" : "false") +
                ",\"state\":\"" + state + "\"";
  if (detail) json += String(",\"detail\":\"") + detail + "\"";
  json += "}";

  // retry a bunch, repeats are fine on the worker side
  for (int attempt = 1; attempt <= 5; attempt++) {
    String body;
    int code = httpPostJson("/confirm", json, body, 15000);
    if (code == 200) {
      Serial.printf("[confirm] #%ld -> %s\n", id, jsonStr(body, "status").c_str());
      return true;
    }
    Serial.printf("[confirm] attempt %d http=%d\n", attempt, code);
    delay(1000UL * attempt);
  }
  return false;
}

void setup() {
  Serial.begin(9600);
  delay(500);
  Serial.println();
  Serial.println("=== dorm-lock ===");

  servoBegin();

#if !CALIBRATE_MODE
  // watchdog first, before any network stuff
  esp_task_wdt_config_t wdtCfg = {
    .timeout_ms = WDT_TIMEOUT_MS,
    .idle_core_mask = 0,
    .trigger_panic = true,
  };
  if (esp_task_wdt_init(&wdtCfg) == ESP_ERR_INVALID_STATE) {
    esp_task_wdt_reconfigure(&wdtCfg);   // already running
  }
  esp_task_wdt_add(NULL);
  Serial.printf("[boot] watchdog armed at %lums\n", (unsigned long)WDT_TIMEOUT_MS);
#endif

#if CALIBRATE_MODE
  Serial.println("CALIBRATE MODE — WiFi is off.");
  Serial.println("Type an angle 0-180 and press Enter. Note the two that line up");
  Serial.println("with locked and unlocked, then put them in ANGLE_LOCKED /");
  Serial.println("ANGLE_UNLOCKED and set CALIBRATE_MODE back to 0.");
  Serial.println("Do this BEFORE coupling the servo to the thumb-turn.");
#else
  if (!wifiConnect()) {
    Serial.println("[boot] no WiFi. Restarting in 10s.");
    delay(10000);
    ESP.restart();
  }
  httpInit();
  bootSync();
  Serial.println("[boot] entering long-poll loop");
#endif
}

// ========== loop ==========

#if CALIBRATE_MODE

void loop() {
  if (!Serial.available()) return;
  String line = Serial.readStringUntil('\n');
  line.trim();
  if (!line.length()) return;
  int angle = line.toInt();
  Serial.printf("-> %d deg (pulse %lu us)\n", angle,
                (unsigned long)(PULSE_MIN_US + ((PULSE_MAX_US - PULSE_MIN_US) * (long)angle) / 180));
  servoGoTo(angle);
}

#else

static int consecutiveFails = 0;

void loop() {
  esp_task_wdt_reset();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[wifi] dropped, reconnecting");
    if (!wifiConnect()) { delay(5000); return; }
    httpInit();
    bootSync();
    return;
  }

  // 8s polls now. havent confirmed on the board that this fixes the hanging yet
  Serial.printf("[poll] #%lu after=%ld rssi=%d dBm heap=%u door=%s ... ",
                (unsigned long)(++pollCount), lastSeenId, WiFi.RSSI(),
                (unsigned)ESP.getFreeHeap(), doorState.c_str());
  uint32_t t0 = millis();

  String body;
  int code = httpGet("/poll?after=" + String(lastSeenId) +
                     "&wait=" + String(POLL_WAIT_MS), body, POLL_HTTP_MS);

  Serial.printf("http=%d (%lums)\n", code, (unsigned long)(millis() - t0));

  if (code == 204) { consecutiveFails = 0; return; }   // nothing to do

  if (code != 200) {
    consecutiveFails++;
    Serial.printf("[poll] failed (%d in a row)\n", consecutiveFails);

    if (consecutiveFails >= FAILS_BEFORE_REBOOT) {
      Serial.println("[poll] too many failures in a row, rebooting");
      delay(200);
      ESP.restart();
    }
    if (consecutiveFails % FAILS_BEFORE_RECONNECT == 0) {
      Serial.println("[poll] rebuilding WiFi + TLS");
      tls.stop();
      WiFi.disconnect(true, false);
      delay(500);
      if (wifiConnect()) { httpInit(); bootSync(); }
      return;
    }
    delay(2000);
    return;
  }
  consecutiveFails = 0;

  long cmdId   = jsonNum(body, "commandId", -1);
  String target = jsonStr(body, "target");
  if (cmdId < 0 || target.length() == 0) {
    Serial.printf("[poll] could not parse: %s\n", body.c_str());
    delay(1000);
    return;
  }

  Serial.printf("[cmd] #%ld -> %s\n", cmdId, target.c_str());
  applyState(target);

  if (confirmCommand(cmdId, target, true, nullptr)) {
    lastSeenId = cmdId; // only after the confirm actually went through
  } else {
    Serial.println("[confirm] gave up — will re-poll and re-run it.");
    Serial.println("          Safe: targets are absolute, so redoing it is a no-op.");
    delay(2000);
  }
}

#endif
