#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include "BluetoothSerial.h"

// Include our modular architecture headers
#include "config.h"
#include "ring_buffer.h"
#include "kinematics_engine.h"
#include "button_handler.h"
#include "feedback_controller.h"
#include "fsm_controller.h"
#include "bluetooth_manager.h"

// ==========================================
// 1. GLOBAL INSTANTIATIONS
// ==========================================
TelemetryRingBuffer blackBoxBuffer;
KinematicsEngine    kinematicsNode;
ButtonHandler       cancelButton(PIN_BUTTON);
FeedbackController  feedbackNode(PIN_BUZZER);
FSMController       systemFSM;
BluetoothManager    btManager;

// Metrics holder for incident snapshot
CrashMetrics latestIncidentMetrics;

// ==========================================
// 2. MODULE IMPLEMENTATION BODIES
// ==========================================

// --- Button Handler Implementation ---
ButtonHandler::ButtonHandler(uint8_t buttonPin) 
    : pin(buttonPin), lastSteadyState(HIGH), lastFlickerableState(HIGH), lastDebounceTime(0) {}

void ButtonHandler::begin() {
    pinMode(pin, INPUT_PULLUP);
}

bool ButtonHandler::wasPressed() {
    bool currentReading = digitalRead(pin);
    bool pressedEvent = false;

    if (currentReading != lastFlickerableState) {
        lastDebounceTime = millis();
        lastFlickerableState = currentReading;
    }

    if ((millis() - lastDebounceTime) > BUTTON_DEBOUNCE_MS) {
        if (lastSteadyState == HIGH && currentReading == LOW) {
            pressedEvent = true;
        }
        lastSteadyState = currentReading;
    }
    return pressedEvent;
}

// --- Kinematics Engine Implementation ---
bool KinematicsEngine::begin() {
    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 400000);
    if (!mpu.begin(MPU6050_I2C_ADDR, &Wire)) return false;

    mpu.setAccelerometerRange(MPU6050_RANGE_16_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    return true;
}

void KinematicsEngine::calibrate(uint16_t sample_count) {
    float sum_ax = 0, sum_ay = 0, sum_az = 0;
    float sum_gx = 0, sum_gy = 0, sum_gz = 0;

    for (uint16_t i = 0; i < sample_count; i++) {
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);

        sum_ax += a.acceleration.x;
        sum_ay += a.acceleration.y;
        sum_az += a.acceleration.z;

        sum_gx += g.gyro.x;
        sum_gy += g.gyro.y;
        sum_gz += g.gyro.z;
        delay(10);
    }

    ax_offset = sum_ax / sample_count;
    ay_offset = sum_ay / sample_count;
    az_offset = (sum_az / sample_count) - GRAVITY_MSS; // 1G baseline on Z

    gx_offset = sum_gx / sample_count;
    gy_offset = sum_gy / sample_count;
    gz_offset = sum_gz / sample_count;
    resetDetection();
}

void KinematicsEngine::resetDetection() {
    prev_acc_mag = GRAVITY_MSS;
    is_first_reading = true;
}

bool KinematicsEngine::processSample(float &ax, float &ay, float &az, 
                                      float &gx, float &gy, float &gz, 
                                      CrashMetrics &metrics) {
    unsigned long now = millis();
    if (now - lastSampleTime < SAMPLE_INTERVAL_MS) return false;
    lastSampleTime = now;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    ax = a.acceleration.x - ax_offset;
    ay = a.acceleration.y - ay_offset;
    az = a.acceleration.z - az_offset;

    gx = g.gyro.x - gx_offset;
    gy = g.gyro.y - gy_offset;
    gz = g.gyro.z - gz_offset;

    float cur_acc_mag = sqrt(ax * ax + ay * ay + az * az);

    if (is_first_reading) {
        prev_acc_mag = cur_acc_mag;
        is_first_reading = false;
        metrics.is_collision = false;
        return true;
    }

    float delta_acc = fabs(cur_acc_mag - prev_acc_mag);
    prev_acc_mag = cur_acc_mag;

    float gyro_mag_dps = sqrt(gx * gx + gy * gy + gz * gz) * 57.2958f;

    metrics.cur_acc_magnitude = cur_acc_mag;
    metrics.delta_acc_magnitude = delta_acc;
    metrics.gyro_magnitude_dps = gyro_mag_dps;

    // Dual-Condition Verification: Sudden shock delta AND tilt/rotation
    metrics.is_collision = (delta_acc > DELTA_ACC_THRESHOLD_MSS && 
                            gyro_mag_dps > ROTATION_THRESHOLD_DPS);

    return true;
}

// --- Feedback Controller Implementation ---
FeedbackController::FeedbackController(uint8_t buzzPin)
    : display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1),
      buzzerPin(buzzPin), lastBuzzerToggle(0), buzzerState(false) {}

