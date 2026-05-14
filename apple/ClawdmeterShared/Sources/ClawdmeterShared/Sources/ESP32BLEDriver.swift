#if canImport(CoreBluetooth)
import Foundation
import CoreBluetooth
import OSLog
#endif

// MARK: - State machine (transport-agnostic, unit-testable per plan E9)

/// 8 states per plan E5 + codex #10/#11 (added `disconnected`, separated bluetooth-off auto-recovery).
public enum BLEState: String, Sendable, Equatable {
    case idle
    case bluetoothOff
    case bluetoothUnauthorized
    case scanning
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case connected
    case disconnected
    case error
}

/// Events the state machine accepts (from CoreBluetooth callbacks or test mock).
public enum BLEEvent: Sendable, Equatable {
    case bluetoothStateChanged(BluetoothPowerState)
    case startScanRequested
    case peripheralFound
    case connectionTimeout
    case didConnect
    case didFailToConnect
    case servicesDiscovered
    case servicesTimeout
    case characteristicsDiscovered
    case characteristicsTimeout
    case didDisconnect
    case reconnectAttempt
    case maxReconnectsExceeded
    case userReset
}

public enum BluetoothPowerState: Sendable, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// Side-effects the state machine asks its host (real driver or test) to perform.
public enum BLEAction: Sendable, Equatable {
    case startScanning
    case stopScanning
    case connect
    case disconnect
    case discoverServices
    case discoverCharacteristics
    case scheduleReconnect(after: TimeInterval)
    case startTimeout(BLETimeout)
    case cancelAllTimeouts
    case log(String)
}

public enum BLETimeout: String, Sendable, Equatable {
    case connecting
    case servicesDiscovery
    case characteristicsDiscovery
}

/// Pure state machine. Owns no I/O. Owners feed events; consume actions.
public final class BLEStateMachine: @unchecked Sendable {

    public private(set) var state: BLEState = .idle
    public private(set) var reconnectAttempts: Int = 0
    public let maxReconnectAttempts: Int

