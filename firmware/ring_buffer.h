#pragma once
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

class TelemetryRingBuffer {
private:
    TelemetryFrame buffer[BUFFER_SIZE];
    uint16_t head;
    bool is_full;

public:
    TelemetryRingBuffer() : head(0), is_full(false) {}

    // Resets buffer indices
    void reset() {
        head = 0;
        is_full = false;
    }

    // Insert a new sensor reading (overwrites oldest entry if full)
    void push(uint32_t t, float ax, float ay, float az, float gx, float gy, float gz) {
        buffer[head].timestamp_ms = t;
        buffer[head].ax = ax;
        buffer[head].ay = ay;
        buffer[head].az = az;
        buffer[head].gx = gx;
        buffer[head].gy = gy;
        buffer[head].gz = gz;

        head++;
        if (head >= BUFFER_SIZE) {
            head = 0;
            is_full = true;
        }
    }

    // Returns the total number of valid frames currently stored
    uint16_t getCount() const {
        return is_full ? BUFFER_SIZE : head;
    }

    // Retrieves frame at chronological index (0 = oldest, getCount()-1 = newest)
    TelemetryFrame getFrame(uint16_t chronological_index) const {
        if (!is_full) {
            return buffer[chronological_index];
        }
        uint16_t actual_index = (head + chronological_index) % BUFFER_SIZE;
        return buffer[actual_index];
    }
};

// Global instance for all modules
extern TelemetryRingBuffer blackBoxBuffer;