bool FeedbackController::begin() {
    pinMode(buzzerPin, OUTPUT);
    digitalWrite(buzzerPin, LOW);

    if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDR)) {
        return false;
    }

    display.clearDisplay();
    display.setTextColor(SSD1306_WHITE);
    return true;
}

void FeedbackController::showMonitoring(float current_g, bool bt_connected) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("AEGIS-LINK | MONITOR");
    display.drawLine(0, 10, 128, 10, SSD1306_WHITE);

    display.setCursor(0, 18);
    display.printf("ID: %s\n", VEHICLE_PROTO_CODE);

    display.setCursor(0, 32);
    display.printf("G-Force : %.2f G\n", current_g / GRAVITY_MSS);

    display.setCursor(0, 46);
    display.printf("BT Link : %s", bt_connected ? "PAIRED" : "ADVERTISING");

    display.display();
}

void FeedbackController::showCountdown(uint8_t seconds_left) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("!! CRASH DETECTED !!");
    display.drawLine(0, 10, 128, 10, SSD1306_WHITE);

    display.setTextSize(2);
    display.setCursor(28, 18);
    display.printf("%02d SEC", seconds_left);

    display.setTextSize(1);
    display.setCursor(10, 48);
    display.println("PRESS BTN TO CANCEL");

    display.display();
}

void FeedbackController::showTransmitting() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.println("EMERGENCY DISPATCH");
    display.drawLine(0, 10, 128, 10, SSD1306_WHITE);

    display.setCursor(0, 20);
    display.println("Transmitting EDR Data");
    display.setCursor(0, 34);
    display.println("Zero-Touch FNOL Sent");
    display.setCursor(0, 48);
    display.println("Claim Disbursed via UPI");

    display.display();
}

void FeedbackController::showCancelled() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 16);
    display.println("FALSE ALARM RECORDED");
    display.setCursor(0, 34);
    display.println("Claim Generation Aborted");
    display.display();
}

void FeedbackController::updateBuzzer(uint8_t seconds_left) {
    unsigned long now = millis();
    unsigned long pulseRate = (seconds_left <= 5) ? 150 : 400;

    if (now - lastBuzzerToggle >= pulseRate) {
        lastBuzzerToggle = now;
        buzzerState = !buzzerState;
        digitalWrite(buzzerPin, buzzerState ? HIGH : LOW);
    }
}

void FeedbackController::silenceBuzzer() {
    buzzerState = false;
    digitalWrite(buzzerPin, LOW);
}

void FeedbackController::playBootChirp() {
    digitalWrite(buzzerPin, HIGH);
    delay(80);
    digitalWrite(buzzerPin, LOW);
}

void FeedbackController::playCancelChirp() {
    digitalWrite(buzzerPin, HIGH);
    delay(50);
    digitalWrite(buzzerPin, LOW);
    delay(50);
    digitalWrite(buzzerPin, HIGH);
    delay(50);
    digitalWrite(buzzerPin, LOW);
}

// --- FSM Controller Implementation ---
FSMController::FSMController() 
    : currentState(STATE_MONITORING), stateStartTime(0), remainingSeconds(15) {}

void FSMController::begin() {
    currentState = STATE_MONITORING;
    stateStartTime = millis();
    remainingSeconds = 15;
}

void FSMController::transitionTo(SystemState nextState) {
    currentState = nextState;
    stateStartTime = millis();

    if (nextState == STATE_COUNTDOWN) {
        remainingSeconds = COUNTDOWN_PERIOD_MS / 1000;
    }
}

SystemState FSMController::getCurrentState() const {
    return currentState;
}

uint8_t FSMController::getRemainingSeconds() const {
    return remainingSeconds;
}

void FSMController::updateTimers() {
    unsigned long elapsed = millis() - stateStartTime;

    switch (currentState) {
        case STATE_COUNTDOWN: {
            if (elapsed >= COUNTDOWN_PERIOD_MS) {
                transitionTo(STATE_TRANSMITTING);
            } else {
                remainingSeconds = (COUNTDOWN_PERIOD_MS - elapsed) / 1000;
            }
            break;
        }

        case STATE_CANCELED: {
            if (elapsed >= 2500) {
                transitionTo(STATE_MONITORING);
            }
            break;
        }

        case STATE_TRANSMITTING:
        case STATE_MONITORING:
        default:
            break;
    }
}

// --- Bluetooth Manager Implementation ---
BluetoothManager::BluetoothManager() : isInitialized(false) {}

bool BluetoothManager::begin(const char* deviceName) {
    if (!SerialBT.begin(deviceName)) return false;
    isInitialized = true;
    return true;
}

