import Foundation
@preconcurrency import CoreBluetooth
import Combine

/// CoreBluetooth manager for Limitless Pendant.
///
/// Limitless BLE protocol:
///   Service:  632DE001-604C-446B-A80F-7963E950F3FB
///   TX char:  632DE002 (write commands to pendant)
///   RX char:  632DE003 (receive audio/responses from pendant)
///   Battery:  standard 0x180F / 0x2A19
///
/// Handshake: subscribe RX notify → write timeSync to TX → write enableDataStream to TX → audio flows on RX.
final class PendantBLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    // Limitless Pendant UUIDs
    private static let serviceUUIDString   = "632DE001-604C-446B-A80F-7963E950F3FB"
    private static let txCharUUIDString    = "632DE002-604C-446B-A80F-7963E950F3FB"
    private static let rxCharUUIDString    = "632DE003-604C-446B-A80F-7963E950F3FB"
    private static let batteryServiceUUID  = "180F"
    private static let batteryLevelUUID    = "2A19"
    private static let restoreIdentifier   = "com.tokdown-mobile.ble-central"

    /// Known pendant name prefixes
    private static let knownPrefixes = ["Pendant", "Friend", "Omi", "Limitless", "OpenGlass"]

    enum ConnectionState: Sendable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var peripheralName: String?
    @Published private(set) var isStreaming = false

    /// Decoded Opus frames (raw Opus data, no protobuf wrapper)
    let opusFrames = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var needsServiceDiscovery = false
    private let reassembler = FragmentReassembler()

    // MARK: - Public API

    func startScanning() {
        if let centralManager {
            if centralManager.state == .poweredOn {
                beginScan(using: centralManager)
            }
            return
        }

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    func stopScanning() {
        centralManager?.stopScan()
        updateConnectionState(.disconnected)
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        resetPeripheralState()
        updateConnectionState(.disconnected)
    }

    // MARK: - Private

    private func resetPeripheralState() {
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        reassembler.reset()
        LimitlessCommand.reset()
        updateStreaming(false)
    }

    private func beginScan(using centralManager: CBCentralManager) {
        updateConnectionState(.scanning)
        centralManager.scanForPeripherals(
            withServices: nil,
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

    /// After RX notify is confirmed, send the handshake commands to start audio streaming.
    private func startStreamingHandshake() {
        guard let peripheral, let tx = txCharacteristic else { return }

        let writeType: CBCharacteristicWriteType = .withResponse

        // Step 1: Wait 1s after subscribe, then send time sync
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let peripheral = self.peripheral, let tx = self.txCharacteristic else { return }
            peripheral.writeValue(LimitlessCommand.timeSync(), for: tx, type: writeType)

            // Step 2: Wait 1s more, then enable data stream
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let peripheral = self.peripheral, let tx = self.txCharacteristic else { return }
                peripheral.writeValue(LimitlessCommand.enableDataStream(), for: tx, type: writeType)
                self.updateStreaming(true)
            }
        }
    }

    /// Process a raw BLE notification from the RX characteristic.
    private func handleRxData(_ data: Data) {
        guard let payload = reassembler.process(notification: data) else { return }

        let frames = OpusFrameExtractor.extract(from: payload)
        for frame in frames {
            opusFrames.send(frame)
        }
    }

    // MARK: - Main-thread property updates

    private func updateConnectionState(_ state: ConnectionState) {
        if Thread.isMainThread { connectionState = state }
        else { DispatchQueue.main.async { [weak self] in self?.connectionState = state } }
    }

    private func updatePeripheralName(_ name: String?) {
        if Thread.isMainThread { peripheralName = name }
        else { DispatchQueue.main.async { [weak self] in self?.peripheralName = name } }
    }

    private func updateBatteryLevel(_ level: Int?) {
        if Thread.isMainThread { batteryLevel = level }
        else { DispatchQueue.main.async { [weak self] in self?.batteryLevel = level } }
    }

    private func updateStreaming(_ value: Bool) {
        if Thread.isMainThread { isStreaming = value }
        else { DispatchQueue.main.async { [weak self] in self?.isStreaming = value } }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if needsServiceDiscovery, let peripheral, peripheral.state == .connected {
                needsServiceDiscovery = false
                peripheral.discoverServices(nil)
            } else if let peripheral, peripheral.state == .connecting {
                // Restored peripheral still connecting — wait for didConnect
            } else {
                beginScan(using: central)
            }
        case .poweredOff, .unauthorized, .unsupported:
            updateConnectionState(.disconnected)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            peripheral = restored
            restored.delegate = self
            updatePeripheralName(restored.name)
            switch restored.state {
            case .connected:
                updateConnectionState(.connected)
                needsServiceDiscovery = true
            case .connecting:
                updateConnectionState(.connecting)
            default:
                updateConnectionState(.disconnected)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advName,
              Self.knownPrefixes.contains(where: { name.hasPrefix($0) }) else {
            return
        }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        updatePeripheralName(name)
        updateConnectionState(.connecting)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        updateConnectionState(.connected)
        updatePeripheralName(peripheral.name)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        updateConnectionState(.disconnected)
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetPeripheralState()
        updateConnectionState(.disconnected)
        scheduleReconnect()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            let uuid = char.uuid.uuidString.uppercased()

            if uuid == Self.txCharUUIDString {
                txCharacteristic = char
            } else if uuid == Self.rxCharUUIDString {
                rxCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }

            if uuid == Self.batteryLevelUUID {
                peripheral.readValue(for: char)
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        if uuid == Self.rxCharUUIDString, characteristic.isNotifying, error == nil {
            startStreamingHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()

        if uuid == Self.batteryLevelUUID {
            updateBatteryLevel(data.first.map(Int.init))
        } else if uuid == Self.rxCharUUIDString {
            handleRxData(data)
        }
    }
}
