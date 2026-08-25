//
//  PositionCoordinator.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/20/25.
//

import Foundation
import simd

/// Snapshot of the latest position fix, published for the Unity bridge.
/// Besides the coordinates it carries the quality data Unity needs to decide how much
/// to trust the fix (show/hide the avatar, freeze the camera, etc.).
struct PositionSnapshot {
    let x: Double
    let y: Double
    /// Trilateration RMS residual in meters (see `TrilaterationEstimate.residual`).
    let residual: Double
    /// Number of anchors that fed this fix.
    let activeAnchorCount: Int
    /// Unix time when the fix was computed; consumers derive the fix age from it.
    let timestamp: TimeInterval
}

/// Combines UWB distance measurements into a filtered 2D position.
///
/// Threading model: all mutable state is owned by the serial `UWBQueue` (every
/// delegate callback and every configuration change runs there). The only state
/// crossing threads is the published `PositionSnapshot`, protected by a lock, which
/// the Unity bridge reads from its own thread.
class PositionCoordinator {

    // MARK: - State owned by the UWB serial queue

    var connectedDevices: Set<String> = []
    var anchors: [String: Anchor] = [:]
    var outOfRangeDevices: Set<String> = []   // connected but excluded by the distance filter

    /// Devices that are in the map, discovered, but not connected because the
    /// connection limit was reached. Used to rotate connections toward closer anchors.
    private var candidateDevices: [String: TimeInterval] = [:]

    /// Devices recently disconnected by rotation. Ignored during discovery for a few
    /// seconds so the freed slot goes to the waiting candidate — without this, the
    /// rotated-out beacon's advertising usually wins the race back and the rotation
    /// degenerates into a connect/disconnect loop.
    private var rotationCooldown: [String: TimeInterval] = [:]
    private let rotationCooldownWindow: Double = 8.0

    /// Per-anchor outlier gate state.
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

    // MARK: - Tuning

    /// Only anchors whose latest measurement is younger than this (seconds) feed the
    /// position computation. Separate from `connectionTimeout`, which only decides
    /// when to disconnect: a distance a few seconds old is meters off for a walking
    /// user and must not enter the trilateration even if the session is kept alive.
    var stalenessWindow: Double = 1.0

    /// After a gap without fixes longer than this (seconds), the Kalman filter is
    /// re-initialized with the next measurement instead of extrapolating across the hole.
    private let reinitializeGap: Double = 2.0

    /// Outlier gate: maximum plausible rate of change of a single anchor distance
    /// (m/s) plus a fixed slack (m). Jumps beyond it are held as pending and only
    /// accepted when the next measurement confirms them, so a lone spike is dropped
    /// but a real change (e.g. walking out from behind an obstacle) passes with one
    /// update of delay.
    private let maxRadialSpeed: Double = 4.0
    private let gateSlack: Double = 0.5

    /// Assumed phone height in meters, used to project slant distances onto the floor
    /// plane before trilaterating. `nil` disables the projection (raw distances).
    var userHeight: Double? = nil

    // Distance filter (configured from Unity via setDistanceFilter).
    // When enabled, sensors farther than maxConnectionDistance are excluded from the
    // trilateration computation, but their UWB session stays active and keeps measuring.
    var distanceFilterEnabled: Bool = false
    var maxConnectionDistance: Double = 5.0
    // Hysteresis: an excluded sensor re-enters the computation only when it drops to 85%
    // of the exclusion threshold, preventing flip-flopping right at the limit.
    private let hysteresisRatio: Double = 0.85

    var uwbManager: UWBManager?

    // MARK: - Published output (crosses threads)

    private let snapshotLock = NSLock()
    private var snapshot: PositionSnapshot? = nil

    /// Initializes the position coordinator, which manages UWB sensors and computes
    /// the user's position via trilateration plus a Kalman filter.
    ///
    /// - Parameters:
    ///   - anchorsPositions: Fixed positions of all UWB sensors (anchors) in the environment.
    ///   - connectionLimit: Maximum number of simultaneously connected UWB sensors.
    ///   - connectionTimeout: Maximum time (seconds) without updates before disconnecting a sensor.
    init(anchorsPositions: [String: Vector3D], connectionLimit: Int, connectionTimeout: Double) {
        self.anchorsPositions = anchorsPositions
        self.connectionLimit = connectionLimit
        self.connectionTimeout = connectionTimeout
    }

