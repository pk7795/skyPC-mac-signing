import Foundation
import CoreFoundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let unmanaged = CFURLCreateBookmarkDataFromAliasRecord(nil, data as CFData) else { fatalError("Invalid native alias record") }
let bookmark = unmanaged.takeRetainedValue() as Data
var stale = false
let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
print("resolved:",url.path,"stale:",stale,"exists:",FileManager.default.fileExists(atPath:url.path))
