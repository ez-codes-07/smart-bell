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
static constexpr uint32_t SAMPLE_PERIOD_US = 10000;  // 100 Hz target
// true: print every CSV row over USB serial at 921600 baud, for live analysis on a
// computer (tools/live). false: print every 10th row at 115200 for a serial monitor.
static constexpr bool SERIAL_FULL_RATE = true;

uint32_t nextSampleDueUs = 0;
uint32_t previousSampleTimeUs = 0;

DFRobot_BMX160 bmx160(&Wire);
BLECharacteristic* dataCharacteristic = nullptr;

class ServerCallbacks : public BLEServerCallbacks {
  void onDisconnect(BLEServer* server) override {
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(SERIAL_FULL_RATE ? 921600 : 115200);
  delay(1000);

  Wire.begin(SDA_PIN, SCL_PIN);

  if (!bmx160.begin(0x69)) {
    Serial.println("BMX160 not found. Check wiring and I2C address.");
    while (true) delay(1000);
  }

  // DFRobot_BMX160::begin() never writes the gyro range register, so the chip stays
  // at its reset range (±2000 °/s) while getAllData() scales with the ±250 °/s factor:
  // every gyro reading came out 8x too small, which made the app's position estimate
  // run away whenever the dumbbell tilted. setGyroRange() writes the register and the
  // matching scale together; it must run after begin(), which soft-resets the chip.
  // ±1000 °/s leaves headroom for fast curls at 0.03 °/s resolution.
  bmx160.setGyroRange(eGyroRange_1000DPS);
  // The accelerometer's reset range (±2 g) already matches the library's default
  // m/s² scale. Do not call setAccelRange(): it switches to a ×10 (not ×9.8) scale.

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

  nextSampleDueUs = micros();

  Serial.println("Advertising as SmartBell. Scan from the app's Device tab.");
  Serial.println("ax,ay,az,gx,gy,gz,dt_s");
}

void loop() {
  // Schedule reads against a 10 ms clock instead of adding a fixed delay after BLE work.
  uint32_t nowUs = micros();
  int32_t waitUs = static_cast<int32_t>(nextSampleDueUs - nowUs);
  if (waitUs > 0) {
    delayMicroseconds(static_cast<uint32_t>(waitUs));
  }

  const uint32_t sampleTimeUs = micros();
  const uint32_t deltaTimeUs = previousSampleTimeUs == 0
      ? SAMPLE_PERIOD_US
      : sampleTimeUs - previousSampleTimeUs;
  previousSampleTimeUs = sampleTimeUs;
  const float deltaTimeSeconds = deltaTimeUs / 1000000.0f;

  sBmx160SensorData_t accel;
  sBmx160SensorData_t gyro;

  bmx160.getAllData(nullptr, &gyro, &accel);

  // Acceleration: m/s^2; gyroscope: degrees/second; dt_s: measured sample interval.
  char row[100];
  snprintf(
    row, sizeof(row),
    "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.6f\n",
    accel.x, accel.y, accel.z,
    gyro.x, gyro.y, gyro.z,
    static_cast<double>(deltaTimeSeconds)
  );

  dataCharacteristic->setValue((uint8_t*)row, strlen(row));
  dataCharacteristic->notify();

  // Full rate feeds tools/live (~6 kB/s fits easily at 921600 baud); otherwise
  // throttle so diagnostics don't dominate the 100 Hz loop.
  static uint8_t serialDivider = 0;
  if (SERIAL_FULL_RATE || ++serialDivider >= 10) {
    Serial.print(row);
    serialDivider = 0;
  }

  nextSampleDueUs += SAMPLE_PERIOD_US;
  const uint32_t afterSendUs = micros();
  if (static_cast<int32_t>(afterSendUs - nextSampleDueUs) >= 0) {
    // If an I2C read or BLE notification overruns the next slot, resume from now and
    // report the longer measured interval in the next CSV row.
    nextSampleDueUs = afterSendUs + SAMPLE_PERIOD_US;
  }
}