    // MARK: - Output accessors (safe from any thread)

    /// Latest filtered position, or `nil` before the first fix. After the first fix
    /// this keeps returning the last valid position even during dropouts; use
    /// `getSnapshot()` to judge freshness.
    func getFilteredPosition() -> Vector2D? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot.map { Vector2D(x: $0.x, y: $0.y) }
    }

    /// Latest fix with its quality data, or `nil` before the first fix.
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

    /// Replaces the anchor map and resets everything derived from the previous one:
    /// per-anchor state, the Kalman filter and the published position. Connected
    /// sensors are disconnected so the pipeline restarts cleanly on the new map.
    func applyNewAnchorMap(_ newAnchors: [String: Vector3D]) {
        guard let queue = uwbManager?.UWBQueue else {
            anchorsPositions = newAnchors
            return
        }
        // Strong capture on purpose: a requested map change must apply even if the
        // caller drops its reference right after.
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
            for deviceId in previouslyConnected {
                uwbManager?.disconnectFrom(deviceId: deviceId)
            }
            print("[UWBplugin]: Anchor map replaced (\(newAnchors.count) anchors), pipeline reset")
        }
    }

    /// Configures the distance filter at runtime. Sensors measuring farther than
    /// `maxDistance` are excluded from the computation (hysteresis re-inclusion at 85%);
    /// their UWB sessions stay active.
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
            print("[UWBplugin]: Distance filter enabled=\(enabled) maxDistance=\(self.maxConnectionDistance)")
        }
    }

    /// Sets the assumed phone height for slant-distance projection (`nil` disables it).
    func setUserHeight(_ height: Double?) {
        uwbManager?.UWBQueue.addOperation { [weak self] in
            self?.userHeight = height
        }
    }

    /// Forces disconnection from all currently connected UWB sensors.
    func disconnectFromAllSensors() {
        // Strong capture on purpose: this runs during teardown and must still execute
        // after the bridge has released its references.
        uwbManager?.UWBQueue.addOperation { [self] in
            for deviceId in connectedDevices {
                print("[UWBplugin]: Requested disconnect from device \(deviceId)")
                uwbManager?.disconnectFrom(deviceId: deviceId)
            }
        }
    }

    // MARK: - Measurement gating

    /// Validates one distance measurement against the anchor's history. Returns the
    /// accepted distance, or `nil` when the measurement is held back as an outlier.
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
            // Second reading agrees with the jump → it was real, accept it.
            gates[deviceId] = DistanceGate(lastDistance: distance, lastTime: now, pending: nil)
            return distance
        }

        // Implausible jump with no confirmation yet. Note: lastTime is intentionally
        // not advanced, so if rejections persist the allowed window keeps growing and
        // the gate can never lock out reality for long.
        gate.pending = distance
        gates[deviceId] = gate
        if uwbVerboseLogging {
            print("[UWBplugin]: Gated outlier from \(deviceId): \(distance) (last accepted \(gate.lastDistance))")
        }
        return nil
    }
}

// MARK: - UWBManagerDelegate

extension PositionCoordinator: UWBManagerDelegate {

    /// Removes a disconnected device from all per-anchor state.
    func didDisconnect(deviceId: String) {
        print("[UWBplugin]: Disconnected from device \(deviceId)")
        connectedDevices.remove(deviceId)
        anchors.removeValue(forKey: deviceId)
        outOfRangeDevices.remove(deviceId)
        gates.removeValue(forKey: deviceId)
    }

    /// Registers a successful connection.
    func didConnect(deviceId: String) {
        connectedDevices.insert(deviceId)
        candidateDevices.removeValue(forKey: deviceId)
        print("[UWBplugin]: Connected to device \(deviceId)")
    }

