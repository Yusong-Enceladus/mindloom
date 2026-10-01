import BestASRDomain
import BestASRIntake
import Darwin
import Foundation

/// Git research entry (V8 contract A7), off by default. For each watched
/// local repository and chosen branch, every new commit becomes an item: its
/// subject, body, author name, time, and the names of the files it changed
/// with how many were added, changed or deleted. File contents are never
/// read: the commands below compare commit trees only (`diff-tree
/// --name-status --no-renames` needs no file object), and nothing else is
/// asked of git. Overleaf projects cloned through git work the same way.
public struct GitCommit: Equatable, Sendable {
  public struct Change: Equatable, Sendable {
    /// `A`, `M`, `D`, `T`, … as git reports it.
    public let status: String
    public let path: String

    public init(status: String, path: String) {
      self.status = status
      self.path = path
    }
  }

  public let hash: String
  public let parents: [String]
  public let authorName: String
  public let authoredAt: Date
  public let subject: String
  public let body: String
  public let changes: [Change]

  public init(
    hash: String, parents: [String], authorName: String, authoredAt: Date, subject: String,
    body: String, changes: [Change]
  ) {
    self.hash = hash
    self.parents = parents
    self.authorName = authorName
    self.authoredAt = authoredAt
    self.subject = subject
    self.body = body
    self.changes = changes
  }
}

/// Runs the system's git with a fixed, read-only set of commands.
public struct GitRunner: Sendable {
  public let executable: URL
  public static let timeoutSeconds: TimeInterval = 20

  public init(executable: URL) {
    self.executable = executable
  }

  /// A real git: the Command Line Tools', Xcode's, or Homebrew's. Never the
  /// `/usr/bin/git` stub, which offers to install the developer tools.
  public static func locate(fileManager: FileManager = .default) -> GitRunner? {
    var candidates = ["/Library/Developer/CommandLineTools/usr/bin/git"]
    if let developer = try? fileManager.destinationOfSymbolicLink(
      atPath: "/var/db/xcode_select_link")
    {
      candidates.append((developer as NSString).appendingPathComponent("usr/bin/git"))
    }
    candidates += [
      "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/opt/homebrew/bin/git",
      "/usr/local/bin/git",
    ]
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map {
      GitRunner(executable: URL(fileURLWithPath: $0))
    }
  }

  public enum RunError: Error, Equatable, Sendable {
    case failed(Int32)
    case timedOut
    case launch
  }

  /// Settings that keep git's output plain and keep it from running anything
  /// a repository's configuration names.
  static let safety = [
    "--no-pager", "-c", "color.ui=false", "-c", "core.quotepath=off", "-c", "core.fsmonitor=false",
    "-c", "log.showSignature=false", "-c", "diff.external=", "-c", "i18n.logOutputEncoding=UTF-8",
  ]

  /// The only subcommands this entry uses; all read history, none reads a
  /// file's contents.
  static let allowedSubcommands: Set<String> = [
    "rev-parse", "symbolic-ref", "rev-list", "show", "diff-tree", "for-each-ref",
  ]

  public func run(_ arguments: [String], in repository: URL) throws -> Data {
    guard let subcommand = arguments.first, Self.allowedSubcommands.contains(subcommand) else {
      throw RunError.launch
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-C", repository.path] + Self.safety + arguments
    var environment: [String: String] = [
      "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1",
      "LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin",
    ]
    let inherited = ProcessInfo.processInfo.environment
    for key in ["HOME", "GIT_CONFIG_GLOBAL", "TMPDIR"] {
      if let value = inherited[key] { environment[key] = value }
    }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { throw RunError.launch }
    let reader = output.fileHandleForReading
    let collected = OutputCollector()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      collected.set(reader.readDataToEndOfFile())
      done.signal()
    }
    if done.wait(timeout: .now() + Self.timeoutSeconds) == .timedOut {
      process.terminate()
      process.waitUntilExit()
      throw RunError.timedOut
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw RunError.failed(process.terminationStatus) }
    return collected.data
  }

