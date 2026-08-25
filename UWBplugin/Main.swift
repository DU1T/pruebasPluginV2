//
//  Main.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/23/25.
//
//  Unity bridge. No function in this file may abort the process: a bad input from C#
//  must translate into an error code (Int32 return, 0 = success), never a fatalError.
//  ABI note: functions that used to return void and now return Int32 stay callable
//  from existing C# `void` DllImports — the return register is simply ignored.
//

import Foundation
import UIKit

var viewModel: ViewModel? = nil
var positionCoordinator: PositionCoordinator? = nil
var anchorMap: [String: Vector3D]? = nil

// Configuration stored here so it survives start()/stop() and can be set before
// start() is ever called; applied to the coordinator as soon as one exists.
var distanceFilterEnabled: Bool = false
var maxConnectionDistance: Double = 5.0
/// Assumed phone height in meters for slant-distance projection. Non-positive means
/// the projection is disabled and raw UWB distances are used (matches the behavior of
/// maps whose anchors are registered at phone height).
var userHeight: Double = 0.0

/// Enables per-update / per-poll logging (sensor counts, positions, getCoords calls, etc.).
/// Keep this `false` in production: those code paths run tens of times per second and the
/// synchronous `print()` calls were the main cause of stutter on the Unity side. Flip to
/// `true` only while debugging the filter/positioning. Module-wide (used across files).
var uwbVerboseLogging = false


/// Sets the anchor map (UWB sensor positions) from a JSON string received from Unity.
///
/// If a pipeline is already running, the new map is applied to it: per-anchor state and
/// the Kalman filter are reset and all sensors are disconnected so positioning restarts
/// cleanly on the new map.
///
/// - Parameter str: A C-style string (UTF-8) containing a JSON map of anchor positions.
/// - Returns: 0 on success, -1 if the string is null, -2 if the JSON is invalid or
///   empty (the previous map is kept in that case).
@_cdecl("setAnchorMap")
public func setAnchorMap(_ str: UnsafePointer<CChar>?) -> Int32 {
    guard let str = str else {
        print("[UWBPlugin] setAnchorMap: received null string")
        return -1
    }

    guard let parsed = MapReader.readCoordinatesFromString(jsonMap: String(cString: str)),
          !parsed.isEmpty else {
        print("[UWBPlugin] setAnchorMap: invalid or empty JSON map, keeping previous map")
        return -2
    }

    anchorMap = parsed
    positionCoordinator?.applyNewAnchorMap(parsed)
    return 0
}

/// Initializes the UWB plugin and starts positioning using the previously defined anchor map.
///
/// Must be called after `setAnchorMap`. Calling it while already running tears the
/// current pipeline down and starts a fresh one (it never stacks two pipelines).
///
/// - Returns: 0 on success, -1 if no anchor map has been set.
@_cdecl("start")
public func start() -> Int32 {
    print("[UWBPlugin] Start function called")
    guard let map = anchorMap else {
        print("[UWBPlugin] start: anchorMap is nil, call setAnchorMap first")
        return -1
    }

    if viewModel != nil {
        print("[UWBPlugin] start: already running — restarting pipeline")
        stopPipeline()
    }

    let vm = ViewModel(anchorMap: map)
    viewModel = vm
    positionCoordinator = vm.getPositionCoordinator()

    // Apply any configuration set before start().
    positionCoordinator?.setDistanceFilter(enabled: distanceFilterEnabled, maxDistance: maxConnectionDistance)
    positionCoordinator?.setUserHeight(userHeight > 0 ? userHeight : nil)
    return 0
}

/// Configures the distance filter from Unity.
///
/// When enabled, UWB sensors measuring farther than `maxDistance` meters are excluded from the
/// position computation (trilateration), while their UWB sessions stay active and keep measuring.
/// Re-inclusion uses hysteresis at 85% of the threshold to prevent oscillation near the limit.
///
/// Can be called before or after `start()`; the configuration is retained and (re)applied to the
/// active coordinator. Passing a non-positive `maxDistance` leaves the current threshold unchanged.
///
/// - Parameters:
///   - enabled: 0 to disable the filter (all in-range sensors used), non-zero to enable it.
///   - maxDistance: Exclusion threshold in meters.
@_cdecl("setDistanceFilter")
public func setDistanceFilter(_ enabled: Int32, _ maxDistance: Double) {
    let isEnabled = enabled != 0
    distanceFilterEnabled = isEnabled
    if maxDistance > 0 {
        maxConnectionDistance = maxDistance
    }
    positionCoordinator?.setDistanceFilter(enabled: isEnabled, maxDistance: maxDistance)
    print("[UWBPlugin] setDistanceFilter enabled=\(isEnabled) maxDistance=\(maxDistance)")
}

/// Sets the assumed phone height (meters above the map's z = 0) used to project slant
/// UWB distances onto the floor plane before trilateration.
///
/// When the anchors are mounted above phone height (e.g. on the ceiling) the raw
/// distances are hypotenuses; projecting them removes an error that grows the closer
/// the user stands to a sensor. Typical values: 1.2–1.4. Pass 0 or a negative value
/// to disable the projection (default — correct when anchor z values already match
/// phone height). Can be called before or after `start()`.
///
/// - Parameter height: Phone height in meters, or a non-positive value to disable.
@_cdecl("setUserHeight")
public func setUserHeight(_ height: Double) {
    userHeight = height
    positionCoordinator?.setUserHeight(height > 0 ? height : nil)
    print("[UWBPlugin] setUserHeight \(height)")
}

