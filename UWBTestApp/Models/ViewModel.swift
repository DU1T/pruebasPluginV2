//
//  ViewModel.swift
//  UWBTestApp
//
//  Created by Gustavo Gonzalez on 7/21/25.
//
//  Plays the role the `@_cdecl` bridge plays in the plugin: it owns the pipeline
//  lifecycle and exposes the same operations Unity calls (load map / start / stop /
//  distance filter / user height / Kalman tuning). Keeping the same shape means the
//  app exercises the real call sequence instead of a shortcut of its own.
//
import Foundation
import Observation

@Observable
class ViewModel {
    let state = AppState()
    let availableMaps = ["casa.json", "campus4sensors.json", "campusTest.json", "315b.json"]
    private(set) var selectedMap: String = "casa.json"

    /// Set when a map fails to load. The plugin returns -2 from `setAnchorMap` in this
    /// situation and keeps the previous map; here it also surfaces in the UI. This path
    /// used to be a fatalError.
    var mapError: String? = nil

    /// Whether a pipeline is currently running (scanning and computing).
    var isRunning: Bool { positionCoordinator != nil }

    /// Mirrors the plugin's ViewModel: connect to the K nearest anchors, not everything.
    private let connectionLimit = 6
    private let connectionTimeout = 10.0

    private var positionCoordinator: PositionCoordinator?
    private var uwbManager: UWBManager?
    private var queue: OperationQueue?
    private var currentAnchorMap: [String: Vector3D]?
    private var didAutoStart = false

    // Initialization is deferred to startIfNeeded() so the main thread is not blocked
    // before the first frame renders.
    init() {}

    /// Called once after the first frame renders. Safe to call multiple times.
    func startIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        start(map: selectedMap)
    }

    // MARK: - Lifecycle controls (exercise the plugin's start/stop guarantees)

    /// Starts or stops the pipeline. Repeated stop/start cycles are the scenario that
    /// used to stack live pipelines and leak coordinators through the delegate cycle.
    func setRunning(_ running: Bool) {
        if running {
            guard !isRunning else { return }
            start(map: selectedMap)
        } else {
            guard isRunning else { return }
            stop()
            state.reset()
            state.mapSensors = sortedSensors(of: currentAnchorMap)
        }
    }

    /// Starts on top of a running pipeline. The plugin's `start()` tears the previous
    /// one down first; this button is here to confirm that nothing doubles up.
    func restart() {
        start(map: selectedMap)
    }

    /// Mirrors Unity calling `setAnchorMap` on a level change: the map is validated
    /// first and, if it is bad, the previous one keeps running instead of tearing the
    /// pipeline down. On success the running pipeline is reset onto the new map rather
    /// than rebuilt — the path the plugin actually takes.
    func changeMap(_ map: String) {
        guard map != selectedMap else { return }

        guard let anchorMap = loadMap(map) else {
            mapError = "No se pudo cargar '\(map)': JSON inválido o ausente en el bundle. Se mantiene '\(selectedMap)'."
            return
        }

        mapError = nil
        selectedMap = map
        currentAnchorMap = anchorMap
        state.reset()
        state.mapSensors = sortedSensors(of: anchorMap)

        if let coordinator = positionCoordinator {
            coordinator.applyNewAnchorMap(anchorMap)
        } else {
            start(map: map)
        }
    }

    // MARK: - Configuration (mirrors the plugin's bridge functions)

    func setDistanceFilter(enabled: Bool, maxDistance: Double) {
        state.distanceFilterEnabled = enabled
        if maxDistance > 0 { state.maxConnectionDistance = maxDistance }
        positionCoordinator?.setDistanceFilter(enabled: enabled, maxDistance: maxDistance)
    }

    func setUserHeight(enabled: Bool, height: Double) {
        state.userHeightEnabled = enabled
        if height > 0 { state.userHeight = height }
        positionCoordinator?.setUserHeight(enabled && height > 0 ? height : nil)
    }

    func setKalmanTuning(measurementStd: Double, processAccelStd: Double) {
        if measurementStd > 0 { state.measurementStd = measurementStd }
        if processAccelStd > 0 { state.processAccelStd = processAccelStd }
        positionCoordinator?.setKalmanTuning(measurementStd: measurementStd, processAccelStd: processAccelStd)
    }

    /// Restores the plugin's shipping defaults, so a tuning session can always get back
    /// to a known baseline.
    func resetTuning() {
        setKalmanTuning(measurementStd: 0.1, processAccelStd: 0.8)
    }

    func setVerboseLogging(_ enabled: Bool) {
        state.verboseLogging = enabled
        uwbVerboseLogging = enabled
    }

    // MARK: - Internals

    private func loadMap(_ map: String) -> [String: Vector3D]? {
        guard let anchorMap = MapReader.readCoordinates(from: map), !anchorMap.isEmpty else {
            return nil
        }
        return anchorMap
    }

    private func sortedSensors(of map: [String: Vector3D]?) -> [String] {
        (map?.keys).map { Array($0).sorted() } ?? []
    }

    private func start(map: String) {
        // Never stack two pipelines — the same guarantee the plugin's start() gives.
        if isRunning { stop() }

        guard let anchorMap = loadMap(map) else {
            mapError = "No se pudo cargar '\(map)': JSON inválido o ausente en el bundle."
            return
        }
        mapError = nil
        currentAnchorMap = anchorMap

        let q = OperationQueue()
        q.name = "UWB queue"
        q.maxConcurrentOperationCount = 1
        self.queue = q

        let coordinator = PositionCoordinator(
            state: state,
            anchorsPositions: anchorMap,
            connectionLimit: connectionLimit,
            connectionTimeout: connectionTimeout
        )

        // The manager holds the coordinator weakly, and the coordinator enqueues its
        // configuration on the manager's queue — so wire both up before scanning and
        // before applying the retained settings.
        let uwb = UWBManager(delegate: coordinator, UWBQueue: q)
        coordinator.uwbManager = uwb

        self.positionCoordinator = coordinator
        self.uwbManager = uwb

        coordinator.setDistanceFilter(enabled: state.distanceFilterEnabled, maxDistance: state.maxConnectionDistance)
        coordinator.setUserHeight(state.userHeightEnabled ? state.userHeight : nil)
        coordinator.setKalmanTuning(measurementStd: state.measurementStd, processAccelStd: state.processAccelStd)

        uwb.startScanning()

        state.mapSensors = sortedSensors(of: anchorMap)
    }

    private func stop() {
        positionCoordinator?.disconnectFromAllSensors()
        uwbManager?.stopScanning()
        positionCoordinator = nil
        uwbManager = nil
        queue = nil
    }
}
