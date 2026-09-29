import BestASRDomain
import BestASRPersistence
import CryptoKit
import Foundation

public enum ProductionPortableArchiveError: Error, Equatable, Sendable {
  case archiveExists
  case authenticationFailed
  case cancelled
  case destinationConflict
  case insufficientSpace
  case invalidArchive
  case invalidAsset
  case invalidSecret
  case unsupportedVersion
}

public struct ProductionPortableArchiveAsset: Codable, Equatable, Sendable {
  public let relativePath: String
  public let byteCount: UInt64
  public let digest: BestASRDomain.SHA256Digest

  public init(
    relativePath: String,
    byteCount: UInt64,
    digest: BestASRDomain.SHA256Digest
  ) {
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.digest = digest
  }
}

public struct ProductionPortableArchiveManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let createdAt: Date
  public let persistence: PortablePersistenceState
  public let assets: [ProductionPortableArchiveAsset]
  public let settings: [PortableSetting]

  public init(
    schemaVersion: Int = 2,
    createdAt: Date = Date(),
    persistence: PortablePersistenceState,
    assets: [ProductionPortableArchiveAsset],
    settings: [PortableSetting]
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.persistence = persistence
    self.assets = assets
    self.settings = settings
  }
}

public struct ProductionPortableArchiveExportResult: Equatable, Sendable {
  public let archiveID: UUID
  public let assetCount: Int
  public let plaintextAssetBytes: UInt64
  public let destination: URL
}

public struct ProductionPortableArchiveImportResult: Equatable, Sendable {
  public let archiveID: UUID
  public let importedAssetCount: Int
  public let reusedAssetCount: Int
  public let settings: [PortableSetting]
}

/// Version 2 is the production streaming container. Metadata is one encrypted
/// record and retained assets are encrypted in bounded chunks, so a two-hour
/// recording never has to fit in memory. Every record authenticates the public
/// KDF header plus its ordinal; an authenticated terminal record prevents
/// truncation and reordering.
public actor ProductionPortableArchiveStore {
  public static let defaultKDFIterations: UInt32 = 100_000

  private static let magic = Data("BESTASRARCHIVE2\n".utf8)
  private static let schemaVersion = 2
  private static let chunkSize = 1_048_576
  private static let maximumHeaderBytes = 65_536
  private static let maximumSealedRecordBytes = 268_435_456

  private struct Header: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let archiveID: UUID
    let kdf: PortableArchiveKDFParameters
  }

  private enum RecordKind: UInt8 {
    case manifest = 1
    case assetChunk = 2
    case end = 3
  }

  private struct ValidatedArchive {
    let header: Header
    let headerData: Data
    let dataOffset: UInt64
    let manifest: ProductionPortableArchiveManifest
  }

  public init() {}

  public func exportArchive(
    persistence: PortablePersistenceState,
    assetRoot: URL,
    settings: [PortableSetting],
    secret: PortableArchiveSecret,
    to destination: URL,
    kdfIterations: UInt32 = defaultKDFIterations
  ) async throws -> ProductionPortableArchiveExportResult {
    try Task.checkCancellation()
    guard kdfIterations >= 10_000 else {
      throw ProductionPortableArchiveError.invalidSecret
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw ProductionPortableArchiveError.archiveExists
    }
    let assets = try discoverAssets(
      persistence: persistence,
      assetRoot: assetRoot
    )
    let manifest = ProductionPortableArchiveManifest(
      persistence: persistence,
      assets: assets,
      settings: settings.sorted { $0.key < $1.key }
    )
    let manifestData = try Self.makeEncoder().encode(manifest)
    let plaintextBytes = assets.reduce(UInt64(0)) { $0 + $1.byteCount }
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try ensureSpace(
      at: parent,
      requiredBytes: plaintextBytes + UInt64(manifestData.count) + 4_194_304
    )

    let archiveID = UUID()
    let salt = Self.randomData(count: 16)
    let header = Header(
      schemaVersion: Self.schemaVersion,
      kind: "bestasr-portable-archive-stream",
      archiveID: archiveID,
      kdf: PortableArchiveKDFParameters(
        iterations: kdfIterations,
        salt: salt
      )
    )
    let headerData = try Self.makeEncoder().encode(header)
    let key = try Self.key(secret: secret, header: header)
    let staging = parent.appendingPathComponent(
      ".\(archiveID.uuidString).bestasrarchive-staging"
    )
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    let output = try FileHandle(forWritingTo: staging)
    do {
      try output.write(contentsOf: Self.magic)
      try output.write(contentsOf: Data.littleEndian(UInt32(headerData.count)))
      try output.write(contentsOf: headerData)
      var ordinal: UInt64 = 0
      var manifestRecord = Data([RecordKind.manifest.rawValue])
      manifestRecord.append(manifestData)
      try Self.writeRecord(
        manifestRecord,
        ordinal: ordinal,
        headerData: headerData,
        key: key,
        output: output
      )
      ordinal += 1

      for (assetIndex, asset) in assets.enumerated() {
        try Task.checkCancellation()
        let source = assetRoot.appendingPathComponent(asset.relativePath)
        let input = try FileHandle(forReadingFrom: source)
        var hasher = SHA256()
        var chunkIndex: UInt32 = 0
        var readBytes: UInt64 = 0
        do {
          while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: Self.chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            readBytes += UInt64(data.count)
            var plaintext = Data([RecordKind.assetChunk.rawValue])
            plaintext.appendLittleEndian(UInt32(assetIndex))
            plaintext.appendLittleEndian(chunkIndex)
            plaintext.append(data)
            try Self.writeRecord(
              plaintext,
              ordinal: ordinal,
              headerData: headerData,
              key: key,
              output: output
            )
            ordinal += 1
            chunkIndex += 1
          }
          try input.close()
        } catch {
          try? input.close()
          throw error
        }
        let digest = Self.digestString(hasher.finalize())
        guard readBytes == asset.byteCount,
          digest == asset.digest.value.lowercased()
        else { throw ProductionPortableArchiveError.invalidAsset }
      }

      var end = Data([RecordKind.end.rawValue])
      end.appendLittleEndian(ordinal)
      try Self.writeRecord(
        end,
        ordinal: ordinal,
        headerData: headerData,
        key: key,
        output: output
      )
      try output.synchronize()
      try output.close()
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: staging.path
      )
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch is CancellationError {
      try? output.close()
      throw ProductionPortableArchiveError.cancelled
    } catch {
      try? output.close()
      throw error
    }
    return ProductionPortableArchiveExportResult(
      archiveID: archiveID,
      assetCount: assets.count,
      plaintextAssetBytes: plaintextBytes,
      destination: destination
    )
  }

  public func importArchive(
    at archiveURL: URL,
    secret: PortableArchiveSecret,
    repository: GRDBDictationStore,
    assetRoot: URL
  ) async throws -> ProductionPortableArchiveImportResult {
    try Task.checkCancellation()
    let validated = try validateArchive(at: archiveURL, secret: secret)
    guard
      BestASRPersistenceSchema.supportsPortableImport(
        userVersion: validated.manifest.persistence.schemaVersion
      )
    else { throw ProductionPortableArchiveError.unsupportedVersion }

    var reused = 0
    var requiredBytes: UInt64 = 0
    for asset in validated.manifest.assets {
      let target = try Self.assetURL(root: assetRoot, relativePath: asset.relativePath)
      if FileManager.default.fileExists(atPath: target.path) {
        guard try Self.fileDigest(target) == asset.digest.value.lowercased() else {
          throw ProductionPortableArchiveError.destinationConflict
        }
        reused += 1
      } else {
        requiredBytes += asset.byteCount
      }
    }
    try ensureSpace(at: assetRoot, requiredBytes: requiredBytes + 4_194_304)

    let created = try await materializeAssets(
      archiveURL: archiveURL,
      validated: validated,
      secret: secret,
      assetRoot: assetRoot
    )
    do {
      try await repository.importPortablePersistenceState(
        validated.manifest.persistence
      )
    } catch {
      for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
      throw ProductionPortableArchiveError.destinationConflict
    }
    return ProductionPortableArchiveImportResult(
      archiveID: validated.header.archiveID,
      importedAssetCount: created.count,
      reusedAssetCount: reused,
      settings: validated.manifest.settings
    )
  }

  private func validateArchive(
    at url: URL,
    secret: PortableArchiveSecret
  ) throws -> ValidatedArchive {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let prefix = try Self.readExact(input, count: Self.magic.count)
    guard prefix == Self.magic else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    let headerLengthData = try Self.readExact(input, count: 4)
    let headerLength = Int(try headerLengthData.readLittleEndian(UInt32.self))
    guard headerLength > 0, headerLength <= Self.maximumHeaderBytes else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    let headerData = try Self.readExact(input, count: headerLength)
    let header: Header
    do { header = try Self.makeDecoder().decode(Header.self, from: headerData) } catch {
      throw ProductionPortableArchiveError.invalidArchive
    }
    guard header.schemaVersion == Self.schemaVersion,
      header.kind == "bestasr-portable-archive-stream",
      header.kdf.algorithm == "PBKDF2-HMAC-SHA256",
      header.kdf.iterations >= 10_000,
      header.kdf.salt.count >= 16
    else { throw ProductionPortableArchiveError.unsupportedVersion }
    let key = try Self.key(secret: secret, header: header)
    let dataOffset = UInt64(Self.magic.count + 4 + headerLength)
    var ordinal: UInt64 = 0
    var manifest: ProductionPortableArchiveManifest?
    var hashers: [SHA256] = []
    var byteCounts: [UInt64] = []
    var expectedChunk: [UInt32] = []
    var sawEnd = false

    while !sawEnd {
      let sealed = try Self.readSealedRecord(input)
      let plaintext: Data
      do {
        let box = try AES.GCM.SealedBox(combined: sealed)
        plaintext = try AES.GCM.open(
          box,
          using: key,
          authenticating: Self.aad(headerData: headerData, ordinal: ordinal)
        )
      } catch {
        throw ProductionPortableArchiveError.authenticationFailed
      }
      guard let rawKind = plaintext.first,
        let kind = RecordKind(rawValue: rawKind)
      else { throw ProductionPortableArchiveError.invalidArchive }
      switch kind {
      case .manifest:
        guard ordinal == 0, manifest == nil else {
          throw ProductionPortableArchiveError.invalidArchive
        }
        let decoded: ProductionPortableArchiveManifest
        do {
          decoded = try Self.makeDecoder().decode(
            ProductionPortableArchiveManifest.self,
            from: plaintext.dropFirst()
          )
        } catch { throw ProductionPortableArchiveError.invalidArchive }
        try Self.validateManifest(decoded)
        manifest = decoded
        hashers = Array(repeating: SHA256(), count: decoded.assets.count)
        byteCounts = Array(repeating: 0, count: decoded.assets.count)
        expectedChunk = Array(repeating: 0, count: decoded.assets.count)
      case .assetChunk:
        guard let manifest, plaintext.count >= 9 else {
          throw ProductionPortableArchiveError.invalidArchive
        }
        let index = Int(try plaintext.readLittleEndian(UInt32.self, at: 1))
        let sequence = try plaintext.readLittleEndian(UInt32.self, at: 5)
        guard index >= 0, index < manifest.assets.count,
          sequence == expectedChunk[index]
        else { throw ProductionPortableArchiveError.invalidArchive }
        let bytes = plaintext.dropFirst(9)
        guard !bytes.isEmpty,
          byteCounts[index] + UInt64(bytes.count)
            <= manifest.assets[index].byteCount
        else { throw ProductionPortableArchiveError.invalidAsset }
        hashers[index].update(data: bytes)
        byteCounts[index] += UInt64(bytes.count)
        expectedChunk[index] += 1
      case .end:
        guard plaintext.count == 9,
          try plaintext.readLittleEndian(UInt64.self, at: 1) == ordinal,
          let manifest
        else { throw ProductionPortableArchiveError.invalidArchive }
        for index in manifest.assets.indices {
          var hasher = hashers[index]
          guard byteCounts[index] == manifest.assets[index].byteCount,
            Self.digestString(hasher.finalize())
              == manifest.assets[index].digest.value.lowercased()
          else { throw ProductionPortableArchiveError.invalidAsset }
        }
        let trailing = try input.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
          throw ProductionPortableArchiveError.invalidArchive
        }
        sawEnd = true
      }
      ordinal += 1
    }
    guard let manifest else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    return ValidatedArchive(
      header: header,
      headerData: headerData,
      dataOffset: dataOffset,
      manifest: manifest
    )
  }

  private func materializeAssets(
    archiveURL: URL,
    validated: ValidatedArchive,
    secret: PortableArchiveSecret,
    assetRoot: URL
  ) async throws -> [URL] {
    let input = try FileHandle(forReadingFrom: archiveURL)
    var created: [URL] = []
    var openAssetIndex: Int?
    var openHandle: FileHandle?
    var openStaging: URL?
    let key = try Self.key(secret: secret, header: validated.header)
    do {
      try input.seek(toOffset: validated.dataOffset)
      var ordinal: UInt64 = 0
      while true {
        try Task.checkCancellation()
        let sealed = try Self.readSealedRecord(input)
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(
          box,
          using: key,
          authenticating: Self.aad(
            headerData: validated.headerData,
            ordinal: ordinal
          )
        )
        guard let rawKind = plaintext.first,
          let kind = RecordKind(rawValue: rawKind)
        else { throw ProductionPortableArchiveError.invalidArchive }
        if kind == .end { break }
        guard kind == .assetChunk else {
          ordinal += 1
          continue
        }
        let index = Int(try plaintext.readLittleEndian(UInt32.self, at: 1))
        let asset = validated.manifest.assets[index]
        let target = try Self.assetURL(
          root: assetRoot,
          relativePath: asset.relativePath
        )
        if FileManager.default.fileExists(atPath: target.path) {
          ordinal += 1
          continue
        }
        if openAssetIndex != index {
          try Self.finishMaterializedAsset(
            handle: &openHandle,
            staging: &openStaging,
            target: openAssetIndex.map {
              try Self.assetURL(
                root: assetRoot,
                relativePath: validated.manifest.assets[$0].relativePath
              )
            },
            created: &created
          )
          try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          let staging = target.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).archive-importing"
          )
          guard FileManager.default.createFile(atPath: staging.path, contents: nil)
          else { throw ProductionPortableArchiveError.invalidAsset }
          openAssetIndex = index
          openStaging = staging
          openHandle = try FileHandle(forWritingTo: staging)
        }
        try openHandle?.write(contentsOf: plaintext.dropFirst(9))
        ordinal += 1
      }
      try Self.finishMaterializedAsset(
        handle: &openHandle,
        staging: &openStaging,
        target: openAssetIndex.map {
          try Self.assetURL(
            root: assetRoot,
            relativePath: validated.manifest.assets[$0].relativePath
          )
        },
        created: &created
      )
      try input.close()
      for url in created {
        let relative = try Self.relativePath(of: url, under: assetRoot)
        guard
          let asset = validated.manifest.assets.first(where: {
            $0.relativePath == relative
          }),
          try Self.fileDigest(url) == asset.digest.value.lowercased()
        else { throw ProductionPortableArchiveError.invalidAsset }
      }
      return created
    } catch is CancellationError {
      try? openHandle?.close()
      if let openStaging { try? FileManager.default.removeItem(at: openStaging) }
      for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
      try? input.close()
      throw ProductionPortableArchiveError.cancelled
    } catch {
      try? openHandle?.close()
      if let openStaging { try? FileManager.default.removeItem(at: openStaging) }
      for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
      try? input.close()
      throw error
    }
  }

  private func discoverAssets(
    persistence: PortablePersistenceState,
    assetRoot: URL
  ) throws -> [ProductionPortableArchiveAsset] {
    let sessionIDs = try Self.sessionIDsWithRetainedSourceAudio(in: persistence)
    let requiredReferences = try Self.requiredAssetReferences(
      in: persistence,
      retainedSessionIDs: sessionIDs
    )
    let sessionsRoot = assetRoot.appendingPathComponent("sessions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
      if requiredReferences.isEmpty { return [] }
      throw ProductionPortableArchiveError.invalidAsset
    }
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionsRoot,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { throw ProductionPortableArchiveError.invalidAsset }
    var assets: [ProductionPortableArchiveAsset] = []
    var discovered = Set<String>()
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      guard values.isSymbolicLink != true else {
        throw ProductionPortableArchiveError.invalidAsset
      }
      let relative = try Self.relativePath(of: url, under: assetRoot)
      let parts = relative.split(separator: "/").map(String.init)
      guard parts.count >= 4,
        parts[0] == "sessions",
        sessionIDs.contains(parts[1].lowercased())
      else { continue }
      let include: Bool
      if parts[2] == "source" {
        include = parts.count == 4
      } else if parts[2] == "journal" {
        include =
          parts.count == 4
          && ["manifest.json", "production-metadata.json"].contains(parts[3])
          || parts.count == 5
            && parts[3] == "chunks"
            && parts[4].hasSuffix(".pcm")
      } else {
        include = false
      }
      guard include else { continue }
      let size = UInt64(values.fileSize ?? 0)
      guard size > 0, discovered.insert(relative).inserted else {
        throw ProductionPortableArchiveError.invalidAsset
      }
      assets.append(
        ProductionPortableArchiveAsset(
          relativePath: relative,
          byteCount: size,
          digest: try SHA256Digest(Self.fileDigest(url))
        )
      )
    }
    guard requiredReferences.isSubset(of: discovered) else {
      throw ProductionPortableArchiveError.invalidAsset
    }
    return assets.sorted { $0.relativePath < $1.relativePath }
  }

  private static func validateManifest(
    _ manifest: ProductionPortableArchiveManifest
  ) throws {
    guard manifest.schemaVersion == schemaVersion,
      BestASRPersistenceSchema.supportsPortableImport(
        userVersion: manifest.persistence.schemaVersion
      ),
      Set(manifest.assets.map(\.relativePath)).count == manifest.assets.count,
      Set(manifest.settings.map(\.key)).count == manifest.settings.count,
      manifest.assets.allSatisfy({
        $0.byteCount > 0 && safeAssetReference($0.relativePath)
      })
    else { throw ProductionPortableArchiveError.unsupportedVersion }
  }

  private static func sessionIDsWithRetainedSourceAudio(
    in state: PortablePersistenceState
  ) throws -> Set<String> {
    guard let table = state.tables.first(where: { $0.name == "sessions" }),
      let idIndex = table.columns.firstIndex(of: "id"),
      let retentionIndex = table.columns.firstIndex(of: "source_audio_retention")
    else { throw ProductionPortableArchiveError.invalidArchive }
    var result = Set<String>()
    for row in table.rows {
      guard row.indices.contains(idIndex), row.indices.contains(retentionIndex),
        case .text(let value) = row[idIndex], UUID(uuidString: value) != nil,
        case .text(let retention) = row[retentionIndex],
        SourceAudioRetention(rawValue: retention) != nil
      else {
        throw ProductionPortableArchiveError.invalidArchive
      }
      if retention == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue {
        result.insert(value.lowercased())
      }
    }
    return result
  }

  private static func requiredAssetReferences(
    in state: PortablePersistenceState,
    retainedSessionIDs: Set<String>
  ) throws -> Set<String> {
    var result = Set<String>()
    for tableName in ["tracks", "audio_chunks", "session_source_assets"] {
      guard let table = state.tables.first(where: { $0.name == tableName }),
        let referenceIndex = table.columns.firstIndex(of: "asset_reference"),
        let sessionIndex = table.columns.firstIndex(of: "session_id")
      else { throw ProductionPortableArchiveError.invalidArchive }
      for row in table.rows {
        guard row.indices.contains(referenceIndex), row.indices.contains(sessionIndex),
          case .text(let sessionID) = row[sessionIndex],
          UUID(uuidString: sessionID) != nil,
          case .text(let value) = row[referenceIndex], safeAssetReference(value)
        else {
          throw ProductionPortableArchiveError.invalidArchive
        }
        if retainedSessionIDs.contains(sessionID.lowercased()) {
          result.insert(value)
        }
      }
    }
    return result
  }

  private static func writeRecord(
    _ plaintext: Data,
    ordinal: UInt64,
    headerData: Data,
    key: SymmetricKey,
    output: FileHandle
  ) throws {
    let sealed = try AES.GCM.seal(
      plaintext,
      using: key,
      authenticating: aad(headerData: headerData, ordinal: ordinal)
    )
    guard let combined = sealed.combined else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    try output.write(contentsOf: Data.littleEndian(UInt64(combined.count)))
    try output.write(contentsOf: combined)
  }

  private static func readSealedRecord(_ input: FileHandle) throws -> Data {
    let lengthData = try readExact(input, count: 8)
    let length = try lengthData.readLittleEndian(UInt64.self)
    guard length >= 28, length <= UInt64(maximumSealedRecordBytes) else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    return try readExact(input, count: Int(length))
  }

  private static func readExact(_ input: FileHandle, count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
      let next = try input.read(upToCount: count - result.count) ?? Data()
      guard !next.isEmpty else {
        throw ProductionPortableArchiveError.invalidArchive
      }
      result.append(next)
    }
    return result
  }

  private static func key(
    secret: PortableArchiveSecret,
    header: Header
  ) throws -> SymmetricKey {
    do {
      return SymmetricKey(
        data: try PortableSecretKDF.deriveKeyData(
          secret: secret.bytes,
          salt: header.kdf.salt,
          iterations: header.kdf.iterations
        )
      )
    } catch {
      throw ProductionPortableArchiveError.invalidSecret
    }
  }

  private static func aad(headerData: Data, ordinal: UInt64) -> Data {
    var value = magic
    value.append(headerData)
    value.appendLittleEndian(ordinal)
    return value
  }

  private static func finishMaterializedAsset(
    handle: inout FileHandle?,
    staging: inout URL?,
    target: URL?,
    created: inout [URL]
  ) throws {
    guard let activeHandle = handle, let activeStaging = staging,
      let target
    else { return }
    try activeHandle.synchronize()
    try activeHandle.close()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: activeStaging.path
    )
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw ProductionPortableArchiveError.destinationConflict
    }
    try FileManager.default.moveItem(at: activeStaging, to: target)
    created.append(target)
    handle = nil
    staging = nil
  }

  private func ensureSpace(at url: URL, requiredBytes: UInt64) throws {
    let values = try url.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    )
    guard
      UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
        >= requiredBytes
    else { throw ProductionPortableArchiveError.insufficientSpace }
  }

  private static func assetURL(root: URL, relativePath: String) throws -> URL {
    guard safeAssetReference(relativePath) else {
      throw ProductionPortableArchiveError.invalidAsset
    }
    let standardizedRoot = root.standardizedFileURL
    let target = standardizedRoot.appendingPathComponent(relativePath)
      .standardizedFileURL
    guard target.path.hasPrefix(standardizedRoot.path + "/") else {
      throw ProductionPortableArchiveError.invalidAsset
    }
    return target
  }

  private static func relativePath(of url: URL, under root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else {
      throw ProductionPortableArchiveError.invalidAsset
    }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private static func safeAssetReference(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.hasPrefix("/"), !value.contains("\\"), !value.contains("://")
    else { return false }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty
      && parts.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
      }
  }

  private static func fileDigest(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hasher = SHA256()
    while true {
      let data = try input.read(upToCount: chunkSize) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return digestString(hasher.finalize())
  }

  private static func digestString<D: Sequence>(_ digest: D) -> String
  where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func randomData(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data(
      (0..<count).map {
        _ in UInt8.random(in: .min ... .max, using: &generator)
      })
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

extension Data {
  fileprivate static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var copy = value.littleEndian
    return Swift.withUnsafeBytes(of: &copy) { Data($0) }
  }

  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    append(Self.littleEndian(value))
  }

  fileprivate func readLittleEndian<T: FixedWidthInteger>(
    _ type: T.Type,
    at offset: Int = 0
  ) throws -> T {
    guard offset >= 0, count >= offset + MemoryLayout<T>.size else {
      throw ProductionPortableArchiveError.invalidArchive
    }
    return withUnsafeBytes { rawBuffer in
      rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
    }
  }
}
