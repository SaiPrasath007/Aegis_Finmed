#pragma once
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <math.h>
#include "config.h"

// Trigger thresholds
#define DELTA_ACC_THRESHOLD_MSS   25.0f   // Shock delta: |cur - prev| (~2.5G sudden change)
#define ROTATION_THRESHOLD_DPS    120.0f  // Angular rate threshold (~120 deg/s rotation/tilt)

struct CrashMetrics {
    float cur_acc_magnitude;
    float delta_acc_magnitude;
    float gyro_magnitude_dps;
    bool is_collision;
};

class KinematicsEngine {
private:
    Adafruit_MPU6050 mpu;
    unsigned long lastSampleTime;

    // Static calibration offsets
    float ax_offset, ay_offset, az_offset;
    float gx_offset, gy_offset, gz_offset;

    // Historical magnitude tracker
    float prev_acc_mag;
    bool is_first_reading;

public:
    KinematicsEngine() : lastSampleTime(0),
                         ax_offset(0.0f), ay_offset(0.0f), az_offset(0.0f),
                         gx_offset(0.0f), gy_offset(0.0f), gz_offset(0.0f),
                         prev_acc_mag(GRAVITY_MSS), is_first_reading(true) {}

    // Initialize I2C and sensor registers
    bool begin();

    // Baseline calibration (keep node flat & stationary during boot)
    void calibrate(uint16_t sample_count = 100);

    // Reset collision detection states (after false alarm or upload)
    void resetDetection();

    // 20Hz non-blocking sample + dual-condition crash validation
    bool processSample(float &ax, float &ay, float &az, 
                       float &gx, float &gy, float &gz, 
                       CrashMetrics &metrics);
};

// Global instance
extern KinematicsEngine kinematicsNode;