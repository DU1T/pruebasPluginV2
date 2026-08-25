//
//  PositionCoordinator.swift
//  UWBTestApp
//
//  Mirror of `UWBplugin/Coordinators/PositionCoordinator.swift`. The measurement
//  pipeline below (validation → outlier gate → distance filter → freshness window →
//  trilateration → Kalman → publish) must stay identical to the plugin's, so whatever
//  you observe and tune here is what Unity gets. The only additions are the telemetry
//  batched to `AppState` for the UI and the per-sensor diagnostic counters, which the
//  headless plugin has no use for.
//
//  Threading is the same as the plugin: every mutable field is owned by the serial
//  UWB queue, the published snapshot is behind a lock, and configuration arriving from
//  the UI is enqueued instead of being read across threads.
//

import Foundation
import simd

/// Snapshot of the latest position fix, published for consumers outside the queue.
struct PositionSnapshot {
    let x: Double
    let y: Double
    let residual: Double
    let activeAnchorCount: Int
    let timestamp: TimeInterval
}

class PositionCoordinator {

    private let state: AppState

    // MARK: - State owned by the UWB serial queue

    var connectedDevices: Set<String> = []
    var anchors: [String: Anchor] = [:]
    var outOfRangeDevices: Set<String> = []

    private var candidateDevices: [String: TimeInterval] = [:]
    private var rotationCooldown: [String: TimeInterval] = [:]
    private let rotationCooldownWindow: Double = 8.0

    private struct DistanceGate {
        var lastDistance: Double
        var lastTime: TimeInterval
        var pending: Double?
    }
    private var gates: [String: DistanceGate] = [:]

    private let kalman = KalmanFilter()
    private var lastFixTime: TimeInterval? = nil

    var anchorsPositions: [String: Vector3D]
    var connectionLimit: Int
    var connectionTimeout: Double

    // MARK: - Tuning (same defaults as the plugin)

    var stalenessWindow: Double = 1.0
    private let reinitializeGap: Double = 2.0
    private let maxRadialSpeed: Double = 4.0
    private let gateSlack: Double = 0.5
    var userHeight: Double? = nil

    var distanceFilterEnabled: Bool = false
    var maxConnectionDistance: Double = 5.0
    private let hysteresisRatio: Double = 0.85

    var uwbManager: UWBManager?

    // MARK: - Published output

    private let snapshotLock = NSLock()
    private var snapshot: PositionSnapshot? = nil

    // MARK: - UI telemetry (test app only)

    /// Distance/position telemetry is batched and pushed at most 8 times per second.
    /// Connection events bypass the throttle — they are rare and must show immediately.
    private var lastUIUpdate: TimeInterval = 0
    private let uiUpdateInterval: TimeInterval = 1.0 / 8.0
    private var gatedCounts: [String: Int] = [:]
    private var fixCount = 0
    private var collinearSkips = 0
    private var invalidDistanceCount = 0
    private var lastRaw: Vector2D? = nil

    init(state: AppState, anchorsPositions: [String: Vector3D], connectionLimit: Int, connectionTimeout: Double) {
        self.state = state
        self.anchorsPositions = anchorsPositions
        self.connectionLimit = connectionLimit
        self.connectionTimeout = connectionTimeout
    }

    // MARK: - Output accessors (safe from any thread)

