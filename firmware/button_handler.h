#pragma once
#include <Arduino.h>
#include "config.h"

class ButtonHandler {
private:
    uint8_t pin;
    bool lastSteadyState;
    bool lastFlickerableState;
    unsigned long lastDebounceTime;

public:
    ButtonHandler(uint8_t buttonPin = PIN_BUTTON);

    // Configures pin as INPUT_PULLUP
    void begin();

    // Call continuously in loop(). Returns true ONCE on valid physical press
    bool wasPressed();
};

extern ButtonHandler cancelButton;