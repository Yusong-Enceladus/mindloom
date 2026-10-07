import BestASRMemoryUI
import Foundation
import XCTest

final class SettingsDictationMetricsTests: XCTestCase {
  func testLatencyReadsAsHalfAndNinetyFivePercent() {
    let week = SettingsDictationMetrics.Latency(
      count: 56, p50Milliseconds: 420, p95Milliseconds: 780)
    XCTAssertEqual(
      SettingsDictationMetrics.latencyText(week), "一半在 0.42 秒内，95% 在 0.78 秒内（共 56 次）")
    XCTAssertEqual(SettingsDictationMetrics.latencyText(nil), "暂无记录")
    XCTAssertEqual(
      SettingsDictationMetrics.latencyText(
        .init(count: 0, p50Milliseconds: 0, p95Milliseconds: 0)), "暂无记录")
    XCTAssertEqual(SettingsDictationMetrics.seconds(12_345), "12.3 秒")
  }

  func testStorageNamesRecordingsModelsAndFiles() {
    var metrics = SettingsDictationMetrics()
    XCTAssertEqual(metrics.storageText, "正在读取…")
    XCTAssertEqual(metrics.memoryText, "正在读取…")
    metrics.recordingsBytes = 304_000_000
    metrics.modelsBytes = 5_400_000_000
    metrics.filesBytes = 12_000_000
    metrics.memoryBytes = 612_000_000
    XCTAssertTrue(metrics.storageText.hasPrefix("录音 "))
    XCTAssertTrue(metrics.storageText.contains(" · 模型 "))
    XCTAssertTrue(metrics.storageText.contains(" · 文件 "))
    XCTAssertTrue(metrics.memoryText.hasPrefix("当前 "))
  }

  /// Regression (review 2026-10-06): memory was shown in disk units, about
  /// 5% above Activity Monitor and the budgets (677,380,096 bytes read
  /// "677.4 MB" instead of "646 MB").
  func testMemoryUsesTheUnitsActivityMonitorUses() {
    var metrics = SettingsDictationMetrics()
    metrics.memoryBytes = 677_380_096
    XCTAssertEqual(
      metrics.memoryText,
      "当前 " + ByteCountFormatter.string(fromByteCount: 677_380_096, countStyle: .memory))
    XCTAssertTrue(metrics.memoryText.contains("646"), metrics.memoryText)
    metrics.recordingsBytes = 677_380_096
    metrics.modelsBytes = 0
    metrics.filesBytes = 0
    XCTAssertTrue(metrics.storageText.contains("677"), metrics.storageText)
  }
}
