import AVFoundation
import Foundation

struct EQProfile: Codable, Equatable, Sendable {
  static let maximumFilterCount = 32

  struct Filter: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
      case parametric
      case lowShelf
      case highShelf
      case lowPass
      case highPass
      case bandPass
      case notch

      var audioUnitType: AVAudioUnitEQFilterType {
        switch self {
        case .parametric: .parametric
        case .lowShelf: .lowShelf
        case .highShelf: .highShelf
        case .lowPass: .lowPass
        case .highPass: .highPass
        case .bandPass: .bandPass
        case .notch: .bandStop
        }
      }
    }

    let kind: Kind
    let frequency: Float
    let gain: Float
    let bandwidth: Float
  }

  let name: String
  let preamp: Float
  let filters: [Filter]
  var source: String?

  init(name: String, preamp: Float, filters: [Filter], source: String? = nil) {
    self.name = name
    self.preamp = preamp
    self.filters = filters
    self.source = source
  }

  func configure(_ equalizer: AVAudioUnitEQ, userGain: Float = 0) {
    precondition(equalizer.bands.count >= filters.count)
    equalizer.globalGain = preamp + userGain
    for band in equalizer.bands { band.bypass = true }
    for (filter, band) in zip(filters, equalizer.bands) {
      band.filterType = filter.kind.audioUnitType
      band.frequency = filter.frequency
      band.gain = filter.gain
      band.bandwidth = filter.bandwidth
      band.bypass = false
    }
  }
}

enum EQProfileError: LocalizedError, Equatable {
  case invalidLine(Int, String)
  case unsupportedCommand(Int, String)
  case unsupportedFilter(Int, String)
  case missingValue(Int, String)
  case noFilters
  case tooManyFilters(Int)

  var errorDescription: String? {
    switch self {
    case .invalidLine(let line, let text):
      "Line \(line) is not valid Equalizer APO syntax: \(text)"
    case .unsupportedCommand(let line, let command):
      "Line \(line) uses the unsupported \(command) command."
    case .unsupportedFilter(let line, let type):
      "Line \(line) uses the unsupported \(type) filter."
    case .missingValue(let line, let value):
      "Line \(line) is missing a valid \(value)."
    case .noFilters:
      "The file does not contain any enabled, supported filters."
    case .tooManyFilters(let count):
      "The profile contains \(count) enabled filters; Headphone EQ supports up to \(EQProfile.maximumFilterCount)."
    }
  }
}

enum EqualizerAPOParser {
  static func parse(_ text: String, name: String) throws -> EQProfile {
    var preamp: Float = 0
    var filters: [EQProfile.Filter] = []

    for (offset, substring) in text.split(
      omittingEmptySubsequences: false,
      whereSeparator: \Character.isNewline
    ).enumerated() {
      let lineNumber = offset + 1
      let line = substring.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      // Equalizer APO treats prose headers and other non-command lines as comments.
      guard let colon = line.firstIndex(of: ":") else { continue }

      let command = line[..<colon].trimmingCharacters(in: .whitespaces)
      let arguments = line[line.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)

      if command.caseInsensitiveCompare("Preamp") == .orderedSame {
        let tokens = arguments.split(whereSeparator: \Character.isWhitespace)
        guard let first = tokens.first, let value = Float(first), value.isFinite else {
          throw EQProfileError.missingValue(lineNumber, "preamp gain")
        }
        preamp += value
      } else if command.lowercased().hasPrefix("filter") {
        if let filter = try parseFilter(arguments, line: lineNumber) {
          filters.append(filter)
        }
      } else if ["equaliser", "equalizer", "notes", "dated"].contains(command.lowercased()) {
        continue
      } else {
        throw EQProfileError.unsupportedCommand(lineNumber, command)
      }
    }

    guard !filters.isEmpty else { throw EQProfileError.noFilters }
    guard filters.count <= EQProfile.maximumFilterCount else {
      throw EQProfileError.tooManyFilters(filters.count)
    }
    return EQProfile(name: name, preamp: preamp, filters: filters)
  }

  private static func parseFilter(
    _ arguments: String,
    line: Int
  ) throws -> EQProfile.Filter? {
    let tokens = arguments.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard tokens.count >= 4 else {
      throw EQProfileError.invalidLine(line, arguments)
    }
    if tokens[0].caseInsensitiveCompare("OFF") == .orderedSame { return nil }
    guard tokens[0].caseInsensitiveCompare("ON") == .orderedSame else {
      throw EQProfileError.invalidLine(line, arguments)
    }

    let type = tokens[1].uppercased()
    let kind: EQProfile.Filter.Kind
    switch type {
    case "PK", "PEQ", "MODAL": kind = .parametric
    case "LS", "LSC": kind = .lowShelf
    case "HS", "HSC": kind = .highShelf
    case "LP", "LPQ": kind = .lowPass
    case "HP", "HPQ": kind = .highPass
    case "BP": kind = .bandPass
    case "NO": kind = .notch
    default: throw EQProfileError.unsupportedFilter(line, type)
    }

    if tokens.count > 2, tokens[2].caseInsensitiveCompare("Fc") != .orderedSame {
      throw EQProfileError.unsupportedFilter(line, "\(type) slope/corner-frequency")
    }

    guard let frequency = value(after: "Fc", in: tokens),
      frequency.isFinite, frequency > 0
    else {
      throw EQProfileError.missingValue(line, "center frequency")
    }

    let needsGain: Bool =
      switch kind {
      case .parametric, .lowShelf, .highShelf: true
      default: false
      }
    let parsedGain = value(after: "Gain", in: tokens)
    if needsGain && parsedGain == nil {
      throw EQProfileError.missingValue(line, "filter gain")
    }

    let bandwidth: Float
    if let q = value(after: "Q", in: tokens) {
      guard q.isFinite, q > 0 else {
        throw EQProfileError.missingValue(line, "Q value")
      }
      bandwidth = qToOctaves(q)
    } else if let bwIndex = index(of: "BW", in: tokens) {
      let valueIndex =
        bwIndex + 1 < tokens.count
          && tokens[bwIndex + 1].caseInsensitiveCompare("Oct") == .orderedSame
        ? bwIndex + 2
        : bwIndex + 1
      guard valueIndex < tokens.count, let value = Float(tokens[valueIndex]),
        value.isFinite, value > 0
      else {
        throw EQProfileError.missingValue(line, "bandwidth")
      }
      bandwidth = value
    } else {
      switch kind {
      case .parametric:
        throw EQProfileError.missingValue(line, "Q or bandwidth")
      case .lowPass, .highPass, .bandPass:
        bandwidth = qToOctaves(sqrt(0.5))
      case .notch:
        bandwidth = qToOctaves(30)
      case .lowShelf, .highShelf:
        bandwidth = 0.9
      }
    }

    return EQProfile.Filter(
      kind: kind,
      frequency: frequency,
      gain: parsedGain ?? 0,
      bandwidth: bandwidth
    )
  }

  private static func index(of label: String, in tokens: [String]) -> Int? {
    tokens.firstIndex { $0.caseInsensitiveCompare(label) == .orderedSame }
  }

  private static func value(after label: String, in tokens: [String]) -> Float? {
    guard let position = index(of: label, in: tokens), position + 1 < tokens.count else {
      return nil
    }
    return Float(tokens[position + 1])
  }

  private static func qToOctaves(_ q: Float) -> Float {
    let root = sqrt(4 * q * q + 1)
    return log2((root + 1) / (root - 1))
  }
}
