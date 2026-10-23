import Foundation
import LocalSwitchCore
import XCTest

@MainActor final class AppIdentityTests: XCTestCase {
  func testNewModelStoreDoesNotAdoptOrAlterLegacyFiles() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: support) }
    let legacy = support.appendingPathComponent("LocalSwitch/Models", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let descriptor = ModelDescriptor.catalogue[0]
    let marker = legacy.appendingPathComponent("original-owner-data")
    let bytes = Data("Unchanged legacy model-store sentinel".utf8)
    try bytes.write(to: marker)

    let store = try ModelStore(root: PipAppIdentity.modelRoot(applicationSupport: support))
    XCTAssertNil(store.installedURL(for: descriptor))
    XCTAssertNotEqual(store.root, legacy)
    XCTAssertEqual(try Data(contentsOf: marker), bytes)
    XCTAssertEqual(
      store.root,
      support.appendingPathComponent(PipAppIdentity.displayName, isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true))
  }

  func testProtectedNamespacesRemainIndependentFromOriginalApp() {
    let services = [
      PipAppIdentity.historyService, PipAppIdentity.chatGPTService, PipAppIdentity.secretsService,
    ]
    XCTAssertEqual(Set(services).count, 3)
    XCTAssertEqual(
      services,
      [
        PipAppIdentity.bundleIdentifier + ".history",
        PipAppIdentity.bundleIdentifier + ".chatgpt",
        PipAppIdentity.bundleIdentifier + ".secrets",
      ])
    XCTAssertFalse(services.contains { $0.hasPrefix("app.localswitch.") })
    XCTAssertNotEqual(PipAppIdentity.bundleIdentifier, "app.localswitch.mac")
  }

  func testEditionUsesExpectedIdentityAndRejectsOtherEditionNamespace() throws {
    let variants = [
      (edition: "baseline", name: "Pip Hybrid Baseline", bundle: "app.pip.hybrid.baseline"),
      (edition: "pip", name: "Pip Hybrid", bundle: "app.pip.hybrid.mac"),
      (
        edition: "baseline-plus", name: "Pip Hybrid Baseline Plus",
        bundle: "app.pip.hybrid.baseline.plus"
      ),
      (edition: "pip-plus", name: "Pip Hybrid Plus", bundle: "app.pip.hybrid.mac.plus"),
    ]
    #if BASELINE_EDITION
      #if ENHANCED_EDITION
        let expected = variants[2]
      #else
        let expected = variants[0]
      #endif
      XCTAssertTrue(PipAppIdentity.isBaseline)
    #else
      #if ENHANCED_EDITION
        let expected = variants[3]
      #else
        let expected = variants[1]
      #endif
      XCTAssertFalse(PipAppIdentity.isBaseline)
    #endif
    #if ENHANCED_EDITION
      XCTAssertTrue(PipAppIdentity.isEnhanced)
      XCTAssertEqual(PipAppIdentity.version, "0.2.0")
    #else
      XCTAssertFalse(PipAppIdentity.isEnhanced)
      XCTAssertEqual(PipAppIdentity.version, "0.1.0")
    #endif
    let expectedEdition = expected.edition
    let expectedName = expected.name
    let expectedBundle = expected.bundle
    XCTAssertEqual(PipAppIdentity.edition, expectedEdition)
    XCTAssertEqual(PipAppIdentity.displayName, expectedName)
    XCTAssertEqual(PipAppIdentity.bundleIdentifier, expectedBundle)

    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: support) }
    for other in variants where other.bundle != expectedBundle {
      let otherRoot = support.appendingPathComponent(other.name, isDirectory: true)
      let otherModels = otherRoot.appendingPathComponent("Models", isDirectory: true)
      try FileManager.default.createDirectory(at: otherModels, withIntermediateDirectories: true)
      let marker = otherModels.appendingPathComponent("other-edition-sentinel")
      let bytes = Data("Unchanged other edition data".utf8)
      try bytes.write(to: marker)

      let store = try ModelStore(root: PipAppIdentity.modelRoot(applicationSupport: support))
      XCTAssertNil(store.installedURL(for: ModelDescriptor.catalogue[0]))
      XCTAssertNotEqual(store.root, otherModels)
      XCTAssertNotEqual(PipAppIdentity.dataRoot(applicationSupport: support), otherRoot)
      XCTAssertEqual(try Data(contentsOf: marker), bytes)
      for service in [
        PipAppIdentity.historyService, PipAppIdentity.chatGPTService, PipAppIdentity.secretsService,
      ] {
        XCTAssertFalse(
          [".history", ".chatgpt", ".secrets"].map { other.bundle + $0 }.contains(service))
      }
    }
  }

}
