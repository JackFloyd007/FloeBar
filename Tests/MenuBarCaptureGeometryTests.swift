import CoreGraphics

@main
enum MenuBarCaptureGeometryTests {
    static func main() {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 40)
        let retina = MenuBarCaptureGeometry(frame: frame, scale: 2)!
        precondition(retina.pixelWidth == 2940 && retina.pixelHeight == 80)
        let standard = MenuBarCaptureGeometry(frame: frame, scale: 1)!
        precondition(standard.pixelWidth == 1470 && standard.pixelHeight == 40)
        let secondary = MenuBarCaptureGeometry(frame: CGRect(x: -1920, y: 956, width: 1920, height: 40), scale: 2)!
        precondition(secondary.pixelWidth == 3840 && secondary.pixelHeight == 80)
        precondition(MenuBarCaptureGeometry(frame: frame, scale: 0) == nil)
        precondition(MenuBarCaptureGeometry(frame: frame, scale: .nan) == nil)
        precondition(MenuBarCaptureGeometry(frame: frame, scale: .infinity) == nil)
        precondition(MenuBarCaptureGeometry(frame: .zero, scale: 2) == nil)
        print("PASS: 7 capture geometry checks (Retina, 1x, secondary display, invalid input)")
    }
}
