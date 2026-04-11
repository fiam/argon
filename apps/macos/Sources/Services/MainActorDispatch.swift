import Foundation

enum MainActorDispatch {
  static func sync<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
    if Thread.isMainThread {
      return body()
    }

    return DispatchQueue.main.sync {
      body()
    }
  }

  static func async(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
      body()
      return
    }

    DispatchQueue.main.async {
      body()
    }
  }
}
