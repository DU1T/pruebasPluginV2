//
//  UWBManagerDelegate.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/20/25.
//

/// Protocol defining callbacks for UWB (Ultra-Wideband) device management and position updates.
/// Class-bound (`AnyObject`) so conformers can be held through `weak` references,
/// which breaks the coordinator ↔ manager retain cycle.
protocol UWBManagerDelegate: AnyObject {
    // MARK: connection functions

    /// Called when a UWB device successfully connects.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the connected device.
    func didConnect(deviceId: String)

    /// Called when a UWB device disconnects.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the disconnected device.
    func didDisconnect(deviceId: String)


    // MARK: triggered on event functions

    /// Triggered when a new UWB device is discovered during scanning.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the discovered device.
    ///   - rssi: The signal strength indicator (RSSI) of the detected device.
    func onDeviceDiscovered(deviceId: String, rssi: Double)

    /// Triggered when a UWB device updates its distance measurement.
    ///
    /// - Parameters:
    ///   - deviceId: The unique identifier of the device that updated.
    ///   - distance: The latest measured distance to the device in meters.
    func didUpdatePosition(deviceId: String, distance: Double)
}
