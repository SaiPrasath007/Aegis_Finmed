#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

#include "config.h"
#include "ring_buffer.h"
#include "kinematics_engine.h"
#include "button_handler.h"
#include "feedback_controller.h"
#include "fsm_controller.h"
#include "bluetooth_manager.h"

// ==========================================
// 1. GLOBAL OBJECTS
// ==========================================
PreCrashBuffer   preCrashBuffer;
PostCrashBuffer  postCrashBuffer;
KinematicsEngine kinematicsNode;
ButtonHandler    cancelButton(PIN_BUTTON);
FeedbackController feedbackNode(PIN_BUZZER);
FSMController    systemFSM;
BluetoothManager btManager;

CrashMetrics latestIncidentMetrics;
uint16_t postCrashSamplesRemaining = 0;

// ==========================================
// 2. SETUP
// ==========================================
void setup() {
    Serial.begin(115200);

    cancelButton.begin();
    feedbackNode.begin();
    btManager.begin(BT_DEVICE_NAME);
    systemFSM.begin();

    feedbackNode.playBootChirp();

    if (!kinematicsNode.begin()) {
        Serial.println("[ERROR] MPU6050 init failed!");
        while (1) { delay(100); }
    }

    kinematicsNode.calibrate(50);
    Serial.println("[OK] AegisLink Node Ready.");
}

// ==========================================
// 3. MAIN LOOP
// ==========================================
void loop() {
    systemFSM.updateTimers();
    bool buttonTriggered = cancelButton.wasPressed();

    float ax, ay, az, gx, gy, gz;
    CrashMetrics metrics;

    switch (systemFSM.getCurrentState()) {

        case STATE_MONITORING: {
            feedbackNode.silenceBuzzer();

            if (kinematicsNode.processSample(ax, ay, az, gx, gy, gz, metrics)) {
                // Keep filling rolling 10-second pre-crash window
                preCrashBuffer.push(millis(), ax, ay, az, gx, gy, gz);
                feedbackNode.showMonitoring(metrics.cur_acc_magnitude, btManager.isConnected());

                if (metrics.is_collision) {
                    latestIncidentMetrics = metrics;
                    // Reset and prepare post-crash collector
                    postCrashBuffer.reset();
                    postCrashSamplesRemaining = POST_CRASH_SAMPLES;
                    systemFSM.transitionTo(STATE_COUNTDOWN);
                }
            }
            break;
        }

        case STATE_COUNTDOWN: {
            uint8_t remaining = systemFSM.getRemainingSeconds();
            feedbackNode.showCountdown(remaining);
            feedbackNode.updateBuzzer(remaining);

            // Record strictly into postCrashBuffer
            if (postCrashSamplesRemaining > 0) {
                if (kinematicsNode.processSample(ax, ay, az, gx, gy, gz, metrics)) {
                    postCrashBuffer.push(millis(), ax, ay, az, gx, gy, gz);
                    postCrashSamplesRemaining--;
                }
            }

            if (buttonTriggered) {
                feedbackNode.silenceBuzzer();
                feedbackNode.playCancelChirp();
                postCrashSamplesRemaining = 0;
                postCrashBuffer.reset();
                kinematicsNode.resetDetection();
                systemFSM.transitionTo(STATE_CANCELED);
            }
            break;
        }

        case STATE_CANCELED: {
            feedbackNode.silenceBuzzer();
            feedbackNode.showCancelled();
            break;
        }

        case STATE_TRANSMITTING: {
            feedbackNode.silenceBuzzer();
            feedbackNode.showTransmitting();

            // Send both cleanly separated buffers
            btManager.transmitEmergencyPayload(
                preCrashBuffer,
                postCrashBuffer, 
                latestIncidentMetrics.delta_acc_magnitude, 
                latestIncidentMetrics.gyro_magnitude_dps
            );

            delay(2000);
            postCrashSamplesRemaining = 0;
            postCrashBuffer.reset();
            kinematicsNode.resetDetection();
            systemFSM.transitionTo(STATE_MONITORING);
            break;
        }
    }
}