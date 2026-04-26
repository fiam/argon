import CoreServices
import Foundation

final class FileWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let callback: () -> Void
  private let path: String

  init(path: String, callback: @escaping () -> Void) {
    self.path = path
    self.callback = callback
  }

  func start() {
    guard stream == nil else { return }

    let context = Unmanaged.passUnretained(self).toOpaque()
    var fsContext = FSEventStreamContext(
      version: 0,
      info: context,
      retain: nil,
      release: nil,
      copyDescription: nil
    )

    let paths = [path] as CFArray
    stream = FSEventStreamCreate(
      nil,
      { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.callback()
      },
      &fsContext,
      paths,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.3,  // latency — coalesce events within 300ms
      UInt32(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer)
    )

    if let stream {
      FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
      FSEventStreamStart(stream)
    }
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit {
    stop()
  }
}
