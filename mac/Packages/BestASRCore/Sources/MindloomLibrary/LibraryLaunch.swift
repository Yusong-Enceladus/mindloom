import BestASRRemoteOrganizer
import Darwin
import Foundation

/// Which kind of build is running. Only `release` (the product, bundle id
/// `app.mindloom`) opens the owner's real library by default.
public enum MindloomBuildFlavor: String, Equatable, Sendable {
  /// The product (`-configuration Release`).
  case release
  /// Mindloom Preview (`-configuration Preview`): synthetic data only.
  case preview
  /// Debug and every other configuration.
  case development
}

/// The library this launch opens and how (v12 phase B, ALIGNMENT 根-10).
public struct LibraryLaunch: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    /// The owner's real library (`~/Library/Application Support/Mindloom`;
    /// `bestASR` before 2026-10-06, moved by the switch script; `LibraryFolderCarryOver`).
    case ownerLibrary
    /// A separate root named with `-BestASRDataRoot` (a rehearsal copy, a
    /// verification clone): the App behaves as it does on the real library.
    case separateRoot
    /// Demo mode: a root marked synthetic, opened with `-MindloomDemoRoot`
    /// (or by Mindloom Preview). Its time zone, owner names, Spark address,
    /// key and 「我」 come from the root itself; dictation is not kept.
    case demo
  }

  public let root: URL
  public let mode: Mode

  public init(root: URL, mode: Mode) {
    self.root = root
    self.mode = mode
  }

  public var isDemo: Bool { mode == .demo }
}

public enum LibraryLaunchError: Error, Equatable, Sendable {
  /// A development build was started without naming a library.
  case developmentBuildNeedsLibrary
  /// `-MindloomDemoRoot` names a folder without the synthetic marker.
  case demoRootNotSynthetic
  /// Two arguments name different libraries.
  case conflictingArguments
  /// An argument is misspelled, repeated or has no usable value.
  case malformedArgument(String)
  /// The named root is the real library, inside it, or contains it, or is
  /// not an absolute path.
  case invalidRoot(BestASRDataRootSelection.SelectionError)
  /// Mindloom Preview names no default root.
  case previewRootNotConfigured
  /// The account's home folder could not be read.
  case homeUnavailable
  /// The owner's library is still in bestASR's folder and bestASR is running.
  case previousAppUsesLibrary
  /// The owner's library is still in bestASR's folder (before the switch, or
  /// after a rollback). Only the switch script moves it; Mindloom opens
  /// nothing (`LibraryFolderCarryOver`).
  case libraryAtPreviousLocation
}

/// Reads the launch arguments, and only them (never persistent preferences),
/// to decide which library this launch opens.
///
/// - `-BestASRDataRoot <absolute path>`: a separate root (any build).
/// - `-MindloomDemoRoot <absolute path>`: demo mode on a synthetic root (any
///   build). `-BestASRDataRoot` may name the same root alongside it.
/// - `-BestASRUseRealLibrary YES`: a development build opens the real
///   library on purpose (a release build does so without it).
///
/// A release build with none of them opens the real library; a development
/// build refuses; Mindloom Preview opens its own synthetic root. A release
/// build (like Mindloom Preview) opens a root marked synthetic in demo mode,
/// whichever argument named it.
public enum LibraryLaunchSelection {
  public static let demoRootArgument = "MindloomDemoRoot"
  public static let useRealLibraryArgument = "BestASRUseRealLibrary"

