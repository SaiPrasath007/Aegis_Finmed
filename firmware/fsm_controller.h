#pragma once
#include <Arduino.h>
#include "config.h"

enum SystemState {
    STATE_MONITORING,
    STATE_COUNTDOWN,
    STATE_CANCELED,
    STATE_TRANSMITTING
};

class FSMController {
private:
    SystemState currentState;
    unsigned long stateStartTime;
    uint8_t remainingSeconds;

public:
    FSMController();

    void begin();
    void transitionTo(SystemState nextState);
    SystemState getCurrentState() const;
    uint8_t getRemainingSeconds() const;
    
    // Evaluates state timeouts (15s countdown, cancelled screen duration)
    void updateTimers();
};

extern FSMController systemFSM;