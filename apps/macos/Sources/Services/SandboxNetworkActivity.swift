import Foundation

struct SandboxNetworkActivityEvent: Decodable, Equatable, Identifiable, Sendable {
  let occurredAt: Date
  let kind: String
  let outcome: String
  let method: String?
  let host: String
  let port: Int
  let path: String?
  let detail: String?
  let bytesUp: UInt64
  let bytesDown: UInt64

  var id: String {
    [
      SandboxNetworkActivityLogStore.formatTimestamp(occurredAt),
      kind,
      outcome,
      method ?? "",
      host,
      String(port),
      path ?? "",
      detail ?? "",
      String(bytesUp),
      String(bytesDown),
    ].joined(separator: "|")
  }

  private enum CodingKeys: String, CodingKey {
    case occurredAt = "occurred_at"
    case kind
    case outcome
    case method
    case host
    case port
    case path
    case detail
    case bytesUp = "bytes_up"
    case bytesDown = "bytes_down"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let timestamp = try container.decode(String.self, forKey: .occurredAt)
    guard let occurredAt = SandboxNetworkActivityLogStore.parseTimestamp(timestamp)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .occurredAt,
        in: container,
        debugDescription: "Invalid proxy event timestamp"
      )
    }

    let kind = try container.decode(String.self, forKey: .kind)
    let outcome = try container.decode(String.self, forKey: .outcome)
    let method = try container.decodeIfPresent(String.self, forKey: .method)
    let host = try container.decode(String.self, forKey: .host)
    let port = try container.decode(Int.self, forKey: .port)
    let path = try container.decodeIfPresent(String.self, forKey: .path)
    let detail = try container.decodeIfPresent(String.self, forKey: .detail)
    let bytesUp = try container.decodeIfPresent(UInt64.self, forKey: .bytesUp) ?? 0
    let bytesDown = try container.decodeIfPresent(UInt64.self, forKey: .bytesDown) ?? 0

    self.occurredAt = occurredAt
    self.kind = kind
    self.outcome = outcome
    self.method = method
    self.host = host
    self.port = port
    self.path = path
    self.detail = detail
    self.bytesUp = bytesUp
    self.bytesDown = bytesDown
  }

  var title: String {
    if let method, !method.isEmpty {
      return "\(method) \(host):\(port)"
    }
    return "\(host):\(port)"
  }

  var statusLabel: String {
    switch outcome {
    case "proxied":
      "Proxied"
    case "denied":
      "Denied"
    default:
      outcome.capitalized
    }
  }

  var transferLabel: String {
    "↑ \(Self.formatBytes(bytesUp))  ↓ \(Self.formatBytes(bytesDown))"
  }

  private static func formatBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    formatter.zeroPadsFractionDigits = false
    return formatter.string(fromByteCount: Int64(value))
  }
}

enum SandboxNetworkActivityLogStore {
  private static func makeTimestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }

  fileprivate static func parseTimestamp(_ value: String) -> Date? {
    makeTimestampFormatter().date(from: value)
  }

  fileprivate static func formatTimestamp(_ value: Date) -> String {
    makeTimestampFormatter().string(from: value)
  }

  private static let directoryName = "argon-sandbox-network"

  static func logURL(for tabID: UUID) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent("\(tabID.uuidString.lowercased()).ndjson")
  }

  static func loadEvents(for tabID: UUID) -> [SandboxNetworkActivityEvent] {
    let url = logURL(for: tabID)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return []
    }

    let lines = contents.split(whereSeparator: \.isNewline)
    let decoder = JSONDecoder()
    let events =
      lines
      .compactMap { line -> SandboxNetworkActivityEvent? in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(SandboxNetworkActivityEvent.self, from: data)
      }
      .sorted { $0.occurredAt < $1.occurredAt }

    if events.count > 200 {
      return Array(events.prefix(200))
    }
    return events
  }
}
