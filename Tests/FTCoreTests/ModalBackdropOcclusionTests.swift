import XCTest
@testable import FTCore

/// 全画面の操作可能な幕(RN `Modal` の「Close modal」)が背面のボタンを覆うと判定されること、
/// 非対話の全画面容器は従来どおり覆いに数えないこと、切り抜きの失敗理由が向きの食い違いを言うこと。
final class ModalBackdropOcclusionTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func node(_ ref: Int, _ type: String, _ id: String?, _ label: String?,
                      _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 5)
    }

    func testFullScreenButtonDrawnAboveCoversTheButtonBehindIt() {
        let button = node(1201, "button", "btn_alert", "アラート", 16, 132, 370, 44)
        let backdrop = node(1206, "button", "modal-backdrop", "Close modal", 0, 0, 402, 874)
        let hit = OcclusionGeometry.occluder(of: button, in: [button, backdrop], screen: screen)
        XCTAssertEqual(hit?.ref, 1206)
    }

    func testFullScreenNonInteractiveContainerStillDoesNotCover() {
        let button = node(1201, "button", "btn_alert", "アラート", 16, 132, 370, 44)
        let container = node(1206, "other", "root", "Root", 0, 0, 402, 874)
        XCTAssertNil(OcclusionGeometry.occluder(of: button, in: [button, container], screen: screen))
    }

    func testBackdropDrawnBeforeTheButtonDoesNotCover() {
        let backdrop = node(1100, "button", "modal-backdrop", "Close modal", 0, 0, 402, 874)
        let button = node(1201, "button", "btn_alert", "アラート", 16, 132, 370, 44)
        XCTAssertNil(OcclusionGeometry.occluder(of: button, in: [backdrop, button], screen: screen))
    }

    func testCropFailureReasonNamesOrientationMismatch() throws {
        // 横長の画面に縦長の絵(1206x2622)
        let width = 12, height = 26
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let landscape = FTRect(x: 0, y: 0, width: 874, height: 402)
        XCTAssertTrue(VisionClassifier.cropFailureReason(png: data as Data, screen: landscape)
            .contains("not in the screen's orientation"))
        let portrait = FTRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(VisionClassifier.cropFailureReason(png: data as Data, screen: portrait)
            .contains("is it inside the screen"))
    }
}
