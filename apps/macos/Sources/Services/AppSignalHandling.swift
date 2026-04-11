import Darwin

enum AppSignalHandling {
  typealias SignalHandler = (@convention(c) (Int32) -> Void)?
  typealias SignalInstaller = (Int32, SignalHandler) -> SignalHandler

  static func installEmbeddedTerminalHandlers(
    installer: SignalInstaller = Darwin.signal
  ) {
    _ = installer(SIGHUP, SIG_IGN)
  }
}
