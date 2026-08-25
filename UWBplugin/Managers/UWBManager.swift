//
//  UWBManager.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/20/25.
//
import EstimoteUWB


class UWBManager: NSObject {
    /// Weak: the coordinator owns this manager, so a strong delegate reference would
    /// create a retain cycle (coordinator → manager → coordinator) that survives
    /// stop() and stacks a live pipeline per start()/stop() cycle.
    weak var delegate: UWBManagerDelegate?
    var manager: EstimoteUWBManager? = nil
    var UWBQueue: OperationQueue

    /// Initializes the UWB manager responsible for communicating with Estimote UWB sensors.
    /// Handles discovery, connection, and distance updates between the app and physical anchors.
    ///
    /// - Parameters:
    ///   - delegate: The object that will receive UWB events through the `UWBManagerDelegate` protocol.
    ///   - UWBQueue: The serial operation queue where all UWB events and state changes run.
    init(delegate: UWBManagerDelegate, UWBQueue: OperationQueue) {
        self.UWBQueue = UWBQueue
        self.delegate = delegate

        super.init()

        self.manager = EstimoteUWBManager(delegate: self, options: EstimoteUWBOptions(shouldHandleConnectivity: false, isCameraAssisted: false))
    }

    /// Initiates a connection to the specified UWB device.
    ///
    /// - Parameter deviceID: The unique identifier of the UWB sensor to connect to.
    func connectTo(deviceID: String) {
        UWBQueue.addOperation {
            self.manager?.connect(to: deviceID)
        }
    }

    /// Disconnects from the specified UWB device.
    ///
    /// - Parameter deviceId: The unique identifier of the UWB sensor to disconnect from.
    func disconnectFrom(deviceId: String) {
        UWBQueue.addOperation {
            self.manager?.disconnect(from: deviceId)
        }
    }

    /// Starts scanning for nearby UWB devices.
    /// Discovered devices are reported through the delegate method `onDeviceDiscovered`.
    func startScanning() {
        UWBQueue.addOperation {
            self.manager?.startScanning()
        }
    }

    /// Stops scanning for UWB devices.
    /// Should be called when scanning is no longer needed or to conserve energy.
    func stopScanning() {
        UWBQueue.addOperation {
            self.manager?.stopScanning()
        }
    }
}

extension UWBManager: EstimoteUWBManagerDelegate {

    /// Called when a connected UWB device sends an updated distance measurement.
    /// The raw value is forwarded as-is: validation (negative, zero or non-finite
    /// readings, outlier jumps) is the coordinator's job, so invalid readings are
    /// dropped instead of being disguised as valid ones with abs().
    ///
    /// - Parameter device: The Estimote UWB device that reported the new position.
    func didUpdatePosition(for device: EstimoteUWBDevice) {
        self.UWBQueue.addOperation {
            self.delegate?.didUpdatePosition(deviceId: device.publicIdentifier, distance: Double(device.distance))
        }
    }

    /// Called when a new UWB device is discovered nearby.
    /// Reports the device's ID and signal strength (RSSI) to the delegate.
    ///
    /// - Parameters:
    ///   - device: The discovered UWB device.
    ///   - rssi: The signal strength of the detected device.
    ///   - manager: The UWB manager handling the discovery.
    func didDiscover(device: UWBIdentifiable, with rssi: NSNumber, from manager: EstimoteUWBManager) {
        self.UWBQueue.addOperation {
            self.delegate?.onDeviceDiscovered(deviceId: device.publicIdentifier, rssi: Double(truncating: rssi))
        }
    }

    /// Called when a UWB device successfully connects.
    /// Notifies the delegate that the device is ready for data exchange.
    ///
    /// - Parameter device: The connected UWB device.
    func didConnect(to device: UWBIdentifiable) {
        self.UWBQueue.addOperation {
            self.delegate?.didConnect(deviceId: device.publicIdentifier)
        }
    }

    /// Called when a UWB device disconnects (including disconnections initiated by the
    /// beacon itself). Forwarded to the delegate so its connection bookkeeping cannot
    /// drift out of sync with reality.
    ///
    /// - Parameters:
    ///   - device: The disconnected UWB device.
    ///   - error: An optional error describing the reason for disconnection.
    func didDisconnect(from device: UWBIdentifiable, error: Error?) {
        self.UWBQueue.addOperation {
            self.delegate?.didDisconnect(deviceId: device.publicIdentifier)
        }
    }

    /// Called when the connection attempt to a UWB device fails.
    /// Logs the failure and provides basic error information.
    ///
    /// - Parameters:
    ///   - device: The UWB device that failed to connect.
    ///   - error: An optional error describing the failure reason.
    func didFailToConnect(to device: UWBIdentifiable, error: Error?) {
        print("[UWBplugin]: Failed to connect to device: \(device.publicIdentifier)")
    }
}
