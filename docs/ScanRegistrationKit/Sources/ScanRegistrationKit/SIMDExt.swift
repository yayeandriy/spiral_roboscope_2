
import Foundation
import simd

public extension simd_float4x4 {
    static var identity: simd_float4x4 { matrix_identity_float4x4 }

    var rotation: simd_float3x3 {
        simd_float3x3(columns: (columns.0.xyz, columns.1.xyz, columns.2.xyz))
    }

    var translation: SIMD3<Float> {
        get { columns.3.xyz }
        set { columns.3 = simd_float4(newValue, 1) }
    }

    init(rotation R: simd_float3x3, translation t: SIMD3<Float>) {
        self = .identity
        columns.0 = simd_float4(R.columns.0, 0)
        columns.1 = simd_float4(R.columns.1, 0)
        columns.2 = simd_float4(R.columns.2, 0)
        columns.3 = simd_float4(t, 1)
    }

    static func * (lhs: simd_float4x4, rhs: simd_float4x4) -> simd_float4x4 {
        simd_mul(lhs, rhs)
    }
}

public extension simd_float4 {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}

public extension SIMD3 where Scalar == Float {
    var norm: Float { simd_length(self) }
    func normalized() -> SIMD3<Float> { simd_normalize(self) }
}

public func skew(_ v: SIMD3<Float>) -> simd_float3x3 {
    simd_float3x3(rows: [
        SIMD3<Float>( 0, -v.z,  v.y),
        SIMD3<Float>( v.z,  0,  -v.x),
        SIMD3<Float>(-v.y, v.x,  0)
    ])
}

/// Small-angle SE(3) update: exp([w v]) ~ [I + [w]_x  v; 0 1]
public func se3Exp(_ xi: SIMD6<Float>) -> simd_float4x4 {
    let w = SIMD3<Float>(xi[0], xi[1], xi[2])
    let v = SIMD3<Float>(xi[3], xi[4], xi[5])
    let Wx = skew(w)
    let R = simd_float3x3(columns: (
        SIMD3<Float>(1,0,0) + Wx.columns.0,
        SIMD3<Float>(0,1,0) + Wx.columns.1,
        SIMD3<Float>(0,0,1) + Wx.columns.2
    ))
    return simd_float4x4(rotation: R, translation: v)
}

public typealias SIMD6<T> = SIMD6Storage<T>
public struct SIMD6Storage<Scalar: SIMDScalar> {
    public var elements: [Scalar] = Array(repeating: 0 as! Scalar, count: 6)
    public init() {}
    public subscript(i: Int) -> Scalar {
        get { elements[i] }
        set { elements[i] = newValue }
    }
}