  private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func set(_ data: Data) { lock.withLock { stored = data } }
  }

  func text(_ arguments: [String], in repository: URL) throws -> String {
    String(decoding: try run(arguments, in: repository), as: UTF8.self)
  }

  // MARK: The commands

  /// The commit a local branch points at.
  public func head(of branch: String, in repository: URL) throws -> String {
    guard GitBranch.isSafeName(branch) else { throw RunError.failed(128) }
    let hash = try text(
      ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"], in: repository
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard GitBranch.isHash(hash) else { throw RunError.failed(128) }
    return hash
  }

  /// The branch checked out now (nil when detached).
  public func currentBranch(in repository: URL) -> String? {
    let name = try? text(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.flatMap { GitBranch.isSafeName($0) ? $0 : nil }
  }

  /// Local branch names.
  public func branches(in repository: URL) -> [String] {
    let output =
      (try? text(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repository)) ?? ""
    return output.split(separator: "\n").map(String.init).filter(GitBranch.isSafeName)
  }

  /// Commits on `head` that `since` does not have, oldest first, at most
  /// `limit` (the newest ones when there are more).
  public func newCommits(since: String, head: String, limit: Int, in repository: URL) throws
    -> [String]
  {
    guard GitBranch.isHash(since), GitBranch.isHash(head) else { throw RunError.failed(128) }
    let output = try text(
      ["rev-list", "--max-count=\(limit)", "\(since)..\(head)"], in: repository)
    return output.split(separator: "\n").map(String.init).filter(GitBranch.isHash).reversed()
  }

  /// One commit: its message and author, and the files it changed against
  /// its first parent (tree comparison only).
  public func commit(_ hash: String, in repository: URL) throws -> GitCommit {
    guard GitBranch.isHash(hash) else { throw RunError.failed(128) }
    let header = try run(
      ["show", "-s", "--no-show-signature", "--format=%H%x00%P%x00%an%x00%at%x00%s%x00%b", hash],
      in: repository)
    let fields = header.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    guard fields.count >= 6 else { throw RunError.failed(128) }
    let parents = fields[1].split(separator: " ").map(String.init).filter(GitBranch.isHash)
    var treeArguments = ["diff-tree", "-r", "--no-renames", "--no-ext-diff", "--name-status", "-z"]
    if let parent = parents.first {
      treeArguments += [parent, hash]
    } else {
      treeArguments += ["--root", hash]
    }
    let tree = try run(treeArguments, in: repository)
    return GitCommit(
      hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines), parents: parents,
      authorName: fields[2], authoredAt: Date(timeIntervalSince1970: Double(fields[3]) ?? 0),
      subject: fields[4],
      body: fields[5...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
      changes: Self.parseNameStatus(tree))
  }

  /// `--name-status -z`: status NUL path NUL …
  static func parseNameStatus(_ data: Data) -> [GitCommit.Change] {
    let parts = data.split(separator: 0, omittingEmptySubsequences: true).map {
      String(decoding: $0, as: UTF8.self)
    }
    var changes: [GitCommit.Change] = []
    var index = 0
    while index + 1 < parts.count {
      let status = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
      changes.append(.init(status: String(status.prefix(1)), path: parts[index + 1]))
      index += 2
    }
    return changes
  }
}

public enum GitBranch {
  public static func isHash(_ text: String) -> Bool {
    (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  /// Branch names the entry passes to git: no option-like or odd spelling.
  public static func isSafeName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"), !name.hasPrefix("/"),
      !name.hasSuffix("/"), !name.contains(".."), !name.hasSuffix(".lock"), !name.contains("@{")
    else { return false }
    return name.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) || "._-/+".unicodeScalars.contains($0)
    }
  }
}

/// Per repository and branch: the last commit accounted for.
public struct GitWatchState: Codable, Equatable, Sendable {
  /// `<repository id>|<branch>` → commit hash.
  public var heads: [String: String] = [:]

  public init() {}
}

public enum GitWatch {
  public static let maximumCommitsPerPass = 50
  public static let maximumListedFiles = 100

