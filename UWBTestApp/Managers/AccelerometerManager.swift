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
    
    init(refreshRate: Float, delegate: AccelerometerDelegate, accelerometerQueue: OperationQueue){
        self.accelerometerQueue = accelerometerQueue
        self.delegate = delegate
        self.refreshRate = refreshRate
        self.motionManager = CMMotionManager()
    }
}

extension AccelerometerManager{
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
    
    func stopListening(){
        // Must match startAccelerometerUpdates — stopDeviceMotionUpdates() does NOT stop it.
        self.motionManager.stopAccelerometerUpdates()
    }
}
