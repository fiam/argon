import Foundation

enum MainActorDispatch {
  static func sync<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread {
      return MainActor.assumeIsolated(body)
    }

    return DispatchQueue.main.sync {
      MainActor.assumeIsolated(body)
    }
  }

  static func async(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(body)
      return
    }

    DispatchQueue.main.async {
      MainActor.assumeIsolated(body)
    }
  }
}