    /// Exponential backoff schedule for reconnects (seconds).
    /// Codex flagged "exp backoff retry; cap 60s; max 5 attempts" — pre-compute the
    /// schedule so it's transparent + testable.
    public static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]

    public init(maxReconnectAttempts: Int = 5) {
        self.maxReconnectAttempts = maxReconnectAttempts
    }

    /// Returns the actions the host must execute for this transition.
    /// State changes are visible via `state` after the call returns.
    @discardableResult
    public func handle(_ event: BLEEvent) -> [BLEAction] {
        let prev = state
        var actions: [BLEAction] = []
        actions.append(.log("BLE event \(event) in state \(prev.rawValue)"))

        switch (state, event) {
        // Bluetooth power transitions — top-priority (codex #11: poweredOff auto-recovers)
        case (_, .bluetoothStateChanged(let power)):
            switch power {
            case .poweredOn:
                if state == .bluetoothOff {
                    state = .idle
                    actions.append(.log("Bluetooth powered on — auto-resuming from bluetoothOff"))
                    actions.append(.startScanning)
                    state = .scanning
                }
                // poweredOn from .idle is the normal path; just stay in current state.
            case .poweredOff, .resetting, .unknown, .unsupported:
                state = .bluetoothOff
                actions.append(.cancelAllTimeouts)
                actions.append(.stopScanning)
            case .unauthorized:
                state = .bluetoothUnauthorized
                actions.append(.cancelAllTimeouts)
                actions.append(.stopScanning)
            }

        // User-initiated reset returns to idle from any state.
        case (_, .userReset):
            state = .idle
            reconnectAttempts = 0
            actions.append(.cancelAllTimeouts)
            actions.append(.stopScanning)

        // From idle: start scanning
        case (.idle, .startScanRequested):
            state = .scanning
            actions.append(.startScanning)

        // From scanning: peripheral found → connecting
        case (.scanning, .peripheralFound):
            state = .connecting
            actions.append(.stopScanning)
            actions.append(.connect)
            actions.append(.startTimeout(.connecting))

        // From connecting: success → discovering services
        case (.connecting, .didConnect):
            state = .discoveringServices
            actions.append(.cancelAllTimeouts)
            actions.append(.discoverServices)
            actions.append(.startTimeout(.servicesDiscovery))
            reconnectAttempts = 0

        // From connecting: failure → error → schedule reconnect
        case (.connecting, .didFailToConnect),
             (.connecting, .connectionTimeout):
            actions.append(contentsOf: scheduleReconnectActions())
            state = scheduleReconnectNextState()

        // From discoveringServices: success → discover chars
        case (.discoveringServices, .servicesDiscovered):
            state = .discoveringCharacteristics
            actions.append(.cancelAllTimeouts)
            actions.append(.discoverCharacteristics)
            actions.append(.startTimeout(.characteristicsDiscovery))

        // From discoveringServices: timeout → error
        case (.discoveringServices, .servicesTimeout):
            actions.append(contentsOf: scheduleReconnectActions())
            state = scheduleReconnectNextState()

        // From discoveringCharacteristics: success → connected
        case (.discoveringCharacteristics, .characteristicsDiscovered):
            state = .connected
            actions.append(.cancelAllTimeouts)

        // From discoveringCharacteristics: timeout → error
        case (.discoveringCharacteristics, .characteristicsTimeout):
            actions.append(contentsOf: scheduleReconnectActions())
            state = scheduleReconnectNextState()

        // From connected: peer disconnect → schedule reconnect
        case (.connected, .didDisconnect):
            state = .disconnected
            actions.append(contentsOf: scheduleReconnectActions())
            state = scheduleReconnectNextState()

        // From disconnected: reconnect attempt fires → back to scanning
        case (.disconnected, .reconnectAttempt):
            state = .scanning
            actions.append(.startScanning)

        // From disconnected: exceeded max attempts → error
        case (.disconnected, .maxReconnectsExceeded),
             (.error, .maxReconnectsExceeded):
            state = .error
            actions.append(.cancelAllTimeouts)
            actions.append(.stopScanning)

        // Unhandled in current state — log and ignore.
        default:
            actions.append(.log("Unhandled event \(event) in state \(prev.rawValue) (ignored)"))
        }

        if prev != state {
            actions.append(.log("State \(prev.rawValue) → \(state.rawValue)"))
        }
        return actions
    }

    private func scheduleReconnectActions() -> [BLEAction] {
        if reconnectAttempts >= maxReconnectAttempts {
            return [.cancelAllTimeouts, .log("Max reconnect attempts exceeded (\(maxReconnectAttempts))")]
        }
        let backoff = Self.backoffSchedule[min(reconnectAttempts, Self.backoffSchedule.count - 1)]
        reconnectAttempts += 1
        return [.cancelAllTimeouts, .scheduleReconnect(after: backoff)]
    }

    private func scheduleReconnectNextState() -> BLEState {
        reconnectAttempts > maxReconnectAttempts ? .error : .disconnected
    }
}

// MARK: - CoreBluetooth wrapper (Mac-only V1 surface; iOS/watch don't drive ESP32)

#if canImport(CoreBluetooth) && os(macOS)

public final class ESP32BLEDriver: NSObject, @unchecked Sendable {

    /// GATT UUIDs from firmware/src/ble.h.
    public static let serviceUUID = CBUUID(string: "4c41555a-4465-7669-6365-000000000001")
    public static let rxCharUUID = CBUUID(string: "4c41555a-4465-7669-6365-000000000002")
    public static let txCharUUID = CBUUID(string: "4c41555a-4465-7669-6365-000000000003")
    public static let reqCharUUID = CBUUID(string: "4c41555a-4465-7669-6365-000000000004")

