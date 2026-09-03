#pragma once
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "config.h"
#include "ring_buffer.h"

// Standard Nordic UART Service UUIDs
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

class BluetoothManager : public BLEServerCallbacks {
private:
    BLEServer *pServer;
    BLECharacteristic *pTxCharacteristic;
    bool deviceConnected;

public:
    BluetoothManager() : pServer(nullptr), pTxCharacteristic(nullptr), deviceConnected(false) {}

    void onConnect(BLEServer* pServer) override {
        deviceConnected = true;
    }

    void onDisconnect(BLEServer* pServer) override {
        deviceConnected = false;
        // Restart advertising so frontend can reconnect
        pServer->getAdvertising()->start();
    }

    bool begin(const char* deviceName = BT_DEVICE_NAME) {
        BLEDevice::init(deviceName);
        pServer = BLEDevice::createServer();
        pServer->setCallbacks(this);

        BLEService *pService = pServer->createService(SERVICE_UUID);

        pTxCharacteristic = pService->createCharacteristic(
            CHARACTERISTIC_UUID_TX,
            BLECharacteristic::PROPERTY_NOTIFY
        );
        pTxCharacteristic->addDescriptor(new BLE2902());

        pService->start();

        BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
        pAdvertising->addServiceUUID(SERVICE_UUID);
        pAdvertising->setScanResponse(true);
        pAdvertising->setMinPreferred(0x06);
        pAdvertising->setMinPreferred(0x12);
        BLEDevice::startAdvertising();

        return true;
    }

    bool isConnected() {
        return deviceConnected;
    }

    void sendLine(const String &line) {
        // Echo to Serial so you can view it directly in Wokwi's terminal
        Serial.print(line);

        if (!deviceConnected || !pTxCharacteristic) return;
        
        // BLE MTU safe transmission
        pTxCharacteristic->setValue((uint8_t*)line.c_str(), line.length());
        pTxCharacteristic->notify();
        delay(15); // Prevent congestion in the BLE stack
    }

    void transmitEmergencyPayload(const TelemetryRingBuffer &buffer, 
                                  float peak_shock, 
                                  float peak_rotation) {
        // 1. Top-level variables
        sendLine("{\n");
        sendLine("  \"protocode\": \"" + String(VEHICLE_PROTO_CODE) + "\",\n");
        sendLine("  \"timestamp\": " + String(millis()) + ",\n");
        sendLine("  \"peak_shock\": " + String(peak_shock, 2) + ",\n");
        sendLine("  \"peak_rotation\": " + String(peak_rotation, 2) + ",\n");

        uint16_t total = buffer.getCount();
        uint16_t splitPoint = (total > POST_CRASH_SAMPLES) ? (total - POST_CRASH_SAMPLES) : total;

        // 2. Pre-Crash Array: [t, ax, ay, az, gx, gy, gz]
        sendLine("  \"pre_crash\": [\n");
        for (uint16_t i = 0; i < splitPoint; i++) {
            TelemetryFrame f = buffer.getFrame(i);
            String row = "    [" + String(f.timestamp_ms) + "," +
                         String(f.ax, 2) + "," + String(f.ay, 2) + "," + String(f.az, 2) + "," +
                         String(f.gx * 57.3f, 1) + "," + String(f.gy * 57.3f, 1) + "," + String(f.gz * 57.3f, 1) + "]";
            if (i < splitPoint - 1) row += ",";
            sendLine(row + "\n");
        }
        sendLine("  ],\n");

        // 3. Post-Crash Array: [t, ax, ay, az, gx, gy, gz]
        sendLine("  \"post_crash\": [\n");
        for (uint16_t i = splitPoint; i < total; i++) {
            TelemetryFrame f = buffer.getFrame(i);
            String row = "    [" + String(f.timestamp_ms) + "," +
                         String(f.ax, 2) + "," + String(f.ay, 2) + "," + String(f.az, 2) + "," +
                         String(f.gx * 57.3f, 1) + "," + String(f.gy * 57.3f, 1) + "," + String(f.gz * 57.3f, 1) + "]";
            if (i < total - 1) row += ",";
            sendLine(row + "\n");
        }
        sendLine("  ]\n");

        // 4. Close JSON
        sendLine("}\n");
    }
};

extern BluetoothManager btManager;