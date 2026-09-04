#pragma once
#include <Arduino.h>
#include "config.h"

// Telemetry structure: exactly 28 bytes
struct TelemetryFrame {
    uint32_t timestamp_ms;
    float ax;
    float ay;
    float az;
    float gx;
    float gy;
    float gz;
};

template <uint16_t CAPACITY>
class TelemetryBuffer {
private:
    TelemetryFrame buffer[CAPACITY];
    uint16_t head;
    bool is_full;

public:
    TelemetryBuffer() : head(0), is_full(false) {}

    void reset() {
        head = 0;
        is_full = false;
    }

    void push(uint32_t t, float ax, float ay, float az, float gx, float gy, float gz) {
        buffer[head].timestamp_ms = t;
        buffer[head].ax = ax;
        buffer[head].ay = ay;
        buffer[head].az = az;
        buffer[head].gx = gx;
        buffer[head].gy = gy;
        buffer[head].gz = gz;

        head++;
        if (head >= CAPACITY) {
            head = 0;
            is_full = true;
        }
    }

    uint16_t getCount() const {
        return is_full ? CAPACITY : head;
    }

    TelemetryFrame getFrame(uint16_t chronological_index) const {
        if (!is_full) {
            return buffer[chronological_index];
        }
        uint16_t actual_index = (head + chronological_index) % CAPACITY;
        return buffer[actual_index];
    }
};

// Typedefs for 10s pre-crash (200 samples) and 5s post-crash (100 samples)
typedef TelemetryBuffer<PRE_CRASH_SAMPLES> PreCrashBuffer;
typedef TelemetryBuffer<POST_CRASH_SAMPLES> PostCrashBuffer;

extern PreCrashBuffer preCrashBuffer;
extern PostCrashBuffer postCrashBuffer;