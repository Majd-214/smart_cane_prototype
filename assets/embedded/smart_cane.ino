#include <Wire.h>
#include <MPU6500_WE.h> // Make sure this is the correct library include
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEService.h>
#include <BLECharacteristic.h>
#include <BLEAdvertising.h>
#include <BLE2902.h>
#include <Adafruit_NeoPixel.h>

// --- Configuration ---
#define SERVICE_UUID                "A5A20D8A-E137-4B30-9F30-1A7A91579C9C"
#define BATTERY_CHARACTERISTIC_UUID "2A19"
#define FALL_CHARACTERISTIC_UUID    "C712A5B2-2C13-4088-8D53-F7E3291B0155"
#define CALIBRATION_CHARACTERISTIC_UUID "E9A10B6B-8A65-4F56-82C3-6768F0EE38A1"
#define CALIBRATION_STATUS_UUID     "494600C8-1693-4A3B-B380-FF1EC534959E"
#define DEVICE_NAME "Smart Cane"

#define I2C_SDA_PIN 32
#define I2C_SCL_PIN 14
#define MPU6500_ADDR 0x68
#define ONBOARD_BLUE_LED_PIN 2
#define NEOPIXEL_PIN 16

#define NUM_NEOPIXELS 1
Adafruit_NeoPixel rgbLed(NUM_NEOPIXELS, NEOPIXEL_PIN, NEO_GRB + NEO_KHZ800);

#define SIMPLIFIED_LOW_G_THRESHOLD  0.7f
#define SIMPLIFIED_HIGH_G_THRESHOLD 2.2f
#define FALL_COOLDOWN_MS            5000
#define FALL_CHECK_INTERVAL_MS      50

#define BATTERY_VOLTAGE_PIN         34
#define ADC_RESOLUTION              4095.0f
#define ADC_VREF                    3.3f
#define MIN_BATTERY_VOLTAGE         2.4f
#define MAX_BATTERY_VOLTAGE         3.2f
const unsigned long batteryUpdateIntervalMs = 30000;

MPU6500_WE myMPU6500 = MPU6500_WE(MPU6500_ADDR);

bool mpuSuccessfullyInitialized = false;

BLEServer* pServer = nullptr;
BLECharacteristic* pBatteryCharacteristic = nullptr;
BLECharacteristic* pFallCharacteristic = nullptr;
BLECharacteristic* pCalibrationCharacteristic = nullptr;
BLECharacteristic* pCalibrationStatusCharacteristic = nullptr;
BLEAdvertising *pAdvertising = nullptr;

volatile bool deviceConnected = false;
volatile bool startAdvertisingPending = false;

unsigned long lastFallTriggerTime = 0;
unsigned long lastBatteryUpdateTime = 0;
unsigned long lastFallCheckTime = 0;
uint8_t currentBatteryPercentage = 0;

enum SystemState {
    STATE_INITIALIZING, STATE_MPU_ERROR, STATE_BLE_ADVERTISING, STATE_BLE_CONNECTING,
    STATE_BLE_CONNECTED_IDLE, STATE_CALIBRATION_IN_PROGRESS,
    STATE_CALIBRATION_SUCCESS_TEMP, STATE_CALIBRATION_FAILED_TEMP,
    STATE_FALL_DETECTED_COOLDOWN, STATE_LOW_BATTERY_CONNECTED
};
SystemState currentSystemState = STATE_INITIALIZING;
SystemState previousSystemStateForTemp = STATE_BLE_CONNECTED_IDLE;

unsigned long ledPatternLastUpdateTime = 0;
int ledPulseBrightness = 0;
bool ledPulseDirectionUp = true;
bool blueLedState = false;

