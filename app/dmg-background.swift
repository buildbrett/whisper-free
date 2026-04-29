import AppKit

// Generates a 660x400 PNG used as the DMG window background. The Finder window
// matches these dimensions; the AppleScript in build.sh positions the app icon
// and the Applications symlink over the visual hint zones.
//
// Coordinate notes: NSImage drawing is bottom-up; Finder window coordinates
// are top-down. We design here in NSImage coords and convert when needed.

let outputPath = CommandLine.arguments[1]
let width: CGFloat = 660
let height: CGFloat = 400

// Where Finder will place the icons (top-down, content area), and the same
// points expressed in NSImage coords for our drawing.
let iconYFinder: CGFloat = 170
let iconYDraw = height - iconYFinder
let appIconX: CGFloat = 165
let applicationsIconX: CGFloat = 495

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

// Subtle light gradient.
let gradient = NSGradient(
    starting: NSColor(calibratedWhite: 0.98, alpha: 1.0),
    ending: NSColor(calibratedWhite: 0.93, alpha: 1.0)
)!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 270)

// Arrow between the two icon positions, at the same y as the icon centers.
let arrowColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
arrowColor.setStroke()
arrowColor.setFill()

let shaft = NSBezierPath()
let shaftStart = NSPoint(x: appIconX + 90, y: iconYDraw)
let shaftEnd = NSPoint(x: applicationsIconX - 100, y: iconYDraw)
shaft.move(to: shaftStart)
shaft.line(to: shaftEnd)
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: shaftEnd.x + 18, y: iconYDraw))
head.line(to: NSPoint(x: shaftEnd.x - 6, y: iconYDraw - 16))
head.line(to: NSPoint(x: shaftEnd.x - 6, y: iconYDraw + 16))
head.close()
head.fill()

// "Drag to install" label below the icons.
let label = "Drag Whisper Free to your Applications folder"
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1.0)
]
let labelSize = (label as NSString).size(withAttributes: labelAttrs)
let labelOrigin = NSPoint(x: (width - labelSize.width) / 2, y: 80)
(label as NSString).draw(at: labelOrigin, withAttributes: labelAttrs)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("failed to encode PNG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
