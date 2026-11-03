import CoreGraphics
import CoreImage
import Testing
@testable import LumenRender

struct SourceReferencedPatchTests {
    @Test func sourceReferenceStillKeepsPhysicalBlackAndAboveWhiteRadiance() {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let image = CIImage(color: .white).cropped(to: bounds).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -0.25, y: 1.5, z: 0.5, w: 1),
        ])
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let output = EditSupport.matchedPatch(image, to: image, within: CIImage(color: .white).cropped(to: bounds),
            enlargement: 1, precompositedEdges: true, sourceReferenced: true, context: context)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16, bounds: bounds, format: .RGBAf, colorSpace: space)
        #expect(abs(pixel[0]) < 0.0001)
        #expect(abs(pixel[1] - 1.5) < 0.0001)
        #expect(abs(pixel[2] - 0.5) < 0.0001 && abs(pixel[3] - 1) < 0.0001)
    }
}
