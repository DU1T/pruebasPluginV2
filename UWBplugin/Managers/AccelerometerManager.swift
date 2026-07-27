//
//  AccelerometerManager.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/20/25.
//
import CoreMotion


class AccelerometerManager{
    var delegate: AccelerometerDelegate? = nil
    var motionManager: CMMotionManager
    var refreshRate: Float
    var accelerometerQueue: OperationQueue
    
    /// Initializes the accelerometer manager responsible for reading motion data from the device.
    /// The data is periodically reported to its delegate for position estimation and Kalman filter updates.
    ///
    /// - Parameters:
    ///   - refreshRate: The update frequency of the accelerometer in Hertz.
    ///   - delegate: The object that will receive motion updates through the `AccelerometerDelegate` protocol.
    ///   - accelerometerQueue: The operation queue where accelerometer updates will be processed.
    init(refreshRate: Float, delegate: AccelerometerDelegate, accelerometerQueue: OperationQueue){
        self.accelerometerQueue = accelerometerQueue
        self.delegate = delegate
        self.refreshRate = refreshRate
        self.motionManager = CMMotionManager()
    }
}

extension AccelerometerManager{

    /// Starts listening for accelerometer updates.
    /// Each reading is converted into a `Vector2D` and sent to the delegate through `onUpdate`.
    ///
    /// This method runs continuously until `stopListening()` is called.
    func startListening(){
        // Bound the accelerometer rate. Without this it runs at the device default (often very
        // high), flooding the shared serial OperationQueue with predict() operations and causing
        // stutter. refreshRate is the update interval in seconds (0.1 = 10 Hz).
        motionManager.accelerometerUpdateInterval = Double(refreshRate)
        motionManager.startAccelerometerUpdates(to: self.accelerometerQueue) { (data, error) in

            guard let data = data, error == nil else {
                print("Accelerometer error: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            let x = data.acceleration.x
            let y = data.acceleration.y
            
            let vector = Vector2D(x: x, y: y)
            self.delegate?.onUpdate(vector: vector)
        }
    }
    
    /// Stops listening for accelerometer updates.
    /// Useful when the app goes to the background or the system needs to save power.
    func stopListening(){
        // Must match startAccelerometerUpdates — stopDeviceMotionUpdates() does NOT stop it.
        self.motionManager.stopAccelerometerUpdates()
    }
}
