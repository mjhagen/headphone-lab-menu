import Foundation

struct AutoEqEntry: Codable, Equatable, Hashable, Sendable {
  let name: String
  let relativePath: String
  let source: String

  var detail: String {
    "by \(source)"
  }
}

enum AutoEqCatalogError: LocalizedError, Equatable {
  case invalidIndex
  case invalidPath(String)
  case invalidText

  var errorDescription: String? {
    switch self {
    case .invalidIndex:
      "AutoEq’s headphone index did not contain any usable profiles."
    case .invalidPath(let path):
      "AutoEq returned an invalid profile path: \(path)"
    case .invalidText:
      "The selected AutoEq profile was not valid UTF-8 text."
    }
  }
}

enum AutoEqIndexParser {
  static func parse(_ markdown: String) throws -> [AutoEqEntry] {
    var entries: [AutoEqEntry] = []
    entries.reserveCapacity(9_000)

    for substring in markdown.split(whereSeparator: \Character.isNewline) {
      let line = String(substring)
      guard line.hasPrefix("- ["),
        let nameEnd = line.range(of: "]("),
        let sourceStart = line.range(of: ") by ", options: .backwards)
      else { continue }

      let nameStart = line.index(line.startIndex, offsetBy: 3)
      guard nameStart < nameEnd.lowerBound,
        nameEnd.upperBound <= sourceStart.lowerBound
      else { continue }

      let name = String(line[nameStart..<nameEnd.lowerBound])
      var path = String(line[nameEnd.upperBound..<sourceStart.lowerBound])
      if path.hasPrefix("./") { path.removeFirst(2) }
      let source = String(line[sourceStart.upperBound...])
      guard !name.isEmpty, !path.isEmpty, !source.isEmpty else { continue }
      entries.append(AutoEqEntry(name: name, relativePath: path, source: source))
    }

    guard !entries.isEmpty else { throw AutoEqCatalogError.invalidIndex }
    return entries
  }
}

actor AutoEqCatalogClient {
  private let session: URLSession
  private let fileManager: FileManager
  private let indexURL = URL(
    string:
      "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md"
  )!
  private let resultsURL = URL(
    string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
  )!
  private let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

  init(session: URLSession = .shared, fileManager: FileManager = .default) {
    self.session = session
    self.fileManager = fileManager
  }

  func catalog() async throws -> [AutoEqEntry] {
    let cacheURL = try cacheFileURL()
    if isFresh(cacheURL), let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
      return try AutoEqIndexParser.parse(text)
    }

    do {
      let text = try await downloadText(from: indexURL)
      try fileManager.createDirectory(
        at: cacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
      return try AutoEqIndexParser.parse(text)
    } catch {
      if let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
        return try AutoEqIndexParser.parse(text)
      }
      throw error
    }
  }

  func profile(for entry: AutoEqEntry) async throws -> EQProfile {
    let url = try profileURL(for: entry)
    let text = try await downloadText(from: url)
    var profile = try EqualizerAPOParser.parse(text, name: entry.name)
    profile.source = entry.source
    return profile
  }

  func profileURL(for entry: AutoEqEntry) throws -> URL {
    let encodedComponents = entry.relativePath.split(separator: "/").map(String.init)
    guard !encodedComponents.isEmpty else {
      throw AutoEqCatalogError.invalidPath(entry.relativePath)
    }

    var url = resultsURL
    var decodedComponents: [String] = []
    for encoded in encodedComponents {
      guard let decoded = encoded.removingPercentEncoding,
        !decoded.isEmpty, decoded != ".", decoded != "..", !decoded.contains("/")
      else {
        throw AutoEqCatalogError.invalidPath(entry.relativePath)
      }
      decodedComponents.append(decoded)
      url.appendPathComponent(decoded, isDirectory: true)
    }

    guard let directoryName = decodedComponents.last else {
      throw AutoEqCatalogError.invalidPath(entry.relativePath)
    }
    url.appendPathComponent("\(directoryName) ParametricEQ.txt", isDirectory: false)
    return url
  }

  private func downloadText(from url: URL) async throws -> String {
    let (data, response) = try await session.data(from: url)
    if let response = response as? HTTPURLResponse,
      !(200..<300).contains(response.statusCode)
    {
      throw URLError(.badServerResponse)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw AutoEqCatalogError.invalidText
    }
    return text
  }

  private func cacheFileURL() throws -> URL {
    let cacheDirectory = try fileManager.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      cacheDirectory
      .appendingPathComponent("nl.mingo.HeadphoneLabMenu", isDirectory: true)
      .appendingPathComponent("AutoEq-INDEX.md", isDirectory: false)
  }

  private func isFresh(_ url: URL) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let modified = attributes[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < cacheLifetime
  }
}
