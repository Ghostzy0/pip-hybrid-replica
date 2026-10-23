import Foundation

/// Source-controlled immutable publisher artifacts; fitting is an estimate for 4K context / one slot.
public struct ModelDescriptor: Identifiable, Codable, Sendable {
  public let id: String
  public let name: String
  public let summary: String
  public let filename: String
  public let bytes: Int64
  public let sha256: String
  public let downloadURL: URL
  public let licenseURL: URL
  public let memoryGiB: Double

  public init(
    id: String, name: String, summary: String, filename: String, bytes: Int64,
    sha256: String, downloadURL: URL, licenseURL: URL, memoryGiB: Double
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.filename = filename
    self.bytes = bytes
    self.sha256 = sha256
    self.downloadURL = downloadURL
    self.licenseURL = licenseURL
    self.memoryGiB = memoryGiB
  }

  public func fits(_ device: DeviceSnapshot) -> Bool {
    guard device.architecture == "arm64", device.unifiedMemory,
      device.recommendedWorkingSet > 0, bytes > 0,
      memoryGiB.isFinite, memoryGiB > 0
    else { return false }
    let gib = 1_073_741_824.0
    let physical = Double(device.physicalMemory)
    let reserve = max(4 * gib, physical * 0.2)
    let budget = min(max(0, physical - reserve), Double(device.recommendedWorkingSet) * 0.85)
    // memoryGiB includes weights + an intentionally conservative 4K KV/runtime/buffer allowance.
    return max(Double(bytes), memoryGiB * gib) <= budget
  }

  public static let catalogue: [ModelDescriptor] = [
    ModelDescriptor(
      id: "qwen3-0.6b-q8_0", name: "Qwen3 · Mini",
      summary:
        "A small first download for quick, simple conversations. Less capable than the larger models.",
      filename: "Qwen3-0.6B-Q8_0.gguf", bytes: 639_446_688,
      sha256: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/23749fefcc72300e3a2ad315e1317431b06b590a/Qwen3-0.6B-Q8_0.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/blob/23749fefcc72300e3a2ad315e1317431b06b590a/LICENSE"
      )!, memoryGiB: 2
    ),
    ModelDescriptor(
      id: "qwen3-4b-q4_k_m", name: "Qwen3 · Everyday",
      summary:
        "A compact choice for writing and summarising. Fit is estimated at 4K context; evaluate answers for your task.",
      filename: "Qwen3-4B-Q4_K_M.gguf", bytes: 2_497_280_256,
      sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-4B-GGUF/blob/bc640142c66e1fdd12af0bd68f40445458f3869b/LICENSE"
      )!, memoryGiB: 5
    ),
    ModelDescriptor(
      id: "qwen3-8b-q4_k_m", name: "Qwen3 · 8B Balanced",
      summary:
        "An 8B model in a 4-bit quantisation. A larger general-chat candidate; speed and quality are not yet qualified here.",
      filename: "Qwen3-8B-Q4_K_M.gguf", bytes: 5_027_783_488,
      sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q4_K_M.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-8B-GGUF/blob/7c41481f57cb95916b40956ab2f0b139b296d974/LICENSE"
      )!, memoryGiB: 8
    ),
    ModelDescriptor(
      id: "qwen3-14b-q4_k_m", name: "Qwen3 · 14B",
      summary:
        "A 14B candidate for Macs with more free memory. Larger downloads and slower loading; fit remains an estimate.",
      filename: "Qwen3-14B-Q4_K_M.gguf", bytes: 9_001_752_960,
      sha256: "500a8806e85ee9c83f3ae08420295592451379b4f8cf2d0f41c15dffeb6b81f0",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/530227a7d994db8eca5ab5ced2fb692b614357fd/Qwen3-14B-Q4_K_M.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-14B-GGUF/blob/530227a7d994db8eca5ab5ced2fb692b614357fd/LICENSE"
      )!, memoryGiB: 13
    ),
    ModelDescriptor(
      id: "qwen3-30b-a3b-q4_k_m", name: "Qwen3 · 30B MoE",
      summary:
        "All 30B weights count toward memory, despite roughly 3B active per token. Intended for higher-memory Macs.",
      filename: "Qwen3-30B-A3B-Q4_K_M.gguf", bytes: 18_556_685_824,
      sha256: "0d003f6662faee786ed5da3e31b29c978de5ae5d275c8794c606a7f3c01aa8f5",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-30B-A3B-GGUF/resolve/e4d4bafdfb96a411a163846265362aceb0b9c63a/Qwen3-30B-A3B-Q4_K_M.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-30B-A3B-GGUF/blob/e4d4bafdfb96a411a163846265362aceb0b9c63a/LICENSE"
      )!, memoryGiB: 22
    ),
    ModelDescriptor(
      id: "qwen3-1.7b-q8_0", name: "Qwen3 · 1.7B Compact",
      summary:
        "A step up from Mini with a smaller download than Everyday. Publisher supplies 8-bit weights for this entry.",
      filename: "Qwen3-1.7B-Q8_0.gguf", bytes: 1_834_426_016,
      sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/90862c4b9d2787eaed51d12237eafdfe7c5f6077/Qwen3-1.7B-Q8_0.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/blob/90862c4b9d2787eaed51d12237eafdfe7c5f6077/LICENSE"
      )!, memoryGiB: 3.5
    ),
    ModelDescriptor(
      id: "qwen3-32b-q4_k_m", name: "Qwen3 · 32B",
      summary:
        "A large dense model for higher-memory Macs. Requires substantial memory beyond the downloaded weights.",
      filename: "Qwen3-32B-Q4_K_M.gguf", bytes: 19_762_149_024,
      sha256: "efd971561896866f0e910cce52761ca77b1b138090c7f15fe284676d57d1f689",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-32B-GGUF/resolve/938a7432affaec9157f883a87164e2646ae17555/Qwen3-32B-Q4_K_M.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-32B-GGUF/blob/938a7432affaec9157f883a87164e2646ae17555/LICENSE"
      )!, memoryGiB: 25
    ),
    ModelDescriptor(
      id: "qwen3-8b-q8_0", name: "Qwen3 · 8B Precision",
      summary:
        "The 8-bit variant of 8B. Uses more memory and storage than 8B Balanced; no speed or quality advantage is promised.",
      filename: "Qwen3-8B-Q8_0.gguf", bytes: 8_709_518_112,
      sha256: "408b955510e196121c1c375201744783b5c9a43c7956d73fc78df54c66e883d6",
      downloadURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/7c41481f57cb95916b40956ab2f0b139b296d974/Qwen3-8B-Q8_0.gguf"
      )!,
      licenseURL: URL(
        string:
          "https://huggingface.co/Qwen/Qwen3-8B-GGUF/blob/7c41481f57cb95916b40956ab2f0b139b296d974/LICENSE"
      )!, memoryGiB: 12
    ),
  ]
}
