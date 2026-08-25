//
//  ViewModel.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/21/25.
//
import Foundation


/// Main view model responsible for initializing and coordinating all components of the UWB plugin.
///
/// The `ViewModel` sets up and links the `PositionCoordinator` and `UWBManager` on a
/// single serial operation queue. The accelerometer pipeline was removed: raw
/// device-frame acceleration (gravity included, never rotated into map coordinates)
/// only injected bias into the Kalman prediction.
class ViewModel {
    /// Maximum simultaneous UWB connections. iOS caps concurrent Nearby Interaction
    /// sessions, every session drains the beacon's AA battery, and with dev-kit
    /// firmware a busy beacon is invisible to other phones — so connect to the K
    /// nearest anchors instead of everything on the map. Far anchors add more noise
    /// than information anyway; the coordinator rotates connections as the user moves.
    var connectionLimit = 6
    var connectionTimeout = 10.0
    let posCoordinator: PositionCoordinator

    var anchorMap: [String: Vector3D]

    /// Initializes the `ViewModel` with the given anchor positions.
    ///
    /// This constructor:
    /// - Stores the anchor map used for position calculation.
    /// - Creates the shared serial `OperationQueue` that owns all UWB state.
    /// - Initializes the UWB manager and starts scanning.
    ///
    /// - Parameters:
    ///   - anchorMap: A dictionary mapping anchor IDs to their corresponding 3D coordinates.
    init(anchorMap: [String: Vector3D]) {
        self.anchorMap = anchorMap

        let queue = OperationQueue()
        queue.name = "UWB queue"
        queue.maxConcurrentOperationCount = 1

        posCoordinator = PositionCoordinator(anchorsPositions: anchorMap, connectionLimit: connectionLimit, connectionTimeout: connectionTimeout)

        // The manager holds the coordinator weakly (delegate), so the coordinator must
        // be wired up before scanning starts.
        let uwbManager = UWBManager(delegate: posCoordinator, UWBQueue: queue)
        posCoordinator.uwbManager = uwbManager
        uwbManager.startScanning()
    }

    /// Returns the active instance of the `PositionCoordinator`.
    ///
    /// - Returns: The initialized `PositionCoordinator` instance used by this `ViewModel`.
    func getPositionCoordinator() -> PositionCoordinator {
        return self.posCoordinator
    }
}
