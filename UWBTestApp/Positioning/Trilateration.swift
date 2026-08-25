//
//  Trilateration.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/21/25.
//

import Foundation

/// Result of a 2D position fix.
struct TrilaterationEstimate {
    let x: Double
    let y: Double
    /// RMS error (meters) between the measured distances and the distances from the
    /// estimated position to each anchor. High values signal bad geometry, multipath
    /// or obstacles — callers can use it to decide how much to trust the fix.
    let residual: Double
}

/// Estimates the 2D position of the device from 3+ anchors with known positions and
/// measured distances.
///
/// Method: classic linearization. For each anchor i:
///     (x - xi)² + (y - yi)² = di²
/// Subtracting the first anchor's equation removes the quadratic terms, leaving a
/// linear system A·[x,y]ᵀ = b solved by least squares (2×2 normal equations). This
/// single path replaces the previous exact 3-anchor solver and the LAPACK-based
/// multilateration: least squares handles both cases and cannot divide by zero or
/// abort the process.
///
/// - Parameters:
///   - anchors: Anchors with known positions and measured distances (3 or more).
///   - userHeight: Assumed phone height in meters, used to project slant distances
///     onto the floor plane: `d_h = sqrt(d² − (z_anchor − userHeight)²)`. Pass `nil`
///     to use raw distances (correct when anchors sit at phone height).
/// - Returns: The estimated position, or `nil` when there are fewer than 3 anchors
///   or the anchors are (nearly) collinear. The caller should keep its last valid
///   fix in that case.
func trilaterate2D(anchors: [Anchor], userHeight: Double?) -> TrilaterationEstimate? {
    guard anchors.count >= 3 else { return nil }

    let projected: [(x: Double, y: Double, d: Double)] = anchors.map { anchor in
        var d = anchor.distance
        if let h = userHeight {
            let dz = anchor.position.z - h
            let horizontal2 = d * d - dz * dz
            // A measurement shorter than the height difference means the phone is
            // (noise aside) right under the anchor — clamp instead of going complex.
            d = horizontal2 > 0 ? horizontal2.squareRoot() : 0.05
        }
        return (anchor.position.x, anchor.position.y, d)
    }

    let ref = projected[0]

    var a11 = 0.0, a12 = 0.0, a22 = 0.0   // AᵀA (symmetric)
    var b1 = 0.0, b2 = 0.0                // Aᵀb

    for p in projected.dropFirst() {
        let ax = 2 * (p.x - ref.x)
        let ay = 2 * (p.y - ref.y)
        let bi = ref.d * ref.d - p.d * p.d
               + p.x * p.x - ref.x * ref.x
               + p.y * p.y - ref.y * ref.y

        a11 += ax * ax
        a12 += ax * ay
        a22 += ay * ay
        b1  += ax * bi
        b2  += ay * bi
    }

    let det = a11 * a22 - a12 * a12
    guard abs(det) > 1e-9 else { return nil }   // collinear anchors → no unique solution

    let x = (b1 * a22 - b2 * a12) / det
    let y = (a11 * b2 - a12 * b1) / det
    guard x.isFinite, y.isFinite else { return nil }

    let residual = (projected.reduce(0.0) { acc, p in
        let d = ((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)).squareRoot()
        return acc + (d - p.d) * (d - p.d)
    } / Double(projected.count)).squareRoot()

    return TrilaterationEstimate(x: x, y: y, residual: residual)
}
