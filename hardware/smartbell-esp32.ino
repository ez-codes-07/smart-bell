#include <Arduino.h>
#include <Wire.h>
#include <DFRobot_BMX160.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

static constexpr char DEVICE_NAME[] = "SmartBell";
static constexpr char SERVICE_UUID[] = "7b7e0001-9d8b-4f2a-a2b0-5c4e1a000001";
static constexpr char DATA_UUID[]    = "7b7e0002-9d8b-4f2a-a2b0-5c4e1a000001";

const int SDA_PIN = 21;
const int SCL_PIN = 22;

DFRobot_BMX160 bmx160(&Wire);
BLECharacteristic* dataCharacteristic = nullptr;

class ServerCallbacks : public BLEServerCallbacks {
  void onDisconnect(BLEServer* server) override {
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(SDA_PIN, SCL_PIN);

  if (!bmx160.begin(0x69)) {
    Serial.println("BMX160 not found. Check wiring and I2C address.");
    while (true) delay(1000);
  }

  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(100);

  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(SERVICE_UUID);
  dataCharacteristic = service->createCharacteristic(
    DATA_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  dataCharacteristic->addDescriptor(new BLE2902());
  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();

  Serial.println("Advertising as SmartBell. Scan from the app's Device tab.");
  Serial.println("Ax,ay,az,gx,gy,gz");
}

void loop() {
  sBmx160SensorData_t accel;
  sBmx160SensorData_t gyro;

  bmx160.getAllData(nullptr, &gyro, &accel);

  // Acceleration: m/s^2; gyroscope: degrees/second.
  char row[100];
  snprintf(
    row, sizeof(row),
    "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
    accel.x, accel.y, accel.z,
    gyro.x, gyro.y, gyro.z
  );

  dataCharacteristic->setValue((uint8_t*)row, strlen(row));
  dataCharacteristic->notify();

  Serial.print(row);
  delay(50);  // About 20 samples per second
}