    /// Connects to discovered devices that belong to the anchor map, up to the
    /// connection limit. Beyond the limit, devices are remembered as rotation
    /// candidates (see `didUpdatePosition`).
    func onDeviceDiscovered(deviceId: String, rssi: Double) {
        if uwbVerboseLogging {
            print("[UWBplugin]: Discovered device \(deviceId)")
        }

        guard anchorsPositions.keys.contains(deviceId) else { return }
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
            candidateDevices[deviceId] = Date().timeIntervalSince1970
        }
    }

    /// Main measurement pipeline. Runs on the UWB serial queue for every distance
    /// update: validation → outlier gate → distance filter → freshness window →
    /// trilateration → Kalman → publish.
    func didUpdatePosition(deviceId: String, distance: Double) {
        let now = Date().timeIntervalSince1970

        // Estimote occasionally reports negative distances; those are invalid readings,
        // not sign glitches — discard instead of abs()-ing them into "valid" data.
        guard distance.isFinite, distance > 0 else {
            if uwbVerboseLogging {
                print("[UWBplugin]: Discarded invalid distance \(distance) from \(deviceId)")
            }
            return
        }

        guard let position = anchorsPositions[deviceId] else {
            print("[UWBplugin]: Sensor \(deviceId) sent an update but is not in the anchor map (likely disconnecting).")
            return
        }

        guard let accepted = gatedDistance(deviceId: deviceId, distance: distance, now: now) else {
            return
        }

        anchors[deviceId] = Anchor(id: deviceId, position: position, distance: accepted, timestamp: now)

        // Distance filter with hysteresis: decides whether this anchor feeds the
        // computation; never touches connectivity.
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

        // Connection-level timeout: disconnect sensors that stopped reporting, and
        // drop them from this tick's state immediately — an expired distance must not
        // participate in the trilateration below.
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

        // Connection rotation: when at the limit with fresh candidates waiting, release
        // the farthest anchor once it stops being useful. Far anchors add more noise
        // than signal, and with dev-kit firmware a busy beacon is invisible to other
        // phones. The freed slot is taken by the candidate on its next discovery.
        candidateDevices = candidateDevices.filter { now - $0.value < 5.0 }
        if connectedDevices.count >= connectionLimit, !candidateDevices.isEmpty {
            let rotationThreshold = distanceFilterEnabled ? maxConnectionDistance : 10.0
            if let farthest = anchors.values.max(by: { $0.distance < $1.distance }),
               farthest.distance > rotationThreshold {
                rotationCooldown[farthest.id] = now
                uwbManager?.disconnectFrom(deviceId: farthest.id)
            }
        }

        // Freshness window: only anchors with a recent measurement enter the fix.
        let activeAnchors = anchors.filter { entry in
            guard let timestamp = entry.value.timestamp else { return false }
            return now - timestamp <= stalenessWindow && !outOfRangeDevices.contains(entry.key)
        }

        if uwbVerboseLogging {
            print("[UWBplugin] \(anchors.count) sensors connected, \(activeAnchors.count) feeding the fix.")
        }

        // Fewer than 3 fresh anchors → no new fix. The last snapshot is kept (its age
        // keeps growing) so Unity can decide what to do instead of losing the position.
        guard activeAnchors.count >= 3 else { return }

        guard let estimate = trilaterate2D(anchors: Array(activeAnchors.values), userHeight: userHeight) else {
            // Collinear geometry — keep the last valid fix.
            return
        }

        // Kalman: re-initialize after a long dropout instead of extrapolating across it;
        // otherwise predict over the elapsed time, then fuse the measurement.
        if let last = lastFixTime, now - last > reinitializeGap {
            kalman.reset()
        }
        if let last = lastFixTime {
            kalman.predict(dt: min(now - last, 1.0))
        }
        guard let filtered = kalman.update(z: simd_double2(estimate.x, estimate.y)) else {
            return
        }
        lastFixTime = now

        publish(PositionSnapshot(x: filtered.x,
                                 y: filtered.y,
                                 residual: estimate.residual,
                                 activeAnchorCount: activeAnchors.count,
                                 timestamp: now))

        if uwbVerboseLogging {
            print("[UWBplugin] Fix: (\(filtered.x), \(filtered.y)) residual=\(estimate.residual)")
        }
    }
}
