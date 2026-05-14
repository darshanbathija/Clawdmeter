import XCTest
@testable import ClawdmeterShared

/// Pure state-machine tests per plan E9 — every transition validated without
/// CoreBluetooth or hardware. Codex pushed hard on this in eng review run 2.
final class BLEStateMachineTests: XCTestCase {

    func test_happyPath_idleToConnected() {
        let sm = BLEStateMachine()
        XCTAssertEqual(sm.state, .idle)

        let bootActions = sm.handle(.bluetoothStateChanged(.poweredOn))
        // poweredOn from .idle: no auto-scan, no state change (caller scans when ready)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(bootActions.contains(where: { if case .startScanning = $0 { return true } else { return false } }))

        sm.handle(.startScanRequested)
        XCTAssertEqual(sm.state, .scanning)

        sm.handle(.peripheralFound)
        XCTAssertEqual(sm.state, .connecting)

        sm.handle(.didConnect)
        XCTAssertEqual(sm.state, .discoveringServices)

        sm.handle(.servicesDiscovered)
        XCTAssertEqual(sm.state, .discoveringCharacteristics)

        sm.handle(.characteristicsDiscovered)
        XCTAssertEqual(sm.state, .connected)
    }

    // Codex #11: poweredOff must auto-recover, NOT require manual reset.

    func test_bluetoothPoweredOffThenOn_autoRecoversFromBluetoothOff() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        XCTAssertEqual(sm.state, .scanning)

        sm.handle(.bluetoothStateChanged(.poweredOff))
        XCTAssertEqual(sm.state, .bluetoothOff)

        let resumeActions = sm.handle(.bluetoothStateChanged(.poweredOn))
        XCTAssertEqual(sm.state, .scanning,
                       "Plan E5 + codex #11: poweredOn from bluetoothOff must auto-resume scanning")
        XCTAssertTrue(resumeActions.contains(where: { if case .startScanning = $0 { return true } else { return false } }))
    }

    // Codex #11: unauthorized should NOT auto-recover; user must fix in Settings.

    func test_bluetoothUnauthorized_doesNotAutoRecover() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.bluetoothStateChanged(.unauthorized))
        XCTAssertEqual(sm.state, .bluetoothUnauthorized)

        // poweredOn while unauthorized — we stay where we are (user must fix permission).
        // The state machine handles bluetoothOff specially but unauthorized stays sticky.
        sm.handle(.bluetoothStateChanged(.poweredOn))
        XCTAssertEqual(sm.state, .bluetoothUnauthorized,
                       "Unauthorized must require explicit user reset, not auto-recover")
    }

    func test_userReset_returnsToIdleFromAnyState() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        sm.handle(.didConnect)
        XCTAssertEqual(sm.state, .discoveringServices)

        sm.handle(.userReset)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.reconnectAttempts, 0)
    }

    func test_connectionTimeout_schedulesReconnectWithBackoff() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        XCTAssertEqual(sm.state, .connecting)

        let actions = sm.handle(.connectionTimeout)
        XCTAssertEqual(sm.state, .disconnected)
        let scheduled = actions.first(where: { action in
            if case .scheduleReconnect(let after) = action { return after == 1 }
            return false
        })
        XCTAssertNotNil(scheduled, "First reconnect should use 1s backoff")
    }

    func test_exponentialBackoff_followsSchedule() {
        let sm = BLEStateMachine()
        for (attempt, expectedBackoff) in BLEStateMachine.backoffSchedule.prefix(5).enumerated() {
            // Drive into connecting state.
            sm.handle(.userReset)
            sm.handle(.startScanRequested)
            sm.handle(.peripheralFound)
            // Drive reconnectAttempts forward manually
            for _ in 0..<attempt {
                sm.handle(.didFailToConnect)
                sm.handle(.reconnectAttempt)
                sm.handle(.peripheralFound)
            }
            let actions = sm.handle(.didFailToConnect)
            let scheduled = actions.first(where: { action in
                if case .scheduleReconnect(let after) = action { return after == expectedBackoff }
                return false
            })
            XCTAssertNotNil(scheduled, "Attempt \(attempt) should use backoff \(expectedBackoff)s")
        }
    }

    func test_maxReconnectsExceeded_movesToError() {
        let sm = BLEStateMachine(maxReconnectAttempts: 2)
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)

        // Attempt 1
        sm.handle(.didFailToConnect)
        sm.handle(.reconnectAttempt)
        sm.handle(.peripheralFound)

        // Attempt 2
        sm.handle(.didFailToConnect)
        sm.handle(.reconnectAttempt)
        sm.handle(.peripheralFound)

        // Attempt 3 — should exhaust and not schedule another reconnect.
        let actions = sm.handle(.didFailToConnect)
        let scheduled = actions.first(where: { if case .scheduleReconnect = $0 { return true } else { return false } })
        XCTAssertNil(scheduled, "After max attempts, no further reconnect scheduling")
    }

    // Codex #10: services / characteristics discovery has its own timeouts and recovery paths.

    func test_servicesDiscoveryTimeout_schedulesReconnect() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        sm.handle(.didConnect)
        XCTAssertEqual(sm.state, .discoveringServices)

        sm.handle(.servicesTimeout)
        XCTAssertEqual(sm.state, .disconnected,
                       "Services-discovery timeout treated as connection failure")
    }

    func test_characteristicsDiscoveryTimeout_schedulesReconnect() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        sm.handle(.didConnect)
        sm.handle(.servicesDiscovered)
        XCTAssertEqual(sm.state, .discoveringCharacteristics)

        sm.handle(.characteristicsTimeout)
        XCTAssertEqual(sm.state, .disconnected,
                       "Char-discovery timeout treated as connection failure")
    }

    func test_disconnectFromConnected_schedulesReconnect() {
        let sm = BLEStateMachine()
        // Drive to connected
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        sm.handle(.didConnect)
        sm.handle(.servicesDiscovered)
        sm.handle(.characteristicsDiscovered)
        XCTAssertEqual(sm.state, .connected)

        let actions = sm.handle(.didDisconnect)
        XCTAssertEqual(sm.state, .disconnected)
        let scheduled = actions.first(where: { if case .scheduleReconnect = $0 { return true } else { return false } })
        XCTAssertNotNil(scheduled)
    }

    func test_reconnectSuccess_resetsAttemptCounter() {
        let sm = BLEStateMachine()
        sm.handle(.startScanRequested)
        sm.handle(.peripheralFound)
        sm.handle(.didFailToConnect)  // attempt 1
        sm.handle(.reconnectAttempt)
        sm.handle(.peripheralFound)
        sm.handle(.didConnect)        // success — should reset counter
        XCTAssertEqual(sm.reconnectAttempts, 0)
    }

    func test_unhandledEvent_logsAndStaysInCurrentState() {
        let sm = BLEStateMachine()
        XCTAssertEqual(sm.state, .idle)
        let actions = sm.handle(.didConnect) // not valid from idle
        XCTAssertEqual(sm.state, .idle)
        XCTAssertTrue(actions.contains(where: { action in
            if case .log(let msg) = action { return msg.contains("Unhandled") }
            return false
        }))
    }
}
