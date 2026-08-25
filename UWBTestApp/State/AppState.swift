//
//  AppState.swift
//  UWBTestApp
//
//  Everything the UI observes. Written only on the main thread, from the batched
//  telemetry the coordinator pushes; the coordinator never reads it back (its own
//  configuration lives on the UWB queue, exactly like in the plugin).
//
import Foundation
import Observation

@Observable
class AppState {

    // MARK: - Sensors

    var mapSensors: [String] = []
    var discoveredDevices: [String: Double] = [:]   // deviceId → RSSI
    var connectedDevices: Set<String> = []
    var outOfRangeDevices: Set<String> = []         // excluded by the distance filter
    var staleDevices: Set<String> = []              // connected, but last measurement too old
    var distances: [String: Double] = [:]           // deviceId → accepted distance (m)
    var gatedCounts: [String: Int] = [:]            // outlier measurements rejected per sensor

    // MARK: - Latest fix

    /// Trilateration output before the Kalman filter. Shown next to `filteredPos` so the
    /// filter's contribution (smoothing vs. lag) is visible while walking.
    var rawPos: Vector2D? = nil
    var filteredPos: Vector2D? = nil
    var residual: Double? = nil
    var activeAnchorCount: Int = 0
    var fixTimestamp: TimeInterval? = nil

    // MARK: - Diagnostics counters

    var fixCount: Int = 0
    /// Fixes skipped because the fresh anchors were (nearly) collinear.
    var collinearSkips: Int = 0
    /// Measurements discarded as invalid (non-positive or non-finite).
    var invalidDistanceCount: Int = 0

    // MARK: - Settings (owned by the UI, forwarded to the coordinator via ViewModel)

    var distanceFilterEnabled: Bool = false
    var maxConnectionDistance: Double = 5.0

    /// Slant-distance projection. Off by default, matching the plugin.
    var userHeightEnabled: Bool = false
    var userHeight: Double = 1.3

    /// Kalman tuning, mirroring the plugin defaults.
    var measurementStd: Double = 0.1
    var processAccelStd: Double = 0.8

    var verboseLogging: Bool = false

    /// Sensors eligible to feed a fix right now: they reported a distance, it is still
    /// fresh, and the distance filter is not excluding them. Unlike `activeAnchorCount`
    /// — which describes the last computed fix and therefore freezes during a dropout —
    /// this reflects the current state of the sensors.
    var feedingSensorCount: Int {
        distances.keys.filter { !staleDevices.contains($0) && !outOfRangeDevices.contains($0) }.count
    }

    func reset() {
        mapSensors = []
        discoveredDevices = [:]
        connectedDevices = []
        outOfRangeDevices = []
        staleDevices = []
        distances = [:]
        gatedCounts = [:]
        rawPos = nil
        filteredPos = nil
        residual = nil
        activeAnchorCount = 0
        fixTimestamp = nil
        fixCount = 0
        collinearSkips = 0
        invalidDistanceCount = 0
        // Settings are user preferences — deliberately not reset.
    }
}
