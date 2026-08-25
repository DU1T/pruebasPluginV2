//
//  Kalman.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/21/25.
//
import Foundation
import simd

/// 2D constant-velocity Kalman filter for smoothing trilateration fixes.
///
/// State: [x, y, vx, vy]. There is no control input: the raw accelerometer feed was
/// removed because `CMAccelerometerData` is expressed in the device frame and includes
/// gravity, so tilting the phone injected a fake ±1 g "motion" into the prediction.
/// Prediction is instead driven by the elapsed time between UWB fixes, with process
/// noise from the random-acceleration model.
///
/// The filter is an instance owned by `PositionCoordinator` (not a singleton), so a
/// new pipeline starts clean; `reset()` also runs on anchor-map changes so a fix from
/// the previous map cannot drag the position on the new one.
final class KalmanFilter {

    /// Measurement noise std, meters. Estimote UWB ranges at ~±0.1 m line-of-sight.
    /// Raise it in multipath-heavy venues (filter trusts the fixes less, moves smoother).
    private(set) var measurementStd: Double
    /// Random-acceleration std, m/s², for the process noise (~0.5–1 for walking).
    /// Raise it if the filter lags behind a fast walk; lower it if the dot jitters.
    private(set) var processAccelStd: Double

    private(set) var isInitialized = false

    private var x = simd_double4()
    private var P = matrix_identity_double4x4
    private let H = simd_double4x2(rows: [
        SIMD4<Double>(1, 0, 0, 0),
        SIMD4<Double>(0, 1, 0, 0)
    ])
    private var R: simd_double2x2 {
        simd_double2x2(diagonal: SIMD2<Double>(measurementStd * measurementStd,
                                               measurementStd * measurementStd))
    }

    init(measurementStd: Double = 0.1, processAccelStd: Double = 0.8) {
        self.measurementStd = measurementStd
        self.processAccelStd = processAccelStd
    }

    /// Retunes R and Q at runtime. Non-positive values leave the current setting
    /// untouched. The state is kept: tuning takes effect from the next predict/update,
    /// so values can be compared live without losing the current fix.
    func setTuning(measurementStd: Double, processAccelStd: Double) {
        if measurementStd > 0 { self.measurementStd = measurementStd }
        if processAccelStd > 0 { self.processAccelStd = processAccelStd }
    }

    /// Clears the filter state. Called on stop() and whenever the anchor map changes.
    func reset() {
        isInitialized = false
        x = simd_double4()
        P = matrix_identity_double4x4
    }

    /// Propagates the state `dt` seconds forward under the constant-velocity model.
    /// Does nothing before the first measurement.
    func predict(dt: Double) {
        guard isInitialized, dt > 0 else { return }

        let F = simd_double4x4(rows: [
            SIMD4<Double>(1, 0, dt, 0),
            SIMD4<Double>(0, 1, 0, dt),
            SIMD4<Double>(0, 0, 1, 0),
            SIMD4<Double>(0, 0, 0, 1)
        ])

        // Q from the random-acceleration model: per axis
        // [[dt⁴/4, dt³/2], [dt³/2, dt²]] · σa²
        let s2 = processAccelStd * processAccelStd
        let q11 = s2 * dt * dt * dt * dt / 4
        let q13 = s2 * dt * dt * dt / 2
        let q33 = s2 * dt * dt
        let Q = simd_double4x4(rows: [
            SIMD4<Double>(q11, 0, q13, 0),
            SIMD4<Double>(0, q11, 0, q13),
            SIMD4<Double>(q13, 0, q33, 0),
            SIMD4<Double>(0, q13, 0, q33)
        ])

        x = F * x
        P = F * P * F.transpose + Q
    }

    /// Fuses a position measurement. The first finite measurement initializes the
    /// state directly (position = z, velocity = 0) instead of pulling the estimate
    /// from the origin. Non-finite measurements are rejected so a bad fix can never
    /// poison the state.
    ///
    /// - Returns: The filtered position, or `nil` if the measurement was rejected.
    @discardableResult
    func update(z: simd_double2) -> simd_double2? {
        guard z.x.isFinite, z.y.isFinite else { return nil }

        if !isInitialized {
            x = simd_double4(z.x, z.y, 0, 0)
            // Position known to measurement accuracy; velocity unknown (~walking speed).
            P = simd_double4x4(diagonal: SIMD4<Double>(measurementStd * measurementStd,
                                                       measurementStd * measurementStd,
                                                       1.0, 1.0))
            isInitialized = true
            return z
        }

        let y = z - H * x                      // Innovation
        let S = H * P * H.transpose + R        // Innovation covariance
        let K = P * H.transpose * S.inverse    // Kalman gain

        x = x + K * y
        P = (matrix_identity_double4x4 - K * H) * P

        return simd_double2(x[0], x[1])
    }

    /// Current filtered position, or `nil` before the first accepted measurement.
    func position() -> simd_double2? {
        guard isInitialized else { return nil }
        return simd_double2(x[0], x[1])
    }
}
