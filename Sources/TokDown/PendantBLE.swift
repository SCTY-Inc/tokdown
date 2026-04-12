import Foundation
@preconcurrency import CoreBluetooth
import Observation

/// CoreBluetooth manager for Limitless Pendant.
///
/// Limitless BLE protocol:
///   Service:  632DE001-604C-446B-A80F-7963E950F3FB
///   TX char:  632DE002 (write commands to pendant)
///   RX char:  632DE003 (receive audio/responses from pendant)
///   Battery:  standard 0x180F / 0x2A19
///
/// Handshake: subscribe RX notify → write timeSync to TX → write enableDataStream to TX → audio flows on RX.
///
/// Thread safety: CBCentralManager is initialized with queue: nil, dispatching all delegate
/// callbacks on the main queue. All property mutations and SwiftUI access also occur on main.
/// @unchecked Sendable is safe under this invariant.
@Observable
final class PendantBLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    // Limitless Pendant UUIDs
    private static let serviceUUIDString   = "632DE001-604C-446B-A80F-7963E950F3FB"
    private static let txCharUUIDString    = "632DE002-604C-446B-A80F-7963E950F3FB"
    private static let rxCharUUIDString    = "632DE003-604C-446B-A80F-7963E950F3FB"
    private static let batteryServiceUUID  = "180F"
    private static let batteryLevelUUID    = "2A19"
    private static let restoreIdentifier   = "com.tokdown.ble-central"

    /// Known pendant name prefixes
    private static let knownPrefixes = ["Pendant", "Friend", "Omi", "Limitless", "OpenGlass"]

    enum ConnectionState: Sendable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChanged?(connectionState) }
    }
    private(set) var batteryLevel: Int?
    private(set) var peripheralName: String?
    private(set) var isStreaming = false

    /// Callback for connection state changes (used by SessionManager for disconnect handling).
    var onConnectionStateChanged: ((ConnectionState) -> Void)?

    private var opusFrameContinuation: AsyncStream<Data>.Continuation?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var needsServiceDiscovery = false
    private var handshakeComplete = false
    private var reconnectDelay: TimeInterval = 2
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
        connectionState = .disconnected
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        resetPeripheralState()
        connectionState = .disconnected
    }

    /// Create a new AsyncStream of Opus frames and enable the pendant data stream.
    /// If handshake hasn't completed yet, defers enableDataStream until it does.
    func startOpusStream() -> AsyncStream<Data> {
        opusFrameContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(100))
        opusFrameContinuation = continuation
        if handshakeComplete {
            enableStreaming()
        }
        // If not yet complete, completeHandshake() will call enableStreaming()
        // when it finishes and sees opusFrameContinuation is non-nil.
        return stream
    }

    /// Disable the pendant data stream and end the Opus frame stream.
    func stopOpusStream() {
        disableStreaming()
        opusFrameContinuation?.finish()
        opusFrameContinuation = nil
    }

    // MARK: - Private

    private func resetPeripheralState() {
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        reassembler.reset()
        LimitlessCommand.reset()
        handshakeComplete = false
        isStreaming = false
    }

    private func beginScan(using centralManager: CBCentralManager) {
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let delay = reconnectDelay
        let work = DispatchWorkItem { [weak self] in
            self?.startScanning()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    /// After RX notify is confirmed, send timeSync to complete the handshake.
    /// If a recording stream is already waiting (opusFrameContinuation non-nil),
    /// automatically enables data streaming after timeSync.
    private func completeHandshake() {
        guard peripheral != nil, txCharacteristic != nil else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let peripheral = self.peripheral, let tx = self.txCharacteristic else { return }
            peripheral.writeValue(LimitlessCommand.timeSync(), for: tx, type: .withResponse)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.handshakeComplete = true
                // If a recording is already in progress, enable streaming now
                if self.opusFrameContinuation != nil {
                    self.enableStreaming()
                }
            }
        }
    }

    /// Send enableDataStream to pendant — call when recording starts.
    private func enableStreaming() {
        guard let peripheral, let tx = txCharacteristic else { return }
        peripheral.writeValue(LimitlessCommand.enableDataStream(), for: tx, type: .withResponse)
        isStreaming = true
    }

    /// Send disableDataStream to pendant — call when recording stops.
    private func disableStreaming() {
        guard let peripheral, let tx = txCharacteristic else { return }
        peripheral.writeValue(LimitlessCommand.disableDataStream(), for: tx, type: .withResponse)
        isStreaming = false
    }

    /// Process a raw BLE notification from the RX characteristic.
    private func handleRxData(_ data: Data) {
        guard let payload = reassembler.process(notification: data) else { return }

        let frames = OpusFrameExtractor.extract(from: payload)
        for frame in frames {
            opusFrameContinuation?.yield(frame)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if needsServiceDiscovery, let peripheral, peripheral.state == .connected {
                needsServiceDiscovery = false
                peripheral.discoverServices(nil)
            } else if let p = self.peripheral, p.state == .connecting {
                // Restored peripheral still connecting — wait for didConnect
            } else {
                beginScan(using: central)
            }
        case .poweredOff, .unauthorized, .unsupported:
            connectionState = .disconnected
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            peripheral = restored
            restored.delegate = self
            peripheralName = restored.name
            switch restored.state {
            case .connected:
                connectionState = .connected
                needsServiceDiscovery = true
            case .connecting:
                connectionState = .connecting
            default:
                connectionState = .disconnected
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
        peripheralName = name
        connectionState = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 2
        peripheral.delegate = self
        connectionState = .connected
        peripheralName = peripheral.name
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetPeripheralState()
        connectionState = .disconnected
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
            completeHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()

        if uuid == Self.batteryLevelUUID {
            batteryLevel = data.first.map(Int.init)
        } else if uuid == Self.rxCharUUIDString {
            handleRxData(data)
        }
    }
}
