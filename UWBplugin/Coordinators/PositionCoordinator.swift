//
//  PositionCoordinator.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/20/25.
//

import Foundation

class PositionCoordinator{
    var connectedDevices: Set<String> = []
    var anchors: [String: Anchor] = [:]
    var outOfRangeDevices: Set<String> = []   // connected but excluded from trilateration
    var lastTime = Date().timeIntervalSince1970

    var anchorsPositions: [String: Vector3D]
    var connectionLimit: Int
    var connectionTimeout: Double

    // Distance filter (configured from Unity via setDistanceFilter).
    // When enabled, sensors farther than maxConnectionDistance are excluded from the
    // trilateration computation, but their UWB session stays active and keeps measuring.
    // The filter never disconnects sensors — it only filters at the data level.
    var distanceFilterEnabled: Bool = false
    var maxConnectionDistance: Double = 5.0
    // Hysteresis: an excluded sensor re-enters the computation only when it drops to 85%
    // of the exclusion threshold. This dead zone prevents connect/exclude oscillation for
    // sensors hovering right at the limit, where UWB noise would otherwise flip the state.
    private let hysteresisRatio: Double = 0.85

    // Manager instances
    var uwbManager: UWBManager?
    var accelerometerManager: AccelerometerManager?

    // Filtered Position
    var filteredPos: Vector2D? = nil
    
    /// Initializes the position coordinator, which manages UWB sensors and accelerometer data
    /// to compute the user's position using trilateration and a Kalman filter.
    ///
    /// - Parameters:
    ///   - anchorsPositions: A dictionary with the fixed positions of all UWB sensors (anchors) in the environment.
    ///   - connectionLimit: The maximum number of UWB sensors that can be connected simultaneously.
    ///   - connectionTimeout: The maximum time (in seconds) allowed without updates before disconnecting a sensor.
    init(anchorsPositions: [String: Vector3D], connectionLimit: Int, connectionTimeout: Double){
        self.anchorsPositions = anchorsPositions
        self.connectionLimit = connectionLimit
        self.connectionTimeout = connectionTimeout
    }
    
    /// Updates the known anchor set with new positions.
    /// This allows recalibrating the system without restarting the coordinator.
    ///
    /// - Parameter anchorsPositions: A dictionary containing the updated positions of the UWB sensors.
    func setNewAnchors(anchorsPositions: [String: Vector3D]){
        // Start with old positions, then overwrite/add with new ones
        self.anchorsPositions = anchorsPositions
    }
    
    /// Creates an `Anchor` object from a UWB device ID and its measured distance.
    /// Returns `nil` if the device is not part of the registered anchor map.
    ///
    /// - Parameters:
    ///   - deviceID: The unique identifier of the UWB sensor.
    ///   - distance: The measured distance to that sensor in meters.
    /// - Returns: An `Anchor` object with the sensor's position and distance, or `nil` if not found.
    func getAnchor(deviceID: String, distance: Double) -> Anchor?{
        
        guard let pos = anchorsPositions[deviceID] else {
            print("[UWBPlugin]: Tried to fetch a device ID that is not on the anchor map.")
            return nil
        }
        
        return Anchor(
            id: deviceID,
            position: pos,
            distance: distance,
            timestamp: Date().timeIntervalSince1970
        )

    }

    /// Returns the most recent filtered position computed by the system.
    /// This position has been smoothed using the Kalman filter to reduce noise and improve stability.
    ///
    /// - Returns: A 2D vector representing the current filtered position.
    func getFilteredPosition() -> Vector2D?{
        return self.filteredPos
    }
    
    /// Forces disconnection from all currently connected UWB sensors.
    /// Useful for resetting the system or clearing inactive connections.
    ///
    /// Does not return any value. 
    func disconnectFromAllSensors(){
        for deviceId in self.connectedDevices{
            print("[UWBplugin]: Requested disconnect from device \(deviceId)")
            uwbManager?.disconnectFrom(deviceId: deviceId)
        }
    }

    /// Configures the distance filter at runtime.
    ///
    /// When `enabled` is true, sensors measuring farther than `maxDistance` meters are excluded
    /// from the trilateration computation (with hysteresis re-inclusion at 85% of the threshold).
    /// Their UWB sessions remain active and keep reporting — the filter only affects which anchors
    /// feed the position estimate, never connectivity.
    ///
    /// The update is enqueued on the UWB operation queue so it is serialized with `didUpdatePosition`,
    /// avoiding data races on the filter state read during distance updates.
    ///
    /// - Parameters:
    ///   - enabled: Whether the distance filter is active.
    ///   - maxDistance: Exclusion threshold in meters. Ignored if not strictly positive.
    func setDistanceFilter(enabled: Bool, maxDistance: Double){
        uwbManager?.UWBQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.distanceFilterEnabled = enabled
            if maxDistance > 0 {
                self.maxConnectionDistance = maxDistance
            }
            if !enabled {
                // Filter off → nothing is excluded anymore.
                self.outOfRangeDevices.removeAll()
            }
            print("[UWBplugin]: Distance filter enabled=\(enabled) maxDistance=\(self.maxConnectionDistance)")
        }
    }
}

extension PositionCoordinator: UWBManagerDelegate{
    