    func getFilteredPosition() -> Vector2D? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot.map { Vector2D(x: $0.x, y: $0.y) }
    }

    func getSnapshot() -> PositionSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    private func publish(_ newSnapshot: PositionSnapshot?) {
        snapshotLock.lock()
        snapshot = newSnapshot
        snapshotLock.unlock()
    }

    // MARK: - Configuration (enqueued so it serializes with the update pipeline)

    /// Replaces the anchor map on a running pipeline — the path Unity triggers when it
    /// calls `setAnchorMap` on a level change. Everything derived from the old map is
    /// cleared (per-anchor state, Kalman, published fix) so the previous map's position
    /// cannot drag the new one.
    func applyNewAnchorMap(_ newAnchors: [String: Vector3D]) {
        guard let queue = uwbManager?.UWBQueue else {
            anchorsPositions = newAnchors
            return
        }
        queue.addOperation { [self] in
            let previouslyConnected = connectedDevices
            anchorsPositions = newAnchors
            anchors.removeAll()
            gates.removeAll()
            outOfRangeDevices.removeAll()
            candidateDevices.removeAll()
            rotationCooldown.removeAll()
            kalman.reset()
            lastFixTime = nil
            publish(nil)

            gatedCounts.removeAll()
            fixCount = 0
            collinearSkips = 0
            invalidDistanceCount = 0
            lastRaw = nil

            for deviceId in previouslyConnected {
                uwbManager?.disconnectFrom(deviceId: deviceId)
            }
            print("[UWBTestApp]: Anchor map replaced (\(newAnchors.count) anchors), pipeline reset")
            pushTelemetry(now: Date().timeIntervalSince1970, force: true)
        }
    }

    func setDistanceFilter(enabled: Bool, maxDistance: Double) {
        uwbManager?.UWBQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.distanceFilterEnabled = enabled
            if maxDistance > 0 {
                self.maxConnectionDistance = maxDistance
            }
            if !enabled {
                self.outOfRangeDevices.removeAll()
            }
        }
    }

    func setUserHeight(_ height: Double?) {
        uwbManager?.UWBQueue.addOperation { [weak self] in
            self?.userHeight = height
        }
    }

    func setKalmanTuning(measurementStd: Double, processAccelStd: Double) {
        uwbManager?.UWBQueue.addOperation { [weak self] in
            self?.kalman.setTuning(measurementStd: measurementStd, processAccelStd: processAccelStd)
        }
    }

    func disconnectFromAllSensors() {
        uwbManager?.UWBQueue.addOperation { [self] in
            for deviceId in connectedDevices {
                uwbManager?.disconnectFrom(deviceId: deviceId)
            }
        }
    }

    // MARK: - Measurement gating

    /// Validates one distance against the anchor's history. Returns the accepted
    /// distance, or `nil` when the measurement is held back as an outlier.
    private func gatedDistance(deviceId: String, distance: Double, now: TimeInterval) -> Double? {
        guard var gate = gates[deviceId] else {
            gates[deviceId] = DistanceGate(lastDistance: distance, lastTime: now, pending: nil)
            return distance
        }

        let dt = max(now - gate.lastTime, 0.05)
        let allowed = maxRadialSpeed * dt + gateSlack

        if abs(distance - gate.lastDistance) <= allowed {
            gates[deviceId] = DistanceGate(lastDistance: distance, lastTime: now, pending: nil)
            return distance
        }

        if let pending = gate.pending, abs(distance - pending) <= allowed {
            gates[deviceId] = DistanceGate(lastDistance: distance, lastTime: now, pending: nil)
            return distance
        }

        gate.pending = distance
        gates[deviceId] = gate
        gatedCounts[deviceId, default: 0] += 1
        if uwbVerboseLogging {
            print("[UWBTestApp]: Gated outlier from \(deviceId): \(distance) (last accepted \(gate.lastDistance))")
        }
        return nil
    }

    // MARK: - Telemetry

    private func updateUI(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    /// Pushes a batched snapshot of everything the UI shows. Throttled to 8 Hz unless
    /// `force` is set (connection events, which must not wait for the next window).
    private func pushTelemetry(now: TimeInterval, force: Bool = false) {
        guard force || now - lastUIUpdate >= uiUpdateInterval else { return }
        lastUIUpdate = now

        var newDistances: [String: Double] = [:]
        var staleIds: Set<String> = []
        for (id, anchor) in anchors {
            newDistances[id] = anchor.distance
            if let timestamp = anchor.timestamp, now - timestamp > stalenessWindow {
                staleIds.insert(id)
            }
        }

        let connectedSnapshot = connectedDevices
        let outOfRangeSnapshot = outOfRangeDevices
        let gatedSnapshot = gatedCounts
        let fixes = fixCount
        let collinear = collinearSkips
        let invalid = invalidDistanceCount
        let raw = lastRaw
        let published = getSnapshot()

        // Every collection below is a full replacement, so disconnected or expired
        // sensors disappear from the UI without incremental bookkeeping.
        updateUI { [state] in
            state.connectedDevices = connectedSnapshot
            state.outOfRangeDevices = outOfRangeSnapshot
            state.staleDevices = staleIds
            state.distances = newDistances
            state.gatedCounts = gatedSnapshot
            state.rawPos = raw
            state.filteredPos = published.map { Vector2D(x: $0.x, y: $0.y) }
            state.residual = published?.residual
            state.activeAnchorCount = published?.activeAnchorCount ?? 0
            state.fixTimestamp = published?.timestamp
            state.fixCount = fixes
            state.collinearSkips = collinear
            state.invalidDistanceCount = invalid
        }
    }
}

// MARK: - UWBManagerDelegate

extension PositionCoordinator: UWBManagerDelegate {

    func didDisconnect(deviceId: String) {
        print("[UWBTestApp]: Disconnected from device \(deviceId)")
        connectedDevices.remove(deviceId)
        anchors.removeValue(forKey: deviceId)
        outOfRangeDevices.remove(deviceId)
        gates.removeValue(forKey: deviceId)
        pushTelemetry(now: Date().timeIntervalSince1970, force: true)
    }

