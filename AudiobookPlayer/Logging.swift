import Foundation
import os

enum AppLog {
    private static let logger = Logger(subsystem: "com.wdh.audiobook", category: "App")

    static func debug(_ message: @autoclosure () -> String) {
#if DEBUG
        let text = message()
        logger.debug("\(text, privacy: .public)")
#endif
    }
}