    public let stateMachine: BLEStateMachine
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "ESP32BLEDriver")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var timeouts: [BLETimeout: DispatchWorkItem] = [:]
    private var reconnectTask: DispatchWorkItem?

    /// Stream of state-machine state changes for SwiftUI binding.
    public let stateUpdates: AsyncStream<BLEState>
    private let stateContinuation: AsyncStream<BLEState>.Continuation

    public init(stateMachine: BLEStateMachine = BLEStateMachine()) {
        self.stateMachine = stateMachine
        var continuation: AsyncStream<BLEState>.Continuation!
        self.stateUpdates = AsyncStream<BLEState> { c in continuation = c }
        self.stateContinuation = continuation
        super.init()
    }

    public func start() {
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    public func reset() {
        process(events: [.userReset])
    }

    /// Push `UsageData` JSON payload to the ESP32 RX characteristic.
    /// Matches the firmware's expected shape (see daemon/claude-usage-daemon.sh lines 225-232).
    public func writeUsage(_ usage: UsageData) {
        guard stateMachine.state == .connected,
              let peripheral = peripheral,
              let rx = rxChar else {
            logger.warning("writeUsage skipped — not connected (state=\(self.stateMachine.state.rawValue))")
            return
        }
        let payload: [String: Any] = [
            "s": usage.sessionPct,
            "sr": usage.sessionResetMins,
            "w": usage.weeklyPct,
            "wr": usage.weeklyResetMins,
            "st": usage.status.rawValue,
            "ok": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        peripheral.writeValue(data, for: rx, type: .withResponse)
    }

    // MARK: - State machine dispatch

    private func process(events: [BLEEvent]) {
        for event in events {
            let actions = stateMachine.handle(event)
            stateContinuation.yield(stateMachine.state)
            for action in actions {
                execute(action)
            }
        }
    }

    private func execute(_ action: BLEAction) {
        switch action {
        case .startScanning:
            central?.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        case .stopScanning:
            central?.stopScan()
        case .connect:
            if let peripheral { central?.connect(peripheral, options: nil) }
        case .disconnect:
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        case .discoverServices:
            peripheral?.discoverServices([Self.serviceUUID])
        case .discoverCharacteristics:
            guard let service = peripheral?.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral?.discoverCharacteristics(
                [Self.rxCharUUID, Self.txCharUUID, Self.reqCharUUID],
                for: service
            )
        case .scheduleReconnect(let after):
            scheduleReconnect(after: after)
        case .startTimeout(let kind):
            startTimeout(kind)
        case .cancelAllTimeouts:
            timeouts.values.forEach { $0.cancel() }
            timeouts.removeAll()
        case .log(let message):
            logger.debug("\(message)")
        }
    }

    private func startTimeout(_ kind: BLETimeout) {
        let duration: TimeInterval = {
            switch kind {
            case .connecting: return 5
            case .servicesDiscovery: return 5
            case .characteristicsDiscovery: return 5
            }
        }()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let event: BLEEvent = {
                switch kind {
                case .connecting: return .connectionTimeout
                case .servicesDiscovery: return .servicesTimeout
                case .characteristicsDiscovery: return .characteristicsTimeout
                }
            }()
            self.process(events: [event])
        }
        timeouts[kind] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func scheduleReconnect(after: TimeInterval) {
        reconnectTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.process(events: [.reconnectAttempt])
        }
        reconnectTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }
}

extension ESP32BLEDriver: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let power: BluetoothPowerState = {
            switch central.state {
            case .poweredOn: return .poweredOn
            case .poweredOff: return .poweredOff
            case .unauthorized: return .unauthorized
            case .resetting: return .resetting
            case .unsupported: return .unsupported
            case .unknown: return .unknown
            @unknown default: return .unknown
            }
        }()
        process(events: [.bluetoothStateChanged(power)])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        process(events: [.peripheralFound])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        process(events: [.didConnect])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        process(events: [.didFailToConnect])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        process(events: [.didDisconnect])
    }
}

extension ESP32BLEDriver: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            process(events: [.servicesTimeout])
            return
        }
        process(events: [.servicesDiscovered])
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            process(events: [.characteristicsTimeout])
            return
        }
        if let chars = service.characteristics, chars.contains(where: { $0.uuid == Self.rxCharUUID }) {
            rxChar = chars.first { $0.uuid == Self.rxCharUUID }
            process(events: [.characteristicsDiscovered])
        } else {
            process(events: [.characteristicsTimeout])
        }
    }
}

#endif