bool BluetoothManager::isConnected() {
    return isInitialized && SerialBT.hasClient();
}

void BluetoothManager::print(const char* msg) {
    if (isInitialized) SerialBT.print(msg);
}

void BluetoothManager::println(const char* msg) {
    if (isInitialized) SerialBT.println(msg);
}

void BluetoothManager::transmitEmergencyPayload(const TelemetryRingBuffer &buffer, 
                                               float peak_shock, 
                                               float peak_rotation) {
    if (!isInitialized) return;

    SerialBT.println("==================================================");
    SerialBT.println(">>> AEGIS-LINK TELEMETRIC FIRST NOTICE OF LOSS <<<");
    SerialBT.println("==================================================");
    SerialBT.printf("PROTO_VERSION : %s\n", PROTO_VERSION);
    SerialBT.printf("VEHICLE_CODE  : %s\n", VEHICLE_PROTO_CODE);
    SerialBT.printf("EVENT_TYPE    : PARAMETRIC_CONFIRMED_COLLISION\n");
    SerialBT.printf("PEAK_SHOCK_MSS: %.2f\n", peak_shock);
    SerialBT.printf("PEAK_ROT_DPS  : %.2f\n", peak_rotation);
    SerialBT.printf("TOTAL_FRAMES  : %u\n", buffer.getCount());
    SerialBT.println("--------------------------------------------------");
    SerialBT.println("TIME_MS,AX_MSS,AY_MSS,AZ_MSS,GX_DPS,GY_DPS,GZ_DPS");

    uint16_t totalSamples = buffer.getCount();
    for (uint16_t i = 0; i < totalSamples; i++) {
        TelemetryFrame frame = buffer.getFrame(i);
        SerialBT.printf("%u,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
            frame.timestamp_ms,
            frame.ax, frame.ay, frame.az,
            frame.gx * 57.2958f, 
            frame.gy * 57.2958f, 
            frame.gz * 57.2958f
        );
    }

    SerialBT.println("==================================================");
    SerialBT.println(">>> END OF INCIDENT TELEMETRY STREAM <<<");
    SerialBT.println("==================================================");
    SerialBT.flush();
}

// ==========================================
// 3. MAIN SETUP & LOOP EXECUTION
// ==========================================
void setup() {
    Serial.begin(115200);

    cancelButton.begin();
    feedbackNode.begin();
    btManager.begin(BT_DEVICE_NAME);
    systemFSM.begin();

    // Show Bootloader Screen
    feedbackNode.playBootChirp();

    if (!kinematicsNode.begin()) {
        Serial.println("[ERROR] MPU6050 communication failed! Check I2C wiring.");
        while (1) { delay(100); }
    }

    // Auto Calibration (keep unit flat on desk during boot)
    kinematicsNode.calibrate(100);
    Serial.println("[OK] AegisLink Edge Node Ready.");
}

void loop() {
    // 1. Tick state timeouts and countdown counters
    systemFSM.updateTimers();

    // 2. Poll push button for manual cancellation
    bool buttonTriggered = cancelButton.wasPressed();

    // 3. Finite State Machine Dispatcher
    switch (systemFSM.getCurrentState()) {

        case STATE_MONITORING: {
            feedbackNode.silenceBuzzer();

            float ax, ay, az, gx, gy, gz;
            CrashMetrics metrics;

            // Poll sensor at exact 20Hz interval
            if (kinematicsNode.processSample(ax, ay, az, gx, gy, gz, metrics)) {
                // Save to circular ring buffer
                blackBoxBuffer.push(millis(), ax, ay, az, gx, gy, gz);

                // Update live OLED metrics
                feedbackNode.showMonitoring(metrics.cur_acc_magnitude, btManager.isConnected());

                // Evaluate collision threshold trip
                if (metrics.is_collision) {
                    latestIncidentMetrics = metrics;
                    systemFSM.transitionTo(STATE_COUNTDOWN);
                }
            }
            break;
        }

        case STATE_COUNTDOWN: {
            uint8_t remaining = systemFSM.getRemainingSeconds();

            // Screen & Audio Alert
            feedbackNode.showCountdown(remaining);
            feedbackNode.updateBuzzer(remaining);

            // User pressed button -> False alarm detected
            if (buttonTriggered) {
                feedbackNode.silenceBuzzer();
                feedbackNode.playCancelChirp();
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

            // Dump proto-code and unwound 15s history over Bluetooth
            btManager.transmitEmergencyPayload(
                blackBoxBuffer, 
                latestIncidentMetrics.delta_acc_magnitude, 
                latestIncidentMetrics.gyro_magnitude_dps
            );

            delay(2000); // Allow judges to view the screen
            kinematicsNode.resetDetection();
            systemFSM.transitionTo(STATE_MONITORING);
            break;
        }
    }
}