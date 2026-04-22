import Foundation
import Testing

@testable import Argon

@Suite("ArgonCLIInstallLink")
struct ArgonCLIInstallLinkTests {
  @Test("status reports installed when symlink matches bundled cli")
  func statusReportsInstalled() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let target = fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon")
    try writeExecutable(at: target)

    let linkPath = fixture.appendingPathComponent("usr/local/bin/argon").path
    try FileManager.default.createDirectory(
      at: fixture.appendingPathComponent("usr/local/bin"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target.path)

    let status = ArgonCLIInstallLink.status(
      paths: .init(linkPath: linkPath, targetPath: target.path)
    )

    #expect(status.state == .installed)
    #expect(status.isHealthy)
    #expect(!status.canRepair)
  }

  @Test("status reports missing when install link is absent")
  func statusReportsMissing() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let target = fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon")
    try writeExecutable(at: target)

    let status = ArgonCLIInstallLink.status(
      paths: .init(
        linkPath: fixture.appendingPathComponent("usr/local/bin/argon").path,
        targetPath: target.path
      )
    )

    #expect(status.state == .missing)
    #expect(status.canRepair)
  }

  @Test("status reports unexpected symlink target")
  func statusReportsUnexpectedTarget() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let expectedTarget = fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon")
    try writeExecutable(at: expectedTarget)

    let otherTarget = fixture.appendingPathComponent("Other.app/Contents/Resources/bin/argon")
    try writeExecutable(at: otherTarget)

    let linkPath = fixture.appendingPathComponent("usr/local/bin/argon").path
    try FileManager.default.createDirectory(
      at: fixture.appendingPathComponent("usr/local/bin"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: linkPath, withDestinationPath: otherTarget.path)

    let status = ArgonCLIInstallLink.status(
      paths: .init(linkPath: linkPath, targetPath: expectedTarget.path)
    )

    #expect(status.state == .pointsElsewhere(currentTarget: otherTarget.path))
    #expect(status.canRepair)
  }

  @Test("status reports occupied path when install target is a regular file")
  func statusReportsOccupiedPath() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let target = fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon")
    try writeExecutable(at: target)

    let linkURL = fixture.appendingPathComponent("usr/local/bin/argon")
    try FileManager.default.createDirectory(
      at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not a symlink".write(to: linkURL, atomically: true, encoding: .utf8)

    let status = ArgonCLIInstallLink.status(
      paths: .init(linkPath: linkURL.path, targetPath: target.path)
    )

    #expect(status.state == .occupiedByFile)
    #expect(status.canRepair)
  }

  @Test("status reports bundled cli unavailable when target is missing")
  func statusReportsBundledCLIUnavailable() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let status = ArgonCLIInstallLink.status(
      paths: .init(
        linkPath: fixture.appendingPathComponent("usr/local/bin/argon").path,
        targetPath: fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon").path
      )
    )

    #expect(status.state == .bundledCLIUnavailable)
    #expect(!status.canRepair)
  }

  @Test("repair creates the install link in a writable location")
  @MainActor
  func repairCreatesInstallLink() throws {
    let fixture = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let target = fixture.appendingPathComponent("Argon.app/Contents/Resources/bin/argon")
    try writeExecutable(at: target)

    let linkPath = fixture.appendingPathComponent("usr/local/bin/argon").path
    let status = try ArgonCLIInstallLink.repair(
      paths: .init(linkPath: linkPath, targetPath: target.path)
    )

    #expect(status.state == .installed)
    let symlinkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
    #expect(symlinkTarget == target.path)
  }

  private func makeFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeExecutable(at path: URL) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
  }
}
