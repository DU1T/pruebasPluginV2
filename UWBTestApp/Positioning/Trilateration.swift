//
//  Trilateration.swift
//  UWBplugin
//
//  Created by Gustavo Gonzalez on 7/21/25.
//

import Foundation


func do_trilateration(anchors: [String: Anchor])->Vector2D{
    
    if anchors.count > 3 {
        let position = multilateration(anchors: Array(anchors.values))
        return position
    }else{
        let topThreeAnchors = pickTopThreeAnchors(anchors: anchors)
        let position = tirlaterate_3D(anchors: topThreeAnchors)
        return position
    }
}

private func pickTopThreeAnchors(anchors: [String: Anchor]) -> [Anchor]{
    if anchors.count == 3 {
        return Array(anchors.values)
    }
    
    return anchors
        .values
        .compactMap { anchor in
            anchor.timestamp != nil ? anchor : nil
        }
        .sorted { $0.timestamp! > $1.timestamp! }
        .prefix(3)
        .map { $0 }
}


private func multilateration(anchors: [Anchor]) -> Vector2D{
    let (matrix, vector) = multInitializeMatrixVector(anchors: anchors)
    let n = matrix.count/3
    
    let transposedMatrix = transpose(matrix: matrix, rows: n , cols: 3)
    
    let lhs = matrixMultiplication(A: transposedMatrix, rowsOfA: 3, B: matrix, colsOfB: 3, sharedDim: n)
    let rhs = matrixMultiplication(A: transposedMatrix, rowsOfA: 3, B: vector, colsOfB: 1, sharedDim: n)
    
    let result = gaussJordan(A: lhs, n: 3, b: rhs)
    //print("Multilat result: \(result)")

    return Vector2D(x:result[0], y:result[1])
}

private func multInitializeMatrixVector(anchors: [Anchor])-> (matrix: [Double], vector: [Double]){
    
    var anchorsCopy = anchors
    guard let pivot = anchorsCopy.popLast() else {
        fatalError("pivotAnchor is nil")
    }
    
    var matrix: [Double] = []
    var vector: [Double] = []
    
    for anchor in anchors{
                
        matrix.append(contentsOf: [
            2 * (pivot.position.x - anchor.position.x),
            2 * (pivot.position.y - anchor.position.y),
            2 * (pivot.position.z - anchor.position.z)
        ])
                    

        let dA2 = pow(anchor.distance, 2)
        let dP2 = pow(pivot.distance, 2)

        let ax2 = pow(anchor.position.x, 2)
        let ay2 = pow(anchor.position.y, 2)
        let az2 = pow(anchor.position.z, 2)

        let px2 = pow(pivot.position.x, 2)
        let py2 = pow(pivot.position.y, 2)
        let pz2 = pow(pivot.position.z, 2)

        let value = dA2 - dP2 - ax2 - ay2 - az2 + px2 + py2 + pz2
        
        vector.append(value)
    }
    
    return (matrix, vector)
}

private func tirlaterate_3D(anchors: [Anchor]) -> Vector2D{
    let d1: Double = anchors[0].distance
    let x1: Double = anchors[0].position.x
    let y1: Double = anchors[0].position.y
    let z1: Double = anchors[0].position.z
    
    let d2: Double = anchors[1].distance
    let x2: Double = anchors[1].position.x
    let y2: Double = anchors[1].position.y
    let z2: Double = anchors[1].position.z
    
    let d3: Double = anchors[2].distance
    let x3: Double = anchors[2].position.x
    let y3: Double = anchors[2].position.y
    let z3: Double = anchors[2].position.z
        
    // First EQ
    let A = 2 * (x1 - x2)
    let B = 2 * (y1 - y2)
    let C = 2 * (z1 - z2)

    let D = pow(d2, 2) - pow(d1,2) - pow(x2,2) - pow(y2,2) - pow(z2,2) + pow(x1, 2) + pow(y1, 2) + pow(z1, 2)
    
    // Second EQ
    let E = 2 * (x1 - x3)
    let F = 2 * (y1 - y3)
    let G = 2 * (z1 - z3)
    let H = pow(d3, 2) - pow(d1, 2) - pow(x3, 2) - pow(y3, 2) - pow(z3, 2) + pow(x1, 2) + pow(y1, 2) + pow(z1, 2)

    // Aux EQ
    let afeb = (A * F - E * B)

    let alpha = (-B * G + C * F) / afeb
    let beta = (-B * H + D * F) / afeb

    let phi = (A * G - E * C) / afeb
    let roh = (A * H - E * D) / afeb

    // Coefficients
    let first = pow(alpha, 2) + pow(phi, 2) + 1
    let second = -(2 * alpha * beta) + (2 * x1 * alpha) - (2 * phi * roh) + (2 * y1 * phi) - (2 * z1)
    let third = pow(beta, 2) + pow(x1, 2) - (2 * x1 * beta) + pow(roh, 2) + pow(y1, 2) - (2 * y1 * roh) + pow(z1, 2) - pow(d1, 2)
    
    let discriminant = Double(pow(second, 2) - 4 * first * third)
    
    var z: Double = 0.0
    
    if discriminant > 0 {
        if let value = solveQuadratic(a: first, b: second, c: third, discriminant: discriminant){
            z = value[0]
        }
    }
    
    let x = Double(beta - alpha * z)
    let y = Double(roh - phi * z)
    return Vector2D(x: x, y: y)
}

