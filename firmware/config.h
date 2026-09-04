#pragma once
#include <Arduino.h>

// ==========================================
// 1. PIN ASSIGNMENTS (STRAPPING-SAFE)
// ==========================================
#define PIN_I2C_SDA         21  // Shared I2C Data (MPU6050 & SSD1306)
#define PIN_I2C_SCL         22  // Shared I2C Clock (MPU6050 & SSD1306)
#define PIN_BUTTON          4   // False Alarm Cancellation Button (Active-LOW)
#define PIN_BUZZER          18  // Audible Warning Buzzer (Active-HIGH)

// ==========================================
// 2. I2C DEVICE ADDRESSES
// ==========================================
#define MPU6050_I2C_ADDR    0x68
#define OLED_I2C_ADDR       0x3C
#define SCREEN_WIDTH        128
#define SCREEN_HEIGHT       64

// ==========================================
// 3. SAMPLING & BUFFER TIMING CONSTANTS
// ==========================================
#define SAMPLE_RATE_HZ      20                          // 20 samples per second
#define SAMPLE_INTERVAL_MS  (1000 / SAMPLE_RATE_HZ)     // 50 ms between samples
#define BUFFER_DURATION_SEC 15                          // Total black-box duration
#define BUFFER_SIZE         (SAMPLE_RATE_HZ * BUFFER_DURATION_SEC) // 300 samples

#define PRE_CRASH_SEC       10                          // History prior to impact
#define POST_CRASH_SEC      5                           // Freeze capture post-impact
#define PRE_CRASH_SAMPLES       (PRE_CRASH_SEC * SAMPLE_RATE_HZ)   // 200 samples
#define POST_CRASH_SAMPLES  (SAMPLE_RATE_HZ * POST_CRASH_SEC) // 100 samples

#define COUNTDOWN_PERIOD_MS 15000                       // 15-second driver cancel window
#define BUTTON_DEBOUNCE_MS  50                          // Noise filtering delay

// ==========================================
// 4. CRASH DETECTION THRESHOLDS
// ==========================================
// 1G = 9.80665 m/s^2. Set default trigger at 3.5G
#define GRAVITY_MSS         9.80665f
#define IMPACT_THRESHOLD_G  3.5f
#define IMPACT_THRESHOLD_MSS (IMPACT_THRESHOLD_G * GRAVITY_MSS) // ~34.32 m/s^2

// ==========================================
// 5. IDENTITY & TELEMETRY PROTOCOL
// ==========================================
#define PROTO_VERSION       "AEGIS-v1.0"
#define VEHICLE_PROTO_CODE  "ACKO-2W-TN09-9842"
#define BT_DEVICE_NAME      "AEGIS_NODE_9842"