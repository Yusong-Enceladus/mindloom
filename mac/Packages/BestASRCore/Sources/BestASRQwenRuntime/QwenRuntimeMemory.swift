import MLX

/// MLX keeps freed GPU buffers for reuse, by default up to its whole memory
/// limit. A resident dictation App should keep only what a decode needs.
public enum QwenRuntimeMemory {
  public static func limitIdleBuffers(toBytes bytes: Int) {
    Memory.cacheLimit = max(0, bytes)
  }

  /// Returns the buffers MLX is holding for reuse. Called after releasing a
  /// model, whose memory is otherwise kept in the cache for the next load.
  public static func trimNow() {
    Memory.clearCache()
  }

  /// Active, cached and peak MLX allocations in bytes; sizes only.
  public static func usage() -> (active: Int, cached: Int, peak: Int) {
    (Memory.activeMemory, Memory.cacheMemory, Memory.peakMemory)
  }
}
