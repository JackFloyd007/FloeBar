import OSLog

enum Constants { static let bundleIdentifier = "io.test.floebar" }
extension Logger { init(category: String) { self.init(subsystem: Constants.bundleIdentifier, category: category) } }