    /// Called when a UWB device disconnects.
    /// Removes the device from the active connection list and anchor map.
    ///
    /// - Parameter deviceId: The unique identifier of the disconnected sensor.
    func didDisconnect(deviceId: String) {
        print("[UWBplugin]: Disconnected from device \(deviceId)")
        // we remove the item from the list of connected devices
        self.connectedDevices.remove(deviceId)
        
        // we remove the item from the map [deviceId: Anchor]
        self.anchors.removeValue(forKey: deviceId)
    }
    
    /// Called when a UWB device successfully connects.
    /// Adds the device to the active connection list.
    ///
    /// - Parameter deviceId: The unique identifier of the connected sensor.
    func didConnect(deviceId: String) {
        // we add the device from the list of connected devices
        self.connectedDevices.insert(deviceId)
        print("[UWBplugin]: Connected to device \(deviceId)")
    }
    
    /// Triggered when a nearby UWB device is discovered.
    /// Attempts to connect to it if it exists in the anchor map and the connection limit has not been reached.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the discovered sensor.
    ///   - rssi: The received signal strength indicator used to estimate proximity.
    func onDeviceDiscovered(deviceId: String, rssi: Double) {
        // if the device detected is not on our map we won't connect to it
        if uwbVerboseLogging {
            print("[UWBplugin]: Discovered device \(deviceId)")
        }

        if !anchorsPositions.keys.contains(deviceId) {
            return
        }
        
        // if we are under our connection limit and the device is in our map we can connect to it
        if connectedDevices.count < self.connectionLimit{
            self.uwbManager?.connectTo(deviceID: deviceId)
        }
    }
    
    /// Called whenever a UWB sensor reports a new distance measurement.
    /// Updates the anchor list, filters out expired devices, and computes the current position through trilateration.
    /// The resulting position is then passed through the Kalman filter to reduce noise.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the UWB sensor that sent the update.
    ///   - distance: The latest distance measurement from the sensor to the device in meters.
    func didUpdatePosition(deviceId: String, distance: Double) {
        // 1. We update
        guard let anchor = getAnchor(deviceID: deviceId, distance: distance) else {
            print("[UWBPlugin]: Warning, Sensor \(deviceId) sent an update but is no longer part of the Anchor Map. Sensor is likely in the process of disconnecting.")
            return
        }
        self.anchors[deviceId] = anchor

        // 2. Distance filter with hysteresis.
        //    Keeps the UWB session active; only decides whether this anchor feeds trilateration.
        if self.distanceFilterEnabled {
            let threshold = self.maxConnectionDistance
            if self.outOfRangeDevices.contains(deviceId) {
                // Already excluded → re-include only once it drops to 85% of the threshold.
                if distance <= threshold * hysteresisRatio {
                    self.outOfRangeDevices.remove(deviceId)
                }
            } else {
                // Currently included → exclude once it exceeds the threshold.
                if distance > threshold {
                    self.outOfRangeDevices.insert(deviceId)
                }
            }
        } else {
            self.outOfRangeDevices.remove(deviceId)
        }

        // 3. We check and remove anchors who exceeded the timout
        let now = Date().timeIntervalSince1970

        //        self.anchors = self.anchors.filter { (_, anchor) in
        //            guard let timestamp = anchor.timestamp else {
        //                return true // keep anchors without timestamp (Shouldn't really happen)
        //            }
        //            return now - timestamp <= self.connectionTimeout
        //        }

        let expiredDevices = self.anchors.filter { (_, anchor) in
            guard let timestamp = anchor.timestamp else {
                return false
            }
            return now - timestamp > self.connectionTimeout
        }.map { $0.key }

        // Disconnect expired devices
        for deviceId in expiredDevices {
            self.uwbManager?.disconnectFrom(deviceId: deviceId)
            self.outOfRangeDevices.remove(deviceId)   // keep the filter set in sync
        }

        // 4. We compute trilateration using only the in-range anchors.
        let activeAnchors = self.anchors.filter { !self.outOfRangeDevices.contains($0.key) }

        if uwbVerboseLogging {
            print("[UWBPlugin] \(self.anchors.count) sensors connected, \(activeAnchors.count) in range.")
        }

        if activeAnchors.count < 3{
            self.filteredPos = nil // if we are in range of less than three sensors we return nil (i.e. no fix)
            return
        }

        let position = do_trilateration(anchors: activeAnchors)

        // 4. We pass our computed position through the Kalman Filter
        KalmanFilter.shared.update(z: position.toSIMD())
        let filtered = KalmanFilter.shared.getX()
        let first = filtered[0]
        let second = filtered[1]

        self.filteredPos = Vector2D(x: first, y: second)
        if uwbVerboseLogging {
            print(String(describing: filteredPos))
        }
    }
    
}

extension PositionCoordinator: AccelerometerDelegate{

    /// Called whenever the accelerometer provides a new motion vector.
    /// Updates the internal Kalman filter’s motion model to refine position prediction between UWB updates.
    ///
    /// - Parameter vector: The 2D acceleration vector representing the device’s movement since the last update.
    func onUpdate(vector: Vector2D) {
        let currentTime = Date().timeIntervalSince1970
        let deltaTime = currentTime - lastTime
        
        if KalmanFilter.shared.getX() == .zero{
            return
        }
        
        let simd2d = vector.toSIMD()
        
        KalmanFilter.shared.updateG(delta_time: deltaTime)
        KalmanFilter.shared.updateF(delta_time: deltaTime)
        
        KalmanFilter.shared.updateU(simd2d)
        KalmanFilter.shared.predict()
        
        lastTime = currentTime
    }
}
    
