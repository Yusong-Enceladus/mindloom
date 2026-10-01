import BestASRDomain
import Darwin
import Foundation
import UniformTypeIdentifiers

extension IntakeProcessor {
  /// Like `prepare`, but a `.zip` becomes the archive itself, kept only on
  /// this Mac, followed by each file inside it taken in by the same rules
  /// as a dropped file (privacy contract §5): audio and video stay on this
  /// Mac, images are normalized (and redacted when sent), text and
  /// documents become their text, other documents their bytes, and
  /// anything else is kept here. A zip inside a zip is expanded once more;
  /// deeper ones, and archives over the limits, are kept unexpanded.
  public func prepareAll(
    _ candidate: IntakeCandidate, capturedAt: Date, source: ItemSourceApplication?,
    origin: ItemSourceOrigin, limits: ZipArchiveReader.Limits = .standard
  ) -> [IntakeOutcome] {
    let archive = prepare(candidate, capturedAt: capturedAt, source: source, origin: origin)
    guard case .file(let url) = candidate, url.isFileURL,
      url.pathExtension.lowercased() == "zip", case .item = archive,
      let data = Self.readSmallRegularFile(url, maximumBytes: assetStore.maximumBytes)
    else { return [archive] }
    return [archive]
      + expand(
        data, archiveName: url.lastPathComponent, depth: 1, capturedAt: capturedAt,
        source: source, origin: origin, limits: limits)
  }

  private func expand(
    _ data: Data, archiveName: String, depth: Int, capturedAt: Date,
    source: ItemSourceApplication?, origin: ItemSourceOrigin, limits: ZipArchiveReader.Limits
  ) -> [IntakeOutcome] {
    let contents: ZipArchiveReader.Contents
    do {
      contents = try ZipArchiveReader(limits: limits).read(data, depth: depth)
    } catch {
      return [.rejected(Self.archiveMessage(error, name: archiveName))]
    }
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-zip-\(UUID().uuidString)", isDirectory: true)
    guard
      (try? fileManager.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])) != nil
    else { return [.rejected("无法展开 \(archiveName)，压缩包只保存在 Mac 上")] }
    defer { try? fileManager.removeItem(at: directory) }
    var outcomes: [IntakeOutcome] = []
    var step = 0
    func nextTime() -> Date {
      step += 1
      return capturedAt.addingTimeInterval(Double(step) * 0.000_01)
    }
    for member in contents.members {
      let label = "\(archiveName) › \(member.path)"
      let id = SessionID()
      let context = ContextFactory(
        id: id, capturedAt: nextTime(), source: source, origin: origin)
      let ext = (member.name as NSString).pathExtension.lowercased()
      if ext == "zip" || ZipArchiveReader.looksLikeZip(member.data) {
        // The inner archive is kept here; its files are taken in when it is
        // not too deep.
        outcomes.append(
          localOnly(
            member.data, filename: label, uniformType: "com.pkware.zip-archive",
            mediaType: "application/zip", context: context))
        if depth < limits.maximumDepth {
          outcomes += expand(
            member.data, archiveName: label, depth: depth + 1, capturedAt: nextTime(),
            source: source, origin: origin, limits: limits)
        }
        continue
      }
      let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
      if MediaContentSniffer.isAudioOrVideo(member.data)
        || type.map({ $0.conforms(to: .audiovisualContent) }) == true
        || MediaImportFormats.extensions.contains(ext)
      {
        // Audio and video inside an archive stay on this Mac.
        outcomes.append(
          localOnly(
            member.data, filename: label, uniformType: type?.identifier,
            mediaType: type?.preferredMIMEType ?? "application/octet-stream", context: context))
        continue
      }
      // The same rules as a dropped file, from a private temporary copy.
      let folder = directory.appendingPathComponent(String(step), isDirectory: true)
      let file = folder.appendingPathComponent(member.name)
      guard
        (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
        (try? member.data.write(to: file, options: [.withoutOverwriting])) != nil
      else {
        outcomes.append(.rejected("无法读取 \(label)，未收进来"))
        continue
      }
      let outcome = prepare(
        .file(file), id: id, capturedAt: context.capturedAt, source: source, origin: origin)
      try? fileManager.removeItem(at: file)
      switch outcome {
      case .item(let draft):
        outcomes.append(.item(draft.renamed(label)))
      case .media:
        // Never imported from a temporary copy: kept here as it is.
        outcomes.append(
          localOnly(
            member.data, filename: label, uniformType: type?.identifier,
            mediaType: "application/octet-stream", context: context))
      case .rejected(let message):
        outcomes.append(.rejected("\(label)：\(message)"))
      }
    }
    for skipped in contents.skipped {
      outcomes.append(.rejected("\(archiveName) › \(skipped)：加密或无法读取，只保存在压缩包里"))
    }
    return outcomes
  }

  private struct ContextFactory {
    let id: SessionID
    let capturedAt: Date
    let source: ItemSourceApplication?
    let origin: ItemSourceOrigin
  }

  private func localOnly(
    _ data: Data, filename: String, uniformType: String?, mediaType: String,
    context: ContextFactory
  ) -> IntakeOutcome {
    let ext = (filename as NSString).pathExtension.lowercased()
    do {
      let attachments = try assetStore.stage(
        sessionID: context.id,
        requests: [
          .init(
            role: .original, source: .data(data), originalFilename: filename,
            mediaType: mediaType, fileExtension: ext)
        ])
      return .item(
        UserItemDraft(
          id: context.id, kind: .file, capturedAt: context.capturedAt, source: context.source,
          sourceOrigin: context.origin, text: "", extractor: UserItemLimits.localOnlyExtractor,
          originalFilename: filename, attachments: attachments, uniformType: uniformType))
    } catch {
      assetStore.discard(sessionID: context.id)
      return .rejected("无法保存 \(filename)，未收进来")
    }
  }

  static func archiveMessage(_ error: Error, name: String) -> String {
    let reason =
      switch error as? ZipArchiveReader.ReadError {
      case .tooManyEntries: "文件超过 2000 个"
      case .tooLarge: "展开后超过 200 MB"
      case .ratioExceeded: "压缩比异常"
      case .tooDeep: "嵌套太深"
      case .unsupported: "格式不受支持"
      default: "无法读取"
      }
    return "\(name) \(reason)，未展开，压缩包只保存在 Mac 上"
  }

  /// The file's bytes, opened without following links, when it is a regular
  /// file of at most `maximumBytes`.
  static func readSmallRegularFile(_ url: URL, maximumBytes: UInt64) -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size > 0, UInt64(status.st_size) <= maximumBytes
    else { return nil }
    return try? handle.readToEnd()
  }
}
