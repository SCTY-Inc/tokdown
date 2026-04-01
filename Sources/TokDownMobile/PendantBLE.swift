import Foundation
import CoreBluetooth
import Combine

/// CoreBluetooth manager for Limitless Pendant (Omi-compatible BLE protocol).
///
/// Service UUID: 19B10000-E8F2-537E-4F6C-D104768A1214
/// Characteristics:
///   - Audio Data (NOTIFY): 19B10001-E8F2-537E-4F6C-D104768A1214
///   - Codec Type (READ):   19B10002-E8F2-537E-4F6C-D104768A1214
///   - Battery (standard):  0x180F / 0x2A19
final class PendantBLE: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - UUIDs

    static let serviceUUID = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    static let audioDataUUID = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    static let codecTypeUUID = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelUUID = CBUUID(string: "2A19")

    private static let restoreIdentifier = "com.tokdown-mobile.ble-central"

    // MARK: - Published state

    enum ConnectionState: Sendable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var batteryLevel: Int?
    @Published var peripheralName: String?

    /// Raw audio packets from BLE notify -- consumers subscribe via Combine
    let audioPackets = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var reconnectWorkItem: DispatchWorkItem?

    // MARK: - Public API

    /// Initialize BLE central manager and start scanning
    func startScanning() {
        guard centralManager == nil else {
            if centralManager.state == .poweredOn {
                beginScan()
            }
            return
        }
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreStateKey: Self.restoreIdentifier]
        )
    }

    /// Stop scanning for peripherals
    func stopScanning() {
        centralManager?.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    /// Disconnect from the pendant
    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        connectionState = .disconnected
    }

    // MARK: - Private

    private func beginScan() {
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startScanning()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - CBCentralManagerDelegate

extension PendantBLE: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff, .unauthorized, .unsupported:
            connectionState = .disconnected
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            peripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                connectionState = .connected
                peripheralName = restored.name
                restored.discoverServices([Self.serviceUUID, Self.batteryServiceUUID])
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheralName = peripheral.name
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        connectionState = .connected
        peripheralName = peripheral.name
        peripheral.discoverServices([Self.serviceUUID, Self.batteryServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = .disconnected
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = .disconnected
        self.peripheral = nil
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension PendantBLE: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.audioDataUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.codecTypeUUID:
                peripheral.readValue(for: characteristic)
            case Self.batteryLevelUUID:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.audioDataUUID:
            audioPackets.send(data)
        case Self.batteryLevelUUID:
            if let firstByte = data.first {
                DispatchQueue.main.async {
                    self.batteryLevel = Int(firstByte)
                }
            }
        default:
            break
        }
    }
}