    func didConnect(deviceId: String) {
        connectedDevices.insert(deviceId)
        candidateDevices.removeValue(forKey: deviceId)
        print("[UWBTestApp]: Connected to device \(deviceId)")
        pushTelemetry(now: Date().timeIntervalSince1970, force: true)
    }

    func onDeviceDiscovered(deviceId: String, rssi: Double) {
        if uwbVerboseLogging {
            print("[UWBTestApp]: Discovered device \(deviceId)")
        }

        guard anchorsPositions.keys.contains(deviceId) else { return }

        updateUI { [state] in state.discoveredDevices[deviceId] = rssi }

        guard !connectedDevices.contains(deviceId) else { return }

        let now = Date().timeIntervalSince1970
        if let rotatedAt = rotationCooldown[deviceId] {
            if now - rotatedAt < rotationCooldownWindow {
                return
            }
            rotationCooldown.removeValue(forKey: deviceId)
        }

        if connectedDevices.count < connectionLimit {
            uwbManager?.connectTo(deviceID: deviceId)
        } else {
            candidateDevices[deviceId] = now
        }
    }

    func didUpdatePosition(deviceId: String, distance: Double) {
        let now = Date().timeIntervalSince1970

        guard distance.isFinite, distance > 0 else {
            invalidDistanceCount += 1
            if uwbVerboseLogging {
                print("[UWBTestApp]: Discarded invalid distance \(distance) from \(deviceId)")
            }
            return
        }

        guard let position = anchorsPositions[deviceId] else {
            print("[UWBTestApp]: Sensor \(deviceId) sent an update but is not in the anchor map (likely disconnecting).")
            return
        }

        guard let accepted = gatedDistance(deviceId: deviceId, distance: distance, now: now) else {
            pushTelemetry(now: now)
            return
        }

        anchors[deviceId] = Anchor(id: deviceId, position: position, distance: accepted, timestamp: now)

        if distanceFilterEnabled {
            if outOfRangeDevices.contains(deviceId) {
                if accepted <= maxConnectionDistance * hysteresisRatio {
                    outOfRangeDevices.remove(deviceId)
                }
            } else if accepted > maxConnectionDistance {
                outOfRangeDevices.insert(deviceId)
            }
        } else {
            outOfRangeDevices.remove(deviceId)
        }

        let expiredIds = anchors.compactMap { (id, anchor) -> String? in
            guard let timestamp = anchor.timestamp else { return id }
            return now - timestamp > connectionTimeout ? id : nil
        }
        for expiredId in expiredIds {
            uwbManager?.disconnectFrom(deviceId: expiredId)
            anchors.removeValue(forKey: expiredId)
            outOfRangeDevices.remove(expiredId)
            gates.removeValue(forKey: expiredId)
        }

        candidateDevices = candidateDevices.filter { now - $0.value < 5.0 }
        if connectedDevices.count >= connectionLimit, !candidateDevices.isEmpty {
            let rotationThreshold = distanceFilterEnabled ? maxConnectionDistance : 10.0
            if let farthest = anchors.values.max(by: { $0.distance < $1.distance }),
               farthest.distance > rotationThreshold {
                rotationCooldown[farthest.id] = now
                uwbManager?.disconnectFrom(deviceId: farthest.id)
            }
        }

        let activeAnchors = anchors.filter { entry in
            guard let timestamp = entry.value.timestamp else { return false }
            return now - timestamp <= stalenessWindow && !outOfRangeDevices.contains(entry.key)
        }

        guard activeAnchors.count >= 3 else {
            pushTelemetry(now: now)
            return
        }

        guard let estimate = trilaterate2D(anchors: Array(activeAnchors.values), userHeight: userHeight) else {
            collinearSkips += 1
            pushTelemetry(now: now)
            return
        }

        if let last = lastFixTime, now - last > reinitializeGap {
            kalman.reset()
        }
        if let last = lastFixTime {
            kalman.predict(dt: min(now - last, 1.0))
        }
        guard let filtered = kalman.update(z: simd_double2(estimate.x, estimate.y)) else {
            pushTelemetry(now: now)
            return
        }
        lastFixTime = now
        fixCount += 1
        lastRaw = Vector2D(x: estimate.x, y: estimate.y)

        publish(PositionSnapshot(x: filtered.x,
                                 y: filtered.y,
                                 residual: estimate.residual,
                                 activeAnchorCount: activeAnchors.count,
                                 timestamp: now))

        pushTelemetry(now: now)
    }
}
