import AppKit
import Combine
import CryptoKit
import Foundation
import LocalSwitchCore
import SwiftUI
import UniformTypeIdentifiers

enum ChatGPTManagementOperation: String {
  case signIn = "Preparing sign-in…"
  case selectAccount = "Opening account…"
  case signOut = "Signing out…"
  case models = "Checking models…"
  case renewal = "Renewing session…"
}

@MainActor final class AppModel: ObservableObject {
  let device = DeviceSnapshot.inspect()
  let models: ModelStore
  let runtime = LocalRuntime()
  let chatGPT: ChatGPTConnection
  private let chatGPTSecrets: any SecretStore
  private let accountConnectionsEnabled: Bool
  private var signInURL: URL?
  @Published private(set) var chatGPTManagementOperation: ChatGPTManagementOperation?
  var chatGPTManagementAction: String? { chatGPTManagementOperation?.rawValue }
  var isSigningOutChatGPT: Bool { chatGPTManagementOperation == .signOut }
  private var chatGPTManagementID = UUID()
  var isManagingChatGPT: Bool { chatGPTManagementOperation != nil }
  @Published var cloudMode = false { didSet { pendingCloudReview = nil } }
  @Published var selectedChatGPTModel = "" { didSet { pendingCloudReview = nil } }
  @Published var pendingCloudReview: CloudReview? {
    didSet { if pendingCloudReview != nil { chatGPTWelcome = false } }
  }
  @Published var chatGPTWelcome = false
  private var welcomeAccountID: String?
  @Published var completionPulse: UUID?
  @Published private(set) var usingCloudGeneration = false
  var canSend: Bool {
    canUseChat
      && (cloudMode
        ? chatGPT.protectedStorageAvailable && !chatGPT.isAuthorizing && !isManagingChatGPT
          && !chatGPT.isRenewingSession
          && chatGPT.activeAccount?.isSignedIn == true
          && chatGPT.activeAccount?.planEnabled == true
          && chatGPT.models.contains(where: { $0.slug == selectedChatGPTModel })
        : installed)
  }
  @Published var selectedModelID: String {
    didSet { preferences.set(selectedModelID, forKey: "selectedModelID") }
  }
  @Published var messages: [ChatMessage] = [] { didSet { pendingCloudReview = nil } }
  @Published var conversations: [SavedConversation] = []
  @Published var draft = "" { didSet { pendingCloudReview = nil } }
  @Published var composerFocusRequest = UUID()
  @Published var error: String?
  @Published private(set) var historyAvailable = false
  @Published private(set) var historyNotice: String?
  @Published private(set) var temporarySession = false
  @Published var onboardingComplete: Bool
  @Published var isBusy = false
  @Published var status = "Ready when you are"
  @Published var appearance: String {
    didSet { preferences.set(appearance, forKey: "appearance") }
  }
  private var store: ChatStore?
  private var currentID = UUID()
  private var operationID = UUID()
  private var operation: Task<Void, Never>?
  private var observers = Set<AnyCancellable>()
  private let preferences: UserDefaults
  private var historySecrets: any SecretStore
  private var storageAvailable = true
  private var stopping = false
  private var lastCheckpoint = Date.distantPast
  private var recoveryCopy = false
  private var ownedCaptureRoot: URL?
  var selectedModel: ModelDescriptor {
    ModelDescriptor.catalogue.first { $0.id == selectedModelID } ?? ModelDescriptor.catalogue[0]
  }
  var installed: Bool { storageAvailable && models.installedURL(for: selectedModel) != nil }
  var canUseChat: Bool { storageAvailable && (historyAvailable || temporarySession) }
  var historySummary: String {
    temporarySession
      ? "Temporary chat · not saved" : (historyAvailable ? "History encrypted" : "History locked")
  }
  init(
    root: URL? = nil,
    preferences: UserDefaults = PipAppIdentity.preferences,
    historySecrets: (any SecretStore)? = nil, chatGPTSecrets: (any SecretStore)? = nil,
    chatGPTConfiguration: URLSessionConfiguration = .ephemeral,
    accountConnectionsEnabled: Bool = true
  ) {
    self.preferences = preferences
    self.accountConnectionsEnabled = accountConnectionsEnabled
    self.historySecrets =
      historySecrets ?? KeychainSecretStore(service: PipAppIdentity.historyService)
    let isCapture =
      ProcessInfo.processInfo.arguments.contains("--qa-output")
      || ProcessInfo.processInfo.arguments.contains("--qa-icon")
    let providerSecrets: any SecretStore =
      chatGPTSecrets
      ?? (isCapture
        ? PreviewSecretStore() : KeychainSecretStore(service: PipAppIdentity.chatGPTService))
    self.chatGPTSecrets = providerSecrets
    chatGPT = ChatGPTConnection(secrets: providerSecrets, configuration: chatGPTConfiguration)
    let initialError: String?
    do {
      let captureRoot =
        isCapture && root == nil
        ? FileManager.default.temporaryDirectory.appendingPathComponent(
          PipAppIdentity.bundleIdentifier + ".qa-\(ProcessInfo.processInfo.processIdentifier)",
          isDirectory: true) : nil
      ownedCaptureRoot = captureRoot
      models = try ModelStore(root: root ?? captureRoot?.appendingPathComponent("Models"))
      initialError = nil
    } catch {
      // Keep a readable interface on storage failure; operations are disabled and the failure is visible.
      models = ModelStore.unavailableStore()
      storageAvailable = false
      initialError =
        "Local storage could not be opened. Nothing will be downloaded or saved. \(error.localizedDescription)"
    }
    selectedModelID =
      preferences.string(forKey: "selectedModelID") ?? ModelDescriptor.catalogue[0].id
    onboardingComplete = preferences.bool(forKey: "onboardingComplete")
    appearance = preferences.string(forKey: "appearance") ?? "system"
    error = initialError
    if storageAvailable && !ProcessInfo.processInfo.arguments.contains("--qa-output")
      && !ProcessInfo.processInfo.arguments.contains("--qa-icon")
    {
      do {
        let history = try ChatStore(
          root: models.root.deletingLastPathComponent().appendingPathComponent("History"),
          secrets: self.historySecrets)
        store = history
        conversations = try history.load()
        historyAvailable = true
        historyNotice = nil
      } catch {
        historyNotice =
          "Encrypted history could not be opened. Existing files are preserved. \(error.localizedDescription)"
        store = nil
        historyAvailable = false
      }
    }
    if ProcessInfo.processInfo.arguments.contains("--qa-output"),
      ProcessInfo.processInfo.arguments.contains("--qa-history-locked")
    {
      historyNotice =
        "Synthetic locked-history preview. Your saved chats are preserved. Unlock history or explicitly choose a temporary session to continue."
    }
    models.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.objectWillChange.send() }
    }.store(in: &observers)
    chatGPT.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.reconcileChatGPT()
        self?.objectWillChange.send()
      }
    }.store(in: &observers)
    reconcileChatGPT()
  }
  /// Claim before scheduling, so repeated clicks cannot enqueue conflicting account operations.
  private func manageChatGPT(
    _ action: ChatGPTManagementOperation, preempt: Bool = false,
    work: @escaping @MainActor () async -> Void
  ) {
    guard !isBusy, preempt || (!isManagingChatGPT && !chatGPT.isAuthorizing),
      !(preempt && chatGPTManagementOperation == action)
    else { return }
    let ticket = UUID()
    chatGPTManagementID = ticket
    chatGPTManagementOperation = action
    pendingCloudReview = nil
    Task {
      guard chatGPTManagementID == ticket else { return }
      await work()
      guard chatGPTManagementID == ticket else { return }
      chatGPTManagementOperation = nil
      reconcileChatGPT()
    }
  }
  func startChatGPTSignIn(accountID: String? = nil, openBrowser: Bool = true) {
    guard accountConnectionsEnabled else {
      error =
        "This isolated acceptance session uses synthetic accounts. Use the ordinary app for your own connection."
      return
    }
    manageChatGPT(.signIn) { [self] in
      let ticket = chatGPTManagementID
      do {
        let url = try await chatGPT.beginSignIn(accountID: accountID)
        guard chatGPTManagementID == ticket else { return }
        signInURL = url
        if openBrowser { openChatGPTSignInPage() }
      } catch {
        guard chatGPTManagementID == ticket, !(error is CancellationError) else { return }
        self.error = error.localizedDescription
      }
    }
  }
  func openChatGPTSignInPage() {
    guard chatGPT.isAuthorizing, let url = signInURL else { return }
    NSWorkspace.shared.open(url)
  }
  func cancelChatGPTSignIn() {
    signInURL = nil
    chatGPT.cancelSignIn()
  }
  func selectChatGPTAccount(_ id: String) {
    manageChatGPT(.selectAccount) { [self] in
      signInURL = nil
      await chatGPT.selectAccount(id)
    }
  }
  func disconnectChatGPT() {
    guard !isBusy else { return }
    cloudMode = false
    // Sign-out may interrupt a renewal/catalogue request. Its ticket owns the final UI state.
    manageChatGPT(.signOut, preempt: true) { [self] in await chatGPT.disconnect() }
  }
  func refreshChatGPTModels() {
    manageChatGPT(.models) { [self] in await chatGPT.refreshModels() }
  }
  func renewChatGPTSession() {
    manageChatGPT(.renewal) { [self] in await chatGPT.renewSession() }
  }
  func retryChatGPTAccess() {
    guard !isBusy, !isManagingChatGPT, !chatGPT.isAuthorizing else { return }
    do {
      if let protected = chatGPTSecrets as? KeychainSecretStore {
        let interactive = protected.withUserInteraction(true)
        _ = try interactive.read("registrations.v1")
        _ = try interactive.read("host-id.v1")
      }
      try chatGPT.reloadProtectedStorage()
      reconcileChatGPT()
    } catch { self.error = error.localizedDescription }
  }
  private func reconcileChatGPT() {
    if !chatGPT.isAuthorizing { signInURL = nil }
    if !chatGPT.models.contains(where: { $0.slug == selectedChatGPTModel }) {
      selectedChatGPTModel = chatGPT.models.first?.slug ?? ""
    }
    if let account = chatGPT.activeAccount, account.isSignedIn, account.planEnabled,
      !preferences.bool(forKey: "chatGPTWelcome." + account.id)
    {
      welcomeAccountID = account.id
      chatGPTWelcome = pendingCloudReview == nil
    } else {
      welcomeAccountID = nil
      chatGPTWelcome = false
    }
    if let review = pendingCloudReview, review.sourceFingerprint != cloudSourceFingerprint() {
      pendingCloudReview = nil
    }
  }
  func dismissChatGPTWelcome() {
    if let id = welcomeAccountID, id == chatGPT.activeAccountID,
      chatGPT.activeAccount?.isSignedIn == true, chatGPT.activeAccount?.planEnabled == true
    {
      preferences.set(true, forKey: "chatGPTWelcome." + id)
    }
    welcomeAccountID = nil
    chatGPTWelcome = false
  }
  func retryHistoryAccess() {
    // Render-only fixtures cannot unlock or read the owner's real history.
    guard !isBusy, storageAvailable,
      !ProcessInfo.processInfo.arguments.contains("--qa-output")
    else { return }
    // Only this explicit unlock may show Keychain UI. Checkpoints remain noninteractive.
    let interactiveSecrets: any SecretStore =
      (historySecrets as? KeychainSecretStore)?.withUserInteraction(true) ?? historySecrets
    do {
      let root = models.root.deletingLastPathComponent().appendingPathComponent("History")
      _ = try ChatStore(root: root, secrets: interactiveSecrets).load()
      let automaticSecrets: any SecretStore =
        (historySecrets as? KeychainSecretStore)?.withUserInteraction(false) ?? historySecrets
      let history = try ChatStore(root: root, secrets: automaticSecrets)
      let saved = try history.load()
      historySecrets = automaticSecrets
      let needsRecoveryCopy =
        !temporarySession
        && (!messages.isEmpty || !draft.isEmpty
          || conversations.contains(where: { $0.id == currentID }))
      store = history
      conversations = saved
      historyAvailable = true
      historyNotice = nil
      if needsRecoveryCopy {
        currentID = UUID()
        recoveryCopy = true
        persist()
        if historyAvailable {
          status = "Recovered a separate copy. The original saved chat is unchanged."
        }
      }
    } catch { historyNotice = "History remains locked. \(error.localizedDescription)" }
  }
  func useTemporarySession() {
    guard !isBusy else { return }
    guard messages.isEmpty else {
      error =
        "Your current answer needs recovery before starting a temporary session. Unlock history first; your text is kept in memory."
      return
    }
    temporarySession = true
    error = nil
    composerFocusRequest = UUID()
  }
  func importTextFile() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.title = "Add text to this local chat"
    panel.message =
      "Choose one UTF-8 text or Markdown file, up to 6 KB. Its text appears in the draft for review."
    panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.begin { [weak self] response in
      guard response == .OK, let self, let file = panel.url else { return }
      let granted = file.startAccessingSecurityScopedResource()
      defer { if granted { file.stopAccessingSecurityScopedResource() } }
      do {
        let facts = try FileManager.default.attributesOfItem(atPath: file.path)
        guard facts[.type] as? FileAttributeType == .typeRegular,
          (facts[.size] as? NSNumber)?.intValue ?? Int.max <= 6_000
        else {
          throw LocalRuntimeError.message(
            "Choose a text file up to 6 KB. Larger files need the later document workflow.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 6_001) ?? Data()
        guard data.count <= 6_000 else {
          throw LocalRuntimeError.message("This file grew beyond 6 KB. Your draft is unchanged.")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
          throw LocalRuntimeError.message(
            "This file is not readable UTF-8 text. Your draft is unchanged.")
        }
        let candidate = self.draft + (self.draft.isEmpty ? "" : "\n\n") + text
        guard candidate.utf8.count <= 8_000 else {
          throw LocalRuntimeError.message(
            "This file cannot fit in the current draft as UTF-8 text. Your draft is unchanged.")
        }
        self.draft = candidate
        self.composerFocusRequest = UUID()
        self.error = nil
      } catch { self.error = error.localizedDescription }
    }
  }
  func download() {
    guard storageAvailable, !isBusy, !["downloading", "verifying"].contains(models.phase) else {
      return
    }
    let model = selectedModel
    guard model.fits(device) else {
      error =
        "This model is not supported by the current hardware estimate. Try the smaller model on an Apple Silicon Mac."
      return
    }
    error = nil
    Task { await models.install(model) }
  }
  func load() {
    guard !isBusy, let file = models.installedURL(for: selectedModel) else { return }
    let model = selectedModel
    let run = UUID()
    operationID = run
    completionPulse = nil
    isBusy = true
    status = "Loading \(model.name)…"
    error = nil
    operation = Task { [self] in
      do {
        try await runtime.load(model: model, file: file)
        guard operationID == run else { return }
        status = "\(model.name) · on this Mac"
      } catch {
        guard operationID == run else { return }
        self.error = error.localizedDescription
        status = "Model could not load"
      }
      guard operationID == run else { return }
      isBusy = false
      operation = nil
    }
  }
  func send() {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard storageAvailable, !isBusy, !prompt.isEmpty else { return }
    guard canUseChat else {
      error =
        "Unlock encrypted history or choose a temporary session before sending. Your draft is kept."
      return
    }
    guard prompt.utf8.count <= 8_000 else {
      error = "This message is too long for the first local model. Keep it under 8,000 bytes."
      return
    }
    if cloudMode {
      prepareCloudReview()
      return
    }
    guard let file = models.installedURL(for: selectedModel) else {
      error = "Download a model in Models first. Your message is kept here."
      return
    }
    let model = selectedModel
    let run = UUID()
    operationID = run
    completionPulse = nil
    isBusy = true
    error = nil
    let prior = messages.filter {
      !$0.content.isEmpty && ($0.role == "user" || $0.role == "assistant")
    }.map { RuntimeMessage(role: $0.role, content: $0.content) }
    let system = RuntimeMessage(
      role: "system",
      content:
        "You are Pip, the helpful local assistant in Pip Hybrid. Be warm, concise and honest. You have no internet, file access or tools. Never claim you read files or browsed. Help users understand and work with the text they give you."
    )
    let input = [system] + prior + [RuntimeMessage(role: "user", content: prompt)]
    guard input.reduce(0, { $0 + $1.content.utf8.count }) <= 12_000 else {
      isBusy = false
      error =
        "This conversation has reached the first model's context limit. Start a new chat; your message is kept."
      return
    }
    let beforeSend = messages
    messages.append(ChatMessage(role: "user", content: prompt))
    draft = ""
    let answer = ChatMessage(role: "assistant", content: "", state: "streaming")
    messages.append(answer)
    persist()
    guard temporarySession || historyAvailable else {
      messages = beforeSend
      draft = prompt
      isBusy = false
      status = "History locked"
      return
    }
    status = "Loading \(model.name)…"
    operation = Task { [self] in
      do {
        try await runtime.load(model: model, file: file)
        guard operationID == run else { return }
        status = "Writing locally…"
        try await runtime.generate(messages: input) { [weak self] text in
          guard let self, self.operationID == run,
            let index = self.messages.firstIndex(where: { $0.id == answer.id })
          else { return }
          self.messages[index].content += text
          if Date().timeIntervalSince(self.lastCheckpoint) > 2 {
            self.lastCheckpoint = Date()
            self.persist()
          }
        }
        guard operationID == run else { return }
        updateAnswer(answer.id, state: "complete")
        status = "Finished on this Mac"
        completionPulse = UUID()
      } catch {
        guard operationID == run else { return }
        updateAnswer(answer.id, state: error is CancellationError ? "stopped" : "failed")
        self.error = error is CancellationError ? nil : error.localizedDescription
        status = error is CancellationError ? "Stopped" : "The local answer was interrupted"
      }
      guard operationID == run else { return }
      isBusy = false
      operation = nil
      persist()
    }
  }
  func stop() {
    guard !stopping, isBusy || runtime.state == "busy" || runtime.state == "loading" else { return }
    if usingCloudGeneration {
      operationID = UUID()
      operation?.cancel()
      chatGPT.cancelGeneration()
      operation = nil
      for index in messages.indices where messages[index].state == "streaming" {
        messages[index].state = "stopped"
      }
      usingCloudGeneration = false
      isBusy = false
      status = "Stopped receiving. Partial answer kept; provider processing may have continued."
      persist()
      return
    }
    stopping = true
    operationID = UUID()
    operation?.cancel()
    operation = nil
    status = "Stopping…"
    isBusy = true
    Task {
      await runtime.stop()
      for index in messages.indices where messages[index].state == "streaming" {
        messages[index].state = runtime.lastStopConfirmed ? "stopped" : "interrupted"
      }
      status =
        runtime.lastStopConfirmed
        ? "Stopped. Your partial answer is kept."
        : "Stop not confirmed. Quit Pip Hybrid to terminate the engine."
      isBusy = false
      stopping = false
      persist()
    }
  }
  func unload() {
    guard !isBusy else { return }
    isBusy = true
    status = "Unloading model…"
    Task {
      await runtime.stop()
      status = runtime.lastStopConfirmed ? "Model unloaded" : "Stop not confirmed"
      isBusy = false
    }
  }
  func removeModel(_ descriptor: ModelDescriptor) {
    guard !isBusy, !["downloading", "verifying"].contains(models.phase) else { return }
    isBusy = true
    Task {
      if runtime.loadedModelID == descriptor.id { await runtime.stop() }
      do {
        guard runtime.loadedModelID != descriptor.id else {
          throw LocalRuntimeError.message(
            "The model is still in use. Quit and reopen Pip Hybrid before removing it.")
        }
        try models.remove(descriptor)
        status = "Model removed"
      } catch { self.error = error.localizedDescription }
      isBusy = false
      objectWillChange.send()
    }
  }
  func newChat() {
    guard !isBusy else { return }
    pendingCloudReview = nil
    let hadSavedConversation = conversations.contains(where: { $0.id == currentID })
    persist()
    guard
      temporarySession || historyAvailable
        || (!hadSavedConversation && messages.isEmpty && draft.isEmpty)
    else {
      return
    }
    currentID = UUID()
    recoveryCopy = false
    messages = []
    draft = ""
    error = nil
    resetContextStatus()
    if historyAvailable { temporarySession = false }
  }
  func openConversation(_ id: UUID) {
    guard !isBusy, id != currentID else { return }
    pendingCloudReview = nil
    persist()
    guard historyAvailable else { return }
    guard let chat = conversations.first(where: { $0.id == id }) else { return }
    currentID = id
    recoveryCopy = false
    temporarySession = false
    messages = chat.messages
    draft = chat.draft ?? ""
    error = nil
    resetContextStatus()
  }
  func deleteConversation(_ id: UUID) {
    guard !isBusy, historyAvailable else { return }
    let oldRecovery = recoveryCopy
    let before = conversations
    let oldID = currentID
    let oldMessages = messages
    let oldDraft = draft
    let oldStatus = status
    conversations.removeAll { $0.id == id }
    if currentID == id {
      currentID = UUID()
      recoveryCopy = false
      messages = []
      draft = ""
      resetContextStatus()
    }
    saveHistory()
    if !historyAvailable {
      conversations = before
      currentID = oldID
      messages = oldMessages
      draft = oldDraft
      recoveryCopy = oldRecovery
      status = oldStatus
      error = "The chat was not deleted. Unlock history and try again."
    }
  }
  private func resetContextStatus() {
    completionPulse = nil
    if runtime.state == "stop-unconfirmed" {
      status = "Stop not confirmed. Quit Pip Hybrid to terminate the engine."
    } else if !historyAvailable && !temporarySession && historyNotice != nil {
      status = "History locked"
    } else {
      status = "Ready when you are"
    }
  }
  func completeOnboarding() {
    guard installed else {
      error = "Download and verify a model to finish setup."
      return
    }
    onboardingComplete = true
    if !ProcessInfo.processInfo.arguments.contains("--qa-output") {
      preferences.set(true, forKey: "onboardingComplete")
    }
  }
  func shutdown() {
    operationID = UUID()
    operation?.cancel()
    models.pause()
    chatGPTManagementID = UUID()
    chatGPT.shutdown()
    runtime.terminateImmediately()
    persist()
    if let ownedCaptureRoot {
      try? FileManager.default.removeItem(at: ownedCaptureRoot)
      self.ownedCaptureRoot = nil
    }
  }
  private func cloudInput() -> [RuntimeMessage] {
    let system = RuntimeMessage(
      role: "system",
      content:
        "You are Pip, the helpful assistant in Pip Hybrid. Be warm, concise and honest. This is an explicitly reviewed cloud conversation. You have no browsing, file access or tools. Work only with the text provided; never claim access you do not have."
    )
    return [system]
      + messages.filter {
        !$0.content.isEmpty && ($0.role == "user" || $0.role == "assistant")
      }.map { RuntimeMessage(role: $0.role, content: $0.content) }
      + [
        RuntimeMessage(role: "user", content: draft.trimmingCharacters(in: .whitespacesAndNewlines))
      ]
  }
  private func cloudSourceFingerprint() -> String {
    let source =
      [
        currentID.uuidString, cloudMode.description, chatGPT.activeAccountID ?? "",
        chatGPT.activeAccount?.subject ?? "", selectedChatGPTModel, draft,
      ]
      + messages.map { "\($0.id)|\($0.role)|\($0.state)|\($0.content)" }
    let encoded = (try? JSONEncoder().encode(source)) ?? Data()
    return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
  }
  func prepareCloudReview(redacted: Bool = false) {
    guard cloudMode, !isBusy, canSend,
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let account = chatGPT.activeAccount,
      let model = chatGPT.models.first(where: { $0.slug == selectedChatGPTModel })
    else {
      error =
        "Connect an eligible ChatGPT account and choose one of its models. Your draft is kept."
      return
    }
    do {
      let input = cloudInput().map {
        RuntimeMessage(
          role: $0.role, content: redacted ? SensitiveInfo.redacted($0.content) : $0.content)
      }
      pendingCloudReview = try CloudReview(
        accountID: account.id, subject: account.subject,
        accountLabel: account.label, model: model.slug, modelName: model.displayName,
        messages: input, sourceFingerprint: cloudSourceFingerprint(), redacted: redacted)
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  func approveCloudReview(_ review: CloudReview) {
    guard !isBusy, cloudMode, canSend, pendingCloudReview?.id == review.id,
      review.sourceFingerprint == cloudSourceFingerprint(),
      chatGPT.activeAccountID == review.accountID,
      chatGPT.activeAccount?.subject == review.subject,
      selectedChatGPTModel == review.model,
      let rebuilt = try? ChatGPTResponseParser.requestBody(
        model: review.model, messages: review.messages),
      rebuilt == review.body
    else {
      pendingCloudReview = nil
      error = "The conversation or account changed. Review the outgoing conversation again."
      return
    }
    pendingCloudReview = nil  // single-use approval, consumed before any await
    let before = messages
    let originalDraft = draft
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    messages.append(
      ChatMessage(
        role: "user", content: prompt, route: "chatgpt",
        model: review.model, outboundDigest: review.digest, redactedForCloud: review.redacted))
    draft = ""
    let answer = ChatMessage(
      role: "assistant", content: "", state: "streaming", route: "chatgpt",
      model: review.model, outboundDigest: review.digest, redactedForCloud: review.redacted)
    messages.append(answer)
    persist()
    guard temporarySession || historyAvailable else {
      messages = before
      draft = originalDraft
      return
    }
    let run = UUID()
    operationID = run
    completionPulse = nil
    usingCloudGeneration = true
    isBusy = true
    status = "Waiting for ChatGPT…"
    operation = Task { [self] in
      do {
        // A previously queued account change can finish between approval and this task.
        // Rebind the immutable consent identity immediately before the core captures it.
        guard operationID == run, cloudMode, canSend,
          chatGPT.activeAccountID == review.accountID,
          chatGPT.activeAccount?.subject == review.subject,
          selectedChatGPTModel == review.model
        else {
          throw ChatGPTError.message(
            "The account changed before sending. Review the conversation again.")
        }
        try await chatGPT.generate(model: review.model, messages: review.messages) {
          [weak self] delta in
          guard let self, self.operationID == run,
            let index = self.messages.firstIndex(where: { $0.id == answer.id })
          else { return }
          self.messages[index].content += delta
          self.status = "Writing with ChatGPT…"
          if Date().timeIntervalSince(self.lastCheckpoint) > 2 {
            self.lastCheckpoint = Date()
            self.persist()
          }
        }
        guard operationID == run else { return }
        updateAnswer(answer.id, state: "complete")
        completionPulse = UUID()
        status = "Finished with ChatGPT"
      } catch {
        guard operationID == run else { return }
        updateAnswer(answer.id, state: error is CancellationError ? "stopped" : "failed")
        self.error = error is CancellationError ? nil : error.localizedDescription
        status = "The cloud answer was interrupted. Partial text kept."
      }
      guard operationID == run else { return }
      usingCloudGeneration = false
      isBusy = false
      operation = nil
      persist()
    }
  }
  private func updateAnswer(_ id: UUID, state: String) {
    if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].state = state }
  }
  private func persist() {
    guard
      !messages.isEmpty || !draft.isEmpty || recoveryCopy
        || conversations.contains(where: { $0.id == currentID }),
      storageAvailable, historyAvailable,
      !temporarySession,
      !ProcessInfo.processInfo.arguments.contains("--qa-output")
    else { return }
    var chat = SavedConversation(
      id: currentID, messages: messages, draft: draft.isEmpty ? nil : draft)
    if recoveryCopy { chat.title = "Recovered · " + chat.title }
    conversations.removeAll { $0.id == currentID }
    conversations.insert(chat, at: 0)
    saveHistory()
  }
  private func saveHistory() {
    guard historyAvailable, let store else { return }
    do { try store.save(conversations) } catch {
      historyAvailable = false
      historyNotice =
        "Your chat could not be saved to encrypted history. Existing files are preserved. \(error.localizedDescription)"
      self.error =
        "History needs attention. Your current text is kept in memory; retry unlocking before leaving this chat."
    }
  }
}

/// QA rendering uses ephemeral credentials and never touches the user's Keychain.
final class PreviewSecretStore: SecretStore {
  private var values: [String: Data] = [:]
  func read(_ key: String) throws -> Data? { values[key] }
  func write(_ data: Data, for key: String) throws { values[key] = data }
  func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