/// Retunes the Kalman filter at runtime.
///
/// `measurementStd` is the assumed UWB measurement noise in meters (default 0.1):
/// raising it makes the filter trust each fix less, so the position moves more smoothly
/// but lags more. `processAccelStd` is the random-acceleration std in m/s² (default 0.8):
/// raising it lets the position follow fast movement, lowering it damps jitter while
/// standing still. Non-positive values leave that parameter unchanged.
///
/// Both take effect from the next measurement without dropping the current fix, so
/// values can be compared live. Use `UWBTestApp` to find good values for a venue before
/// hardcoding them in Unity.
///
/// - Parameters:
///   - measurementStd: Measurement noise std in meters, or <= 0 to keep the current one.
///   - processAccelStd: Process acceleration std in m/s², or <= 0 to keep the current one.
@_cdecl("setKalmanTuning")
public func setKalmanTuning(_ measurementStd: Double, _ processAccelStd: Double) {
    positionCoordinator?.setKalmanTuning(measurementStd: measurementStd, processAccelStd: processAccelStd)
    print("[UWBPlugin] setKalmanTuning measurementStd=\(measurementStd) processAccelStd=\(processAccelStd)")
}

/// Stops the UWB plugin, disconnecting sensors and releasing all active references.
@_cdecl("stop")
public func stop() {
    print("[UWBPlugin] Stop method called.")
    stopPipeline()
    anchorMap = nil
}

/// Tears down the active pipeline: disconnects all sensors, stops scanning and releases
/// the references. The teardown operations retain what they need, so they still execute
/// on the UWB queue after the globals are cleared.
private func stopPipeline() {
    positionCoordinator?.disconnectFromAllSensors()
    positionCoordinator?.uwbManager?.stopScanning()
    viewModel = nil
    positionCoordinator = nil
}

/// Returns the most recent filtered coordinates of the user's position as a JSON string.
///
/// After the first fix, this keeps returning the last valid position during dropouts
/// (fewer than 3 fresh anchors) instead of flickering to null — use `getPositionData`
/// to judge freshness and quality. Returns `{"x":null,"y":null}` before the first fix.
///
/// - Returns: A C-style UTF-8 string, e.g. `{"x":1.200000,"y":3.400000}`.
///   The string must be freed with `freeCString()` after use.
@_cdecl("getCoords")
public func getCoords() -> UnsafeMutablePointer<CChar> {
    let json: String
    if let position = positionCoordinator?.getFilteredPosition() {
        json = String(format: "{\"x\":%.6f,\"y\":%.6f}", position.x, position.y)
    } else {
        json = "{\"x\":null,\"y\":null}"
    }
    return strdup(json)!
}

/// Returns the latest position fix together with its quality data, without any JSON
/// allocation — intended for per-frame polling from Unity.
///
/// C# signature:
/// ```csharp
/// [DllImport("__Internal")]
/// static extern int getPositionData(out double x, out double y, out double residual,
///                                   out int activeAnchors, out double fixAgeMs);
/// ```
///
/// - Parameters:
///   - outX: Filtered x coordinate (map meters).
///   - outY: Filtered y coordinate (map meters).
///   - outResidual: Trilateration RMS residual in meters (higher = less trustworthy).
///   - outActiveAnchors: Number of anchors that fed the fix.
///   - outFixAgeMs: Milliseconds elapsed since the fix was computed.
/// - Returns: 1 if a fix is available (out parameters written), 0 otherwise.
@_cdecl("getPositionData")
public func getPositionData(_ outX: UnsafeMutablePointer<Double>?,
                            _ outY: UnsafeMutablePointer<Double>?,
                            _ outResidual: UnsafeMutablePointer<Double>?,
                            _ outActiveAnchors: UnsafeMutablePointer<Int32>?,
                            _ outFixAgeMs: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let snapshot = positionCoordinator?.getSnapshot() else {
        return 0
    }
    outX?.pointee = snapshot.x
    outY?.pointee = snapshot.y
    outResidual?.pointee = snapshot.residual
    outActiveAnchors?.pointee = Int32(snapshot.activeAnchorCount)
    outFixAgeMs?.pointee = (Date().timeIntervalSince1970 - snapshot.timestamp) * 1000.0
    return 1
}

/// Frees a C-style UTF-8 string previously allocated by `getCoords()`.
///
/// - Parameter ptr: The pointer to the C string to be freed.
@_cdecl("freeCString")
public func freeCString(_ ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr = ptr {
        free(ptr)
    }
}


/// Forces a UI refresh as a workaround for Unity-related UI desynchronization on iOS.
///
/// The previous implementation posted synthetic didEnterBackground/willEnterForeground/
/// didBecomeActive notifications; every SDK in the process receives those (Estimote,
/// analytics, ARKit) and may pause sessions or corrupt state in response. This version
/// pokes the view hierarchy directly instead, which only affects layout.
@_cdecl("triggerUIRefresh")
public func triggerUIRefresh() {
    print("[UWBPlugin] Triggering UI refresh workaround")

    DispatchQueue.main.async {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.view.setNeedsLayout()
                window.rootViewController?.view.layoutIfNeeded()
            }
        }
    }
}