  public struct Status: Equatable, Sendable {
    public var repository: String
    public var message: String
  }

  /// New commits of every watched branch, as items. The first look at a
  /// branch only records where it is; a branch that was rewritten (its old
  /// commit is gone) starts again from where it is now.
  public static func plan(
    _ repositories: [WatchedRepository], runner: GitRunner, state: inout GitWatchState,
    now: Date, timeZone: TimeZone = .current
  ) -> (items: [EntryIntakeItem], problems: [Status]) {
    var items: [EntryIntakeItem] = []
    var problems: [Status] = []
    var live: Set<String> = []
    for repository in repositories {
      let url = URL(fileURLWithPath: repository.path, isDirectory: true)
      let branches =
        repository.branches.isEmpty
        ? runner.currentBranch(in: url).map { [$0] } ?? [] : repository.branches
      if branches.isEmpty {
        problems.append(.init(repository: repository.displayName, message: "读不到这个仓库的分支"))
        continue
      }
      for branch in branches {
        let key = "\(repository.id.uuidString)|\(branch)"
        live.insert(key)
        guard let head = try? runner.head(of: branch, in: url) else {
          problems.append(.init(repository: repository.displayName, message: "读不到分支 \(branch)"))
          continue
        }
        guard let last = state.heads[key] else {
          state.heads[key] = head
          continue
        }
        guard last != head else { continue }
        guard
          let hashes = try? runner.newCommits(
            since: last, head: head, limit: maximumCommitsPerPass, in: url)
        else {
          state.heads[key] = head
          continue
        }
        for hash in hashes {
          guard let commit = try? runner.commit(hash, in: url) else { continue }
          items.append(
            EntryIntakeItem(
              candidate: .text(
                GitItemText.text(
                  commit, repository: repository.displayName, branch: branch, timeZone: timeZone),
                extractor: EntryExtractor.gitCommit),
              source: EntrySource.named(EntrySource.git(repository.displayName)),
              capturedAt: min(commit.authoredAt, now),
              id: EntryIdentity.itemID(.git, key: "\(repository.path)|\(commit.hash)")))
        }
        state.heads[key] = head
      }
    }
    state.heads = state.heads.filter { live.contains($0.key) }
    return (items, problems)
  }
}

public enum GitItemText {
  public static func text(
    _ commit: GitCommit, repository: String, branch: String, timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    var lines = ["Git 提交：\(commit.subject.isEmpty ? "（没有标题）" : commit.subject)"]
    lines.append("仓库：\(repository) · 分支：\(branch) · 提交 \(commit.hash.prefix(8))")
    lines.append("作者：\(commit.authorName) · 时间：\(formatter.string(from: commit.authoredAt))")
    if !commit.body.isEmpty { lines.append(commit.body) }
    lines.append(stats(commit.changes))
    for change in commit.changes.prefix(GitWatch.maximumListedFiles) {
      lines.append("\(change.status)  \(change.path)")
    }
    if commit.changes.count > GitWatch.maximumListedFiles {
      lines.append("……另有 \(commit.changes.count - GitWatch.maximumListedFiles) 个文件")
    }
    return lines.joined(separator: "\n")
  }

  /// "改动：3 个文件（新增 1，修改 2）"; counts only, from the tree comparison.
  public static func stats(_ changes: [GitCommit.Change]) -> String {
    guard !changes.isEmpty else { return "改动：没有文件改动" }
    let words: [(String, String)] = [("A", "新增"), ("M", "修改"), ("D", "删除"), ("T", "类型改变")]
    var parts: [String] = []
    for (status, word) in words {
      let count = changes.filter { $0.status == status }.count
      if count > 0 { parts.append("\(word) \(count)") }
    }
    let other = changes.filter { !["A", "M", "D", "T"].contains($0.status) }.count
    if other > 0 { parts.append("其他 \(other)") }
    return "改动：\(changes.count) 个文件（\(parts.joined(separator: "，"))）"
  }
}
