import Darwin
import Foundation

/// Owns the application slot for this macOS user, regardless of the bundle being launched.
enum LaneInstance {
    static let activation = Notification.Name("site.dong4j.lane.show-main-window")
    static let user = String(getuid())

    /// The kernel releases the lock at process exit, including after a crash. Keep its inode in place.
    static func claim() throws -> Bool {
        let directory = URL.applicationSupportDirectory.appending(path: "Lane", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: ".instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // Keep the successful descriptor for the lifetime of the app, without passing it to SSH.
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Forward the open request without using Launch Services to start a third process.
    static func activatePrimary() {
        DistributedNotificationCenter.default().postNotificationName(
            activation, object: user, userInfo: nil, deliverImmediately: true
        )
    }
}
