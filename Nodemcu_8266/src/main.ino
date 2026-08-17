#include <Arduino.h>
#include <ArduinoJson.h>
#include <FastLED.h>

//

// --- CONFIGURATION ---
const uint16_t PixelCount = 24;     // NeoPixel ring size
const uint8_t PixelPin = 2;         // D4 (GPIO2) on NodeMCU / ESP8266

// FastLED array definition
CRGB leds[PixelCount];

struct Segment {
  uint16_t start;
  uint16_t end;
  CRGB color;       // Background solid color
  CRGB dotColor;    // Running dot color
  String animation;
};

Segment cachedSegments[10];
int segmentCount = 0;
unsigned long lastPacketTime = 0;
const unsigned long timeoutMillis = 15000; // 15 seconds stale timeout

// ==========================================
// Animation Helper Functions
// ==========================================
void renderIdleAnimation() {
  // Smooth breathing Cyan idle ring effect
  float wave = (sin(millis() / 500.0) + 1.0) / 2.0; 
  uint8_t brightness = (uint8_t)(20 + (wave * 80));   

  CRGB idleColor = CRGB(0, (uint8_t)(100 * (brightness / 100.0)), (uint8_t)(150 * (brightness / 100.0)));
  fill_solid(leds, PixelCount, idleColor);
}

void renderActiveAnimations() {
  FastLED.clear();

  for (int i = 0; i < segmentCount; i++) {
    Segment seg = cachedSegments[i];
    
    if (seg.animation == "pulse") {
      float brightness = (sin(millis() / 200.0) + 1.0) / 2.0; 
      brightness = 0.25 + (brightness * 0.75);          

      CRGB scaledColor = CRGB(
        (uint8_t)(seg.color.r * brightness),
        (uint8_t)(seg.color.g * brightness),
        (uint8_t)(seg.color.b * brightness)
      );

      for (uint16_t j = seg.start; j <= seg.end && j < PixelCount; j++) {
        leds[j] = scaledColor;
      }
    } 
    else if (seg.animation == "running" || seg.animation == "crawler") {
      // 1. Fill segment background with the base solid color
      for (uint16_t j = seg.start; j <= seg.end && j < PixelCount; j++) {
        leds[j] = seg.color;
      }

      // 2. One-way running dot (wraps around to start)
      int length = (seg.end >= seg.start) ? (seg.end - seg.start + 1) : 1;
      int offset = (millis() / 100) % length; 
      uint16_t targetPixel = seg.start + offset;

      if (targetPixel < PixelCount) {
        leds[targetPixel] = seg.dotColor; 
      }
    }
    else if (seg.animation == "bounce" || seg.animation == "pingpong") {
      // 1. Fill segment background with the base solid color
      for (uint16_t j = seg.start; j <= seg.end && j < PixelCount; j++) {
        leds[j] = seg.color;
      }

      // 2. Bounceback / Ping-pong motion calculation
      int length = (seg.end >= seg.start) ? (seg.end - seg.start + 1) : 1;
      int offset = 0;

      if (length > 1) {
        int period = 2 * (length - 1);
        int phase = (millis() / 100) % period; 
        if (phase < length) {
          offset = phase;
        } else {
          offset = period - phase;
        }
      }

      uint16_t targetPixel = seg.start + offset;

      if (targetPixel < PixelCount) {
        leds[targetPixel] = seg.dotColor; 
      }
    } 
    else { 
      // Default / solid animation
      for (uint16_t j = seg.start; j <= seg.end && j < PixelCount; j++) {
        leds[j] = seg.color;
      }
    }
  }
}

// ==========================================
// Setup & Loop
// ==========================================
void setup() {
  Serial.begin(115200);
  
  // Initialize FastLED
  FastLED.addLeds<NEOPIXEL, PixelPin>(leds, PixelCount);
  FastLED.setBrightness(255);
  
  fill_solid(leds, PixelCount, CRGB(0, 0, 50));
  FastLED.show();
}

void loop() {
  // Read incoming JSON payload line-by-line from USB Serial
  if (Serial.available() > 0) {
    String incomingData = Serial.readStringUntil('\n');
    incomingData.trim();
    
    if (incomingData.length() > 0) {
      JsonDocument doc;
      DeserializationError error = deserializeJson(doc, incomingData);

      if (!error) {
        JsonArray segments = doc["segments"];
        segmentCount = 0;
        for (JsonObject seg : segments) {
          if (segmentCount < 10) {
            cachedSegments[segmentCount].start = seg["start"];
            cachedSegments[segmentCount].end = seg["end"];
            
            // Background color
            JsonArray col = seg["color"];
            cachedSegments[segmentCount].color = CRGB(col[0], col[1], col[2]);
            
            // Optional Dot color (defaults to White if omitted)
            if (seg["dotColor"].is<JsonArray>()) {
              JsonArray dcol = seg["dotColor"];
              cachedSegments[segmentCount].dotColor = CRGB(dcol[0], dcol[1], dcol[2]);
            } else {
              cachedSegments[segmentCount].dotColor = CRGB(255, 255, 255);
            }

            cachedSegments[segmentCount].animation = seg["animation"].as<String>();
            segmentCount++;
          }
        }
        lastPacketTime = millis();
      }
    }
  }

  // Render animations based on state
  if (segmentCount == 0 || (millis() - lastPacketTime > timeoutMillis && segmentCount == 0)) {
    renderIdleAnimation();
  } else {
    renderActiveAnimations();
  }

  FastLED.show();
  delay(30);
}