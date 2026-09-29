import AppKit
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path) else { fatalError("Cannot load image") }
    print(URL(fileURLWithPath:path).lastPathComponent, "logical size:", image.size)
    for rep in image.representations { print("pixels:", rep.pixelsWide, rep.pixelsHigh, "points:", rep.size) }
}