  public static func resolve(
    arguments: [String],
    flavor: MindloomBuildFlavor,
    previewDefaultRoot: String? = nil,
    realLibraryRoot: URL
  ) throws -> LibraryLaunch {
    let separate: URL?
    do {
      separate = try BestASRDataRootSelection.separateDataRoot(
        arguments: arguments, realLibraryRoot: realLibraryRoot)
    } catch let error as BestASRDataRootSelection.SelectionError {
      if error == .malformedArgument {
        throw LibraryLaunchError.malformedArgument(BestASRDataRootSelection.launchArgumentKey)
      }
      throw LibraryLaunchError.invalidRoot(error)
    }
    let demo = try validatedRoot(
      try value(of: demoRootArgument, in: arguments), realLibraryRoot: realLibraryRoot)
    let useReal = try flag(useRealLibraryArgument, in: arguments)

    if useReal, separate != nil || demo != nil || flavor == .preview {
      throw LibraryLaunchError.conflictingArguments
    }
    if let demo {
      if let separate, !BestASRDataRootSelection.path(separate, isWithinOrEqualTo: demo)
        || !BestASRDataRootSelection.path(demo, isWithinOrEqualTo: separate)
      {
        throw LibraryLaunchError.conflictingArguments
      }
      guard isMarkedSynthetic(demo) else { throw LibraryLaunchError.demoRootNotSynthetic }
      return LibraryLaunch(root: demo, mode: .demo)
    }
    switch flavor {
    case .preview:
      // The preview never opens the real library. A marked root is demo
      // mode; an unmarked one is opened as a separate root, as before.
      let root: URL
      if let separate {
        root = separate
      } else {
        guard let configured = previewDefaultRoot, configured.hasPrefix("/") else {
          throw LibraryLaunchError.previewRootNotConfigured
        }
        guard let validated = try validatedRoot(configured, realLibraryRoot: realLibraryRoot)
        else { throw LibraryLaunchError.previewRootNotConfigured }
        root = validated
      }
      return LibraryLaunch(root: root, mode: isMarkedSynthetic(root) ? .demo : .separateRoot)
    case .release, .development:
      if let separate {
        // The product on a root marked synthetic is demo mode, as Mindloom
        // Preview's is: the root's own identity, names, Spark and time
        // zone, never the owner's preferences or link state (review v12-B
        // #12). A development build keeps its own preferences domain.
        let demo = flavor == .release && isMarkedSynthetic(separate)
        return LibraryLaunch(root: separate, mode: demo ? .demo : .separateRoot)
      }
      guard flavor == .release || useReal else {
        throw LibraryLaunchError.developmentBuildNeedsLibrary
      }
      return LibraryLaunch(root: realLibraryRoot, mode: .ownerLibrary)
    }
  }

  public static let noArmArgument = "MindloomNoArm"

  /// `-MindloomNoArm` (verification runs, in every build): fn and the
  /// dictation shortcut are never armed. Any mention but `-MindloomNoArm NO`
  /// counts, so a misspelled value still leaves them unarmed. Read from the
  /// launch arguments only, never from saved preferences.
  public static func noArmRequested(arguments: [String]) -> Bool {
    guard let index = arguments.dropFirst().firstIndex(of: "-" + noArmArgument) else {
      return false
    }
    return index + 1 >= arguments.count || arguments[index + 1] != "NO"
  }

  /// The root's synthetic marker is a regular file (not a link).
  public static func isMarkedSynthetic(_ root: URL) -> Bool {
    var entry = stat()
    let marker = root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    return lstat(marker.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFREG
  }

  private static func validatedRoot(_ requested: String?, realLibraryRoot: URL) throws -> URL? {
    guard let requested else { return nil }
    do {
      return try BestASRDataRootSelection.separateDataRoot(
        requested: requested, realLibraryRoot: realLibraryRoot)
    } catch let error as BestASRDataRootSelection.SelectionError {
      if error == .malformedArgument { throw LibraryLaunchError.malformedArgument(demoRootArgument) }
      throw LibraryLaunchError.invalidRoot(error)
    }
  }

  /// `-<key> <value>` exactly once, or nil when the key is not mentioned.
  /// Any other mention (misspelled case, `--key`, a second copy, no value)
  /// fails rather than being ignored.
  static func value(of key: String, in arguments: [String]) throws -> String? {
    let lowered = key.lowercased()
    let mentions = arguments.indices.dropFirst().filter {
      arguments[$0].lowercased().contains(lowered)
    }
    guard let first = mentions.first else { return nil }
    guard arguments[first] == "-" + key,
      mentions.allSatisfy({ $0 == first || $0 == first + 1 }),
      first + 1 < arguments.count, !arguments[first + 1].hasPrefix("-")
    else { throw LibraryLaunchError.malformedArgument(key) }
    return arguments[first + 1]
  }

  /// `-<key> YES`; `-<key> NO` or no mention is false; anything else fails.
  static func flag(_ key: String, in arguments: [String]) throws -> Bool {
    guard let value = try value(of: key, in: arguments) else { return false }
    switch value {
    case "YES": return true
    case "NO": return false
    default: throw LibraryLaunchError.malformedArgument(key)
    }
  }
}
