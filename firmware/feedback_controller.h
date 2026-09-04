#pragma once
#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include "config.h"

class FeedbackController {
private:
    Adafruit_SSD1306 display;
    uint8_t buzzerPin;
    unsigned long lastBuzzerToggle;
    bool buzzerState;

public:
    FeedbackController(uint8_t buzzPin = PIN_BUZZER);

    // Initialize display & configure buzzer output pin
    bool begin();

    // UI Renderers
    void showMonitoring(float current_g, bool bt_connected);
    void showCountdown(uint8_t seconds_left);
    void showTransmitting();
    void showCancelled();

    // Audio Feedback
    void updateBuzzer(uint8_t seconds_left);
    void silenceBuzzer();
    void playBootChirp();
    void playCancelChirp();
};

extern FeedbackController feedbackNode;