const uint32_t COLOR_RED = rgbLed.Color(255, 0, 0);
const uint32_t COLOR_GREEN = rgbLed.Color(0, 255, 0);
const uint32_t COLOR_BLUE = rgbLed.Color(0, 0, 255);
const uint32_t COLOR_CYAN = rgbLed.Color(0, 255, 255);
const uint32_t COLOR_MAGENTA = rgbLed.Color(255, 0, 255);
const uint32_t COLOR_YELLOW = rgbLed.Color(255, 255, 0);
const uint32_t COLOR_ORANGE = rgbLed.Color(255, 100, 0);
const uint32_t COLOR_WHITE = rgbLed.Color(150, 150, 150);
const uint32_t COLOR_OFF = rgbLed.Color(0, 0, 0);

void updateSystemState(SystemState newState, bool forceUpdate = false);
bool isMpuConnectedAndResponsive();
void updateLedStatus();

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* svrInstance, esp_ble_gatts_cb_param_t *param) {
        deviceConnected = true;
        Serial.println("Device connected");
        updateSystemState(STATE_BLE_CONNECTED_IDLE);
    };
    void onDisconnect(BLEServer* svrInstance) {
        deviceConnected = false;
        Serial.println("Device disconnected.");
        startAdvertisingPending = true;
        updateSystemState(mpuSuccessfullyInitialized ? STATE_BLE_ADVERTISING : STATE_MPU_ERROR);
    }
};

bool isMpuConnectedAndResponsive() {
    // Corrected: Use whoAmI()
    uint8_t whoAmI_val = myMPU6500.whoAmI();
    Serial.print("isMpuConnectedAndResponsive - WhoAmI Check: Read 0x");
    Serial.print(whoAmI_val, HEX);
    // Corrected: Use literal 0x71 (standard MPU6500 WhoAmI)
    Serial.print(" (Expected for MPU6500: 0x71 or compatible like 0x73 for MPU9255)"); Serial.println();


    // Primary Check: WHO AM I
    if (whoAmI_val != 0x71 && whoAmI_val != 0x73 && whoAmI_val != 0x70) { // 0x71 is MPU6500, 0x73 for MPU9255
        Serial.println("isMpuConnectedAndResponsive: FAIL - WhoAmI mismatch.");
        return false;
    }
    Serial.println("isMpuConnectedAndResponsive: PASS - WhoAmI matched.");

    xyzFloat accVal1 = myMPU6500.getGValues();
    xyzFloat gyrVal1 = myMPU6500.getGyrValues();
    delay(20);
    xyzFloat accVal2 = myMPU6500.getGValues();
    xyzFloat gyrVal2 = myMPU6500.getGyrValues();

    bool isAllZero = (accVal1.x == 0.0f && accVal1.y == 0.0f && accVal1.z == 0.0f &&
                      gyrVal1.x == 0.0f && gyrVal1.y == 0.0f && gyrVal1.z == 0.0f);

    if (isAllZero) {
        Serial.println("isMpuConnectedAndResponsive: FAIL - All sensor readings are zero.");
        return false;
    }

    Serial.println("isMpuConnectedAndResponsive: PASS - Sensor responsive (WhoAmI OK, not all zero).");
    return true;
}

class CalibrationCharacteristicCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        uint8_t* rxData = pCharacteristic->getData();
        size_t rxDataLength = pCharacteristic->getLength();
        uint8_t calibrationStatusValueToSend = 0;

        if (rxDataLength == 0 || rxData[0] != 1) {
            Serial.println("Invalid calibration command.");
        } else {
            Serial.println("Calibration command received. Starting process...");
            updateSystemState(STATE_CALIBRATION_IN_PROGRESS);

            if (!isMpuConnectedAndResponsive()) {
                Serial.println("MPU not responsive for calibration.");
                mpuSuccessfullyInitialized = false;
                updateSystemState(STATE_MPU_ERROR, true);
                calibrationStatusValueToSend = 0;
            } else {
                mpuSuccessfullyInitialized = true;
                Serial.println("MPU responsive. Proceeding with autoOffsets.");
                myMPU6500.setAccRange(MPU6500_ACC_RANGE_8G);
                // Corrected: Use MPU6500_GYRO_RANGE_500 for gyro range if calibrating gyro offsets
                myMPU6500.setGyrRange(MPU6500_GYRO_RANGE_500);

                myMPU6500.autoOffsets();
                Serial.println("MPU autoOffsets() completed.");

                xyzFloat accOffsets = myMPU6500.getAccOffsets();
                xyzFloat gyrOffsets = myMPU6500.getGyrOffsets();

                Serial.printf("Biases after autoOffsets: A(%.3f,%.3f,%.3f) G(%.3f,%.3f,%.3f)\n",
                    accOffsets.x, accOffsets.y, accOffsets.z,
                    gyrOffsets.x, gyrOffsets.y, gyrOffsets.z);

                if (accOffsets.x == 0.0f && accOffsets.y == 0.0f && accOffsets.z == 0.0f &&
                    gyrOffsets.x == 0.0f && gyrOffsets.y == 0.0f && gyrOffsets.z == 0.0f) {
                    Serial.println("All biases are zero after autoOffsets. Calibration likely ineffective.");
                    calibrationStatusValueToSend = 0;
                    updateSystemState(STATE_CALIBRATION_FAILED_TEMP, true);
                } else {
                    Serial.println("Calibration biases plausible.");
                    calibrationStatusValueToSend = 1;
                    updateSystemState(STATE_CALIBRATION_SUCCESS_TEMP, true);
                }
            }
        }

        if (pCalibrationStatusCharacteristic != nullptr && deviceConnected) {
            pCalibrationStatusCharacteristic->setValue(&calibrationStatusValueToSend, 1);
            pCalibrationStatusCharacteristic->notify();
            Serial.print("BLE: Final calibration status notified: "); Serial.println(calibrationStatusValueToSend);
        }
    }
};

void setup() {
    Serial.begin(115200);
    while(!Serial);
    Serial.println("\nSmart Cane ESP32 - Robust MPU & LED v7");
    updateSystemState(STATE_INITIALIZING);

    pinMode(ONBOARD_BLUE_LED_PIN, OUTPUT);
    digitalWrite(ONBOARD_BLUE_LED_PIN, LOW);

    rgbLed.begin();
    rgbLed.setBrightness(30);
    rgbLed.clear();
    rgbLed.show();

    Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
    Wire.setClock(400000);
    Serial.println("I2C Initialized.");

    Serial.println("Attempting MPU6500 initialization & responsiveness check...");

    if (myMPU6500.init()) {
        Serial.println("MPU6500_WE::init() successful.");
        // Corrected: Use MPU6500_GYRO_RANGE_500 for gyro range
        myMPU6500.setAccRange(MPU6500_ACC_RANGE_8G);
        myMPU6500.setGyrRange(MPU6500_GYRO_RANGE_500);

        if(isMpuConnectedAndResponsive()){
            Serial.println("MPU is responsive. Performing boot-time autoOffsets.");
            mpuSuccessfullyInitialized = true;
            myMPU6500.autoOffsets();
            Serial.println("Boot-time autoOffsets complete.");
            xyzFloat initialAccOffsets = myMPU6500.getAccOffsets();
            xyzFloat initialGyrOffsets = myMPU6500.getGyrOffsets();
            Serial.printf("Initial Biases: A(%.3f,%.3f,%.3f) G(%.3f,%.3f,%.3f)\n",
                initialAccOffsets.x, initialAccOffsets.y, initialAccOffsets.z,
                initialGyrOffsets.x, initialGyrOffsets.y, initialGyrOffsets.z);
        } else {
            Serial.println("MPU init() passed but isMpuConnectedAndResponsive() failed. MPU Error.");
            mpuSuccessfullyInitialized = false;
        }
    } else {
        Serial.println("MPU6500_WE::init() failed. Sensor not detected or communication error.");
        mpuSuccessfullyInitialized = false;
    }

    if (!mpuSuccessfullyInitialized) {
        updateSystemState(STATE_MPU_ERROR, true);
    }

    analogSetPinAttenuation(BATTERY_VOLTAGE_PIN, ADC_11db);

    Serial.println("Initializing BLE...");
    BLEDevice::init(DEVICE_NAME);
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    BLEService *pService = pServer->createService(SERVICE_UUID);

    pBatteryCharacteristic = pService->createCharacteristic(BATTERY_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
    pBatteryCharacteristic->addDescriptor(new BLE2902());
    uint8_t initialBattery = 50; pBatteryCharacteristic->setValue(&initialBattery, 1);

    pFallCharacteristic = pService->createCharacteristic(FALL_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    pFallCharacteristic->addDescriptor(new BLE2902());
    uint8_t initialFallStatus = 0; pFallCharacteristic->setValue(&initialFallStatus, 1);

    pCalibrationCharacteristic = pService->createCharacteristic(CALIBRATION_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_WRITE);
    pCalibrationCharacteristic->setCallbacks(new CalibrationCharacteristicCallbacks());

    pCalibrationStatusCharacteristic = pService->createCharacteristic(CALIBRATION_STATUS_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    pCalibrationStatusCharacteristic->addDescriptor(new BLE2902());
    uint8_t initialCalStatus = 0; pCalibrationStatusCharacteristic->setValue(&initialCalStatus, 1);

    pService->start();
    Serial.println("BLE Service started.");

    pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    BLEDevice::startAdvertising();
    Serial.println("BLE advertising started.");

    if (currentSystemState == STATE_INITIALIZING) {
      updateSystemState(mpuSuccessfullyInitialized ? STATE_BLE_ADVERTISING : STATE_MPU_ERROR, true);
    }

    updateBatteryLevel();
    updateLedStatus();
}

void updateSystemState(SystemState newState, bool forceUpdate /*= false*/) {
    if (!forceUpdate && currentSystemState == newState &&
        newState != STATE_CALIBRATION_SUCCESS_TEMP &&
        newState != STATE_CALIBRATION_FAILED_TEMP) {
        return;
    }
    SystemState oldState = currentSystemState;
    if ((newState == STATE_CALIBRATION_SUCCESS_TEMP || newState == STATE_CALIBRATION_FAILED_TEMP) &&
        (oldState != STATE_CALIBRATION_SUCCESS_TEMP && oldState != STATE_CALIBRATION_FAILED_TEMP)) {
        if(oldState == STATE_CALIBRATION_IN_PROGRESS) {
             previousSystemStateForTemp = deviceConnected ? STATE_BLE_CONNECTED_IDLE :
                                           (mpuSuccessfullyInitialized ? STATE_BLE_ADVERTISING : STATE_MPU_ERROR);
        } else {
            previousSystemStateForTemp = oldState;
        }
    }
    currentSystemState = newState;
    if (oldState != newState || forceUpdate) {
      Serial.print("System State Changed from "); Serial.print(oldState);
      Serial.print(" to: "); Serial.println(currentSystemState);
    }
    ledPatternLastUpdateTime = millis();
    if (newState != STATE_BLE_ADVERTISING && newState != STATE_CALIBRATION_IN_PROGRESS &&
        newState != STATE_INITIALIZING && newState != STATE_LOW_BATTERY_CONNECTED) {
        ledPulseBrightness = 0;
        ledPulseDirectionUp = true;
    }
     updateLedStatus();
}

void updateLedStatus() {
    unsigned long currentTime = millis();
    uint32_t rgbColorTarget = COLOR_OFF;
    bool blueLedTargetOn = false;
    static unsigned long tempStateEndTime = 0;

    if (currentSystemState == STATE_CALIBRATION_SUCCESS_TEMP || currentSystemState == STATE_CALIBRATION_FAILED_TEMP) {
        if (tempStateEndTime == 0) {
            tempStateEndTime = currentTime + 1500;
        }
        if (currentTime >= tempStateEndTime) {
            tempStateEndTime = 0;
            SystemState stateToRevertTo = previousSystemStateForTemp;
            updateSystemState(stateToRevertTo, true);
            return;
        }
    } else {
        tempStateEndTime = 0;
    }

    switch (currentSystemState) {
        case STATE_INITIALIZING:
            if (currentTime - ledPatternLastUpdateTime > 30) {
                ledPatternLastUpdateTime = currentTime;
                if (ledPulseDirectionUp) { ledPulseBrightness += 15; if (ledPulseBrightness >= 150) { ledPulseBrightness = 150; ledPulseDirectionUp = false; }}
                else { ledPulseBrightness -= 15; if (ledPulseBrightness <= 5) { ledPulseBrightness = 5; ledPulseDirectionUp = true; }}
            }
            rgbColorTarget = rgbLed.Color(ledPulseBrightness, ledPulseBrightness, ledPulseBrightness);
            blueLedTargetOn = false;
            break;
        case STATE_MPU_ERROR:
            rgbColorTarget = COLOR_RED;
            blueLedTargetOn = ((currentTime / 150) % 2 == 0);
            break;
        case STATE_BLE_ADVERTISING:
            if (currentTime - ledPatternLastUpdateTime > 40) {
                ledPatternLastUpdateTime = currentTime;
                if (ledPulseDirectionUp) { ledPulseBrightness += 10; if (ledPulseBrightness >= 150) { ledPulseBrightness = 150; ledPulseDirectionUp = false; }}
                else { ledPulseBrightness -= 10; if (ledPulseBrightness <= 10) { ledPulseBrightness = 10; ledPulseDirectionUp = true; }}
            }
            rgbColorTarget = rgbLed.Color(0, ledPulseBrightness, ledPulseBrightness);
            blueLedTargetOn = ((currentTime / 1000) % 2 == 0);
            break;
        case STATE_BLE_CONNECTING:
            rgbColorTarget = ((currentTime / 300) % 2 == 0) ? COLOR_GREEN : COLOR_OFF;
            blueLedTargetOn = ((currentTime / 600) % 2 == 0);
            break;
        case STATE_BLE_CONNECTED_IDLE:
            rgbColorTarget = COLOR_BLUE;
            blueLedTargetOn = true;
            break;
        case STATE_CALIBRATION_IN_PROGRESS:
            if (currentTime - ledPatternLastUpdateTime > 35) {
                ledPatternLastUpdateTime = currentTime;
                if (ledPulseDirectionUp) { ledPulseBrightness += 12; if (ledPulseBrightness >= 200) { ledPulseBrightness = 200; ledPulseDirectionUp = false; }}
                else { ledPulseBrightness -= 12; if (ledPulseBrightness <= 20) { ledPulseBrightness = 20; ledPulseDirectionUp = true; }}
            }
            rgbColorTarget = rgbLed.Color(ledPulseBrightness, ledPulseBrightness, 0);
            blueLedTargetOn = true;
            break;
        case STATE_CALIBRATION_SUCCESS_TEMP:
            rgbColorTarget = COLOR_GREEN;
            blueLedTargetOn = true;
            break;
        case STATE_CALIBRATION_FAILED_TEMP:
            rgbColorTarget = COLOR_RED;
            blueLedTargetOn = true;
            break;
        case STATE_FALL_DETECTED_COOLDOWN:
            rgbColorTarget = COLOR_ORANGE;
            blueLedTargetOn = ((currentTime / 200) % 2 == 0);
            break;
        case STATE_LOW_BATTERY_CONNECTED:
             if (currentTime - ledPatternLastUpdateTime > 60) {
                ledPatternLastUpdateTime = currentTime;
                if (ledPulseDirectionUp) { ledPulseBrightness += 8; if (ledPulseBrightness >= 120) { ledPulseBrightness = 120; ledPulseDirectionUp = false; }}
                else { ledPulseBrightness -= 8; if (ledPulseBrightness <= 5) { ledPulseBrightness = 5; ledPulseDirectionUp = true; }}
            }
            rgbColorTarget = rgbLed.Color(ledPulseBrightness, 0, 0);
            blueLedTargetOn = true;
            break;
        default:
            rgbColorTarget = COLOR_MAGENTA;
            blueLedTargetOn = true;
            break;
    }
    rgbLed.setPixelColor(0, rgbColorTarget);
    rgbLed.show();
    digitalWrite(ONBOARD_BLUE_LED_PIN, blueLedTargetOn ? HIGH : LOW);
}

void updateBatteryLevel() {
    int adcValue = analogRead(BATTERY_VOLTAGE_PIN);
    double voltageAtPin = (adcValue / ADC_RESOLUTION) * ADC_VREF;
    double batteryVoltage = voltageAtPin * 2.0;
    batteryVoltage = constrain(batteryVoltage, MIN_BATTERY_VOLTAGE, MAX_BATTERY_VOLTAGE);
    currentBatteryPercentage = (uint8_t)(((batteryVoltage - MIN_BATTERY_VOLTAGE) / (MAX_BATTERY_VOLTAGE - MIN_BATTERY_VOLTAGE)) * 100.0f);
    currentBatteryPercentage = constrain(currentBatteryPercentage, 0, 100);

    if (pBatteryCharacteristic != nullptr && deviceConnected) {
        pBatteryCharacteristic->setValue(&currentBatteryPercentage, 1);
        pBatteryCharacteristic->notify();
    }
}

void loop() {
    unsigned long currentTime = millis();
    if (startAdvertisingPending && !deviceConnected) {
        startAdvertisingPending = false; delay(100); BLEDevice::startAdvertising();
        Serial.println("Advertising restarted.");
    }

    if (mpuSuccessfullyInitialized) {
        if (currentTime - lastFallCheckTime >= FALL_CHECK_INTERVAL_MS) {
            lastFallCheckTime = currentTime;
            if (currentSystemState != STATE_CALIBRATION_SUCCESS_TEMP &&
                currentSystemState != STATE_CALIBRATION_FAILED_TEMP &&
                currentSystemState != STATE_MPU_ERROR &&
                currentSystemState != STATE_CALIBRATION_IN_PROGRESS &&
                currentSystemState != STATE_INITIALIZING ) {

                xyzFloat gValue = myMPU6500.getGValues();
                float resultantG = myMPU6500.getResultantG(gValue);
                bool fallCooldownActive = (currentTime - lastFallTriggerTime < FALL_COOLDOWN_MS);

                if (fallCooldownActive) {
                    if (currentSystemState != STATE_FALL_DETECTED_COOLDOWN) {
                         updateSystemState(STATE_FALL_DETECTED_COOLDOWN, true);
                    }
                } else {
                    if (currentSystemState == STATE_FALL_DETECTED_COOLDOWN) {
                        updateSystemState(deviceConnected ? STATE_BLE_CONNECTED_IDLE : STATE_BLE_ADVERTISING, true);
                    }
                    bool fallConditionMet = (resultantG < SIMPLIFIED_LOW_G_THRESHOLD) || (resultantG > SIMPLIFIED_HIGH_G_THRESHOLD);
                    if (fallConditionMet) {
                        Serial.print("!!! FALL DETECTED !!! Resultant G: "); Serial.println(resultantG, 2);
                        lastFallTriggerTime = currentTime;
                        updateSystemState(STATE_FALL_DETECTED_COOLDOWN, true);

                        if (deviceConnected && pFallCharacteristic != nullptr) {
                            uint8_t fallVal = 1; pFallCharacteristic->setValue(&fallVal, 1); pFallCharacteristic->notify();
                            Serial.println("BLE: Fall Detected notification sent.");
                        }
                    }
                }
            }
        }
    } else {
        if (currentSystemState != STATE_MPU_ERROR && currentSystemState != STATE_INITIALIZING ) {
             updateSystemState(STATE_MPU_ERROR, true);
        }
    }

    if (currentTime - lastBatteryUpdateTime >= batteryUpdateIntervalMs) {
        lastBatteryUpdateTime = currentTime;
        updateBatteryLevel();
    }
    updateLedStatus();
    delay(20);
}