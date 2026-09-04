#pragma once
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "config.h"
#include "ring_buffer.h"

#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

class BluetoothManager : public BLEServerCallbacks {
private:
    BLEServer *pServer;
    BLECharacteristic *pTxCharacteristic;
    bool deviceConnected;

public:
    BluetoothManager() : pServer(nullptr), pTxCharacteristic(nullptr), deviceConnected(false) {}

    void onConnect(BLEServer* server) override {
        deviceConnected = true;
    }

    void onDisconnect(BLEServer* server) override {
        deviceConnected = false;
        if (server) {
            server->getAdvertising()->start();
        }
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
        Serial.print(line); // Echos directly to Wokwi Terminal

        if (!deviceConnected || !pTxCharacteristic) return;
        pTxCharacteristic->setValue((uint8_t*)line.c_str(), line.length());
        pTxCharacteristic->notify();
        delay(15);
    }

void transmitEmergencyPayload(const PreCrashBuffer &preBuffer,
                                  const PostCrashBuffer &postBuffer, 
                                  float peak_shock, 
                                  float peak_rotation) {
        // 1. Packet Frame Start Delimiter
        sendLine("<CRASH_START>\n");

        // 2. Complete JSON Payload
        sendLine("{\n");
        sendLine("  \"protocode\": \"" + String(VEHICLE_PROTO_CODE) + "\",\n");
        sendLine("  \"timestamp\": " + String(millis()) + ",\n");
        sendLine("  \"peak_shock\": " + String(peak_shock, 2) + ",\n");
        sendLine("  \"peak_rotation\": " + String(peak_rotation, 2) + ",\n");

        // Pre-Crash Array
        sendLine("  \"pre_crash\": [\n");
        uint16_t preCount = preBuffer.getCount();
        for (uint16_t i = 0; i < preCount; i++) {
            TelemetryFrame f = preBuffer.getFrame(i);
            String row = "    [" + String(f.timestamp_ms) + "," +
                         String(f.ax, 2) + "," + String(f.ay, 2) + "," + String(f.az, 2) + "," +
                         String(f.gx * 57.3f, 1) + "," + String(f.gy * 57.3f, 1) + "," + String(f.gz * 57.3f, 1) + "]";
            if (i < preCount - 1) row += ",";
            sendLine(row + "\n");
        }
        sendLine("  ],\n");

        // Post-Crash Array
        sendLine("  \"post_crash\": [\n");
        uint16_t postCount = postBuffer.getCount();
        for (uint16_t i = 0; i < postCount; i++) {
            TelemetryFrame f = postBuffer.getFrame(i);
            String row = "    [" + String(f.timestamp_ms) + "," +
                         String(f.ax, 2) + "," + String(f.ay, 2) + "," + String(f.az, 2) + "," +
                         String(f.gx * 57.3f, 1) + "," + String(f.gy * 57.3f, 1) + "," + String(f.gz * 57.3f, 1) + "]";
            if (i < postCount - 1) row += ",";
            sendLine(row + "\n");
        }
        sendLine("  ]\n");

        sendLine("}\n");

        // 3. Packet Frame End Delimiter
        sendLine("<CRASH_END>\n");
    }
};

extern BluetoothManager btManager;