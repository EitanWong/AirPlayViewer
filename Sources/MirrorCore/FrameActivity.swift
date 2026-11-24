import CoreVideo

/// Detects visual activity without storing a picture, sending input, or scanning every pixel.
package struct FrameActivity {
    private static let columns = 32
    private static let rows = 18
    private var previous = [UInt8]()
    private var current = [UInt8](repeating: 0, count: columns * rows)
    private var lastSample = -Double.infinity
    private var lastWidth = 0
    private var lastHeight = 0

    package init() {}

    package mutating func record(_ buffer: CVPixelBuffer, at time: Double) -> Bool {
        guard time - lastSample >= 0.09 else { return false }
        lastSample = time
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = CVPixelBufferIsPlanar(buffer)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange,
             kCVPixelFormatType_32BGRA: tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            tenBit = true
        default: return false
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer),
              width > 0, height > 0 else { return false }
        var changed = 0
        let comparable = previous.count == current.count && width == lastWidth && height == lastHeight
        for y in 0..<Self.rows {
            let row = base.advanced(by: (2 * y + 1) * height / (2 * Self.rows) * stride)
            for x in 0..<Self.columns {
                let column = (2 * x + 1) * width / (2 * Self.columns)
                let luma: UInt8
                if tenBit {
                    luma = row.load(fromByteOffset: 2 * column + 1, as: UInt8.self)
                } else if planar {
                    luma = row.load(fromByteOffset: column, as: UInt8.self)
                } else {
                    let pixel = row.advanced(by: 4 * column)
                    let green = Int(pixel.load(fromByteOffset: 1, as: UInt8.self))
                    let red = Int(pixel.load(fromByteOffset: 2, as: UInt8.self))
                    let blue = Int(pixel.load(as: UInt8.self))
                    luma = UInt8((2 * green + red + blue) / 4)
                }
                let index = y * Self.columns + x
                if comparable, abs(Int(luma) - Int(previous[index])) >= 22 { changed += 1 }
                current[index] = luma
            }
        }
        if previous.isEmpty { previous = current }
        else { swap(&previous, &current) }
        lastWidth = width
        lastHeight = height
        return changed >= 4
    }
}
