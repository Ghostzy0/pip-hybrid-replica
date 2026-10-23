import Darwin
import Foundation
import Metal

/// Read-only capacity facts. Metal's working set is a view of the same physical pool on Apple Silicon.
public struct DeviceSnapshot: Codable, Sendable {
  public let chip: String
  public let physicalMemory: UInt64
  public let cpuCount: Int
  public let gpuName: String
  public let unifiedMemory: Bool
  public let recommendedWorkingSet: UInt64
  public let architecture: String

  public init(
    chip: String, physicalMemory: UInt64, cpuCount: Int, gpuName: String,
    unifiedMemory: Bool, recommendedWorkingSet: UInt64, architecture: String
  ) {
    self.chip = chip
    self.physicalMemory = physicalMemory
    self.cpuCount = cpuCount
    self.gpuName = gpuName
    self.unifiedMemory = unifiedMemory
    self.recommendedWorkingSet = recommendedWorkingSet
    self.architecture = architecture
  }

  public static func inspect() -> DeviceSnapshot {
    let gpu = MTLCreateSystemDefaultDevice()
    return DeviceSnapshot(
      chip: systemString("machdep.cpu.brand_string") ?? "Unknown processor",
      physicalMemory: ProcessInfo.processInfo.physicalMemory,
      cpuCount: ProcessInfo.processInfo.activeProcessorCount,
      gpuName: gpu?.name ?? "Metal unavailable",
      unifiedMemory: gpu?.hasUnifiedMemory ?? false,
      recommendedWorkingSet: gpu?.recommendedMaxWorkingSetSize ?? 0,
      architecture: systemString("hw.machine") ?? "unknown"
    )
  }

  private static func systemString(_ key: String) -> String? {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
  }
}
