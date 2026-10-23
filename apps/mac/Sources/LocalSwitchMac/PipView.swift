import LocalSwitchCore
import SwiftUI

private struct PipMotionQAReduceMotionKey: EnvironmentKey {
  static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
  /// Synthetic recorder input only; production reads the actual macOS accessibility preference.
  var pipMotionQAReduceMotion: Bool? {
    get { self[PipMotionQAReduceMotionKey.self] }
    set { self[PipMotionQAReduceMotionKey.self] = newValue }
  }
}

#if BASELINE_EDITION
  /// The baseline keeps a semantic system icon and contains no mascot gestures.
  struct PipView: View {
    var size: CGFloat = 74
    var working = false
    var greeting = false
    var completionID: UUID? = nil
    var isLocked = false
    var live = true

    var body: some View {
      Image(systemName: isLocked ? "lock.shield" : (working ? "cpu" : "desktopcomputer"))
        .font(.system(size: size * 0.55, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
#else
  /// Original MIT pebble geometry with native finite gesture adaptation. Finite recognition and completion gestures never gate work.
  struct PipView: View {
    var size: CGFloat
    var working: Bool
    var greeting: Bool
    var completionID: UUID?
    var isLocked: Bool
    var live: Bool
    @AppStorage("pipMotionPaused", store: PipAppIdentity.preferences)
    private var paused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.pipMotionQAReduceMotion) private var qaReduced
    @State private var hovered = false
    @State private var blink = false
    @State private var nod: CGFloat = 0
    @State private var greeted = false
    @State private var lastCompletion: UUID?
    @State private var animationEpoch = UUID()

    init(
      size: CGFloat = 74, working: Bool = false, greeting: Bool = false, completionID: UUID? = nil,
      isLocked: Bool = false, live: Bool = true
    ) {
      self.size = size
      self.working = working
      self.greeting = greeting
      self.completionID = completionID
      self.isLocked = isLocked
      self.live = live
      // Existing completion IDs do not replay a celebration when a history row or screen mounts.
      _lastCompletion = State(initialValue: completionID)
    }
    private struct MotionKey: Hashable {
      let reduced: Bool
      let working: Bool
      let greeting: Bool
      let locked: Bool
      let completion: UUID?
    }
    private var reduced: Bool { !live || (qaReduced ?? (paused || systemReduced)) }
    private var recognizesPointer: Bool { hovered && !reduced && !working && !isLocked }
    private var eyeHeight: CGFloat {
      if !reduced && !working && !isLocked && blink { return size * 0.025 }
      return size * (working || isLocked ? 0.07 : 0.13)
    }
    var body: some View {
      let p = SwitchPalette(scheme)
      ZStack {
        PipPebble().fill(p.ink)
        HStack(spacing: size * 0.12) {
          Capsule().fill(p.canvas).frame(width: size * 0.06, height: eyeHeight)
          Capsule().fill(p.canvas).frame(width: size * 0.06, height: eyeHeight)
        }
        .offset(x: size * 0.04 + (recognizesPointer ? size * 0.035 : 0), y: -size * 0.025)
        if isLocked {
          Image(systemName: "lock.fill").font(.system(size: max(8, size * 0.14), weight: .semibold))
            .foregroundStyle(p.accentInk)
            .padding(max(2, size * 0.05)).background(p.accent, in: Circle())
            .offset(x: size * 0.36, y: size * 0.28)
        }
      }
      // Discard in-flight decorative presentation when motion is disabled or protection locks.
      // The outer state/task identity survives; an existing completion UUID cannot replay.
      .id(reduced || isLocked)
      .frame(width: size, height: size)
      .rotationEffect(.degrees(recognizesPointer ? -10 : -6))
      .offset(y: reduced || working || isLocked ? 0 : nod)
      .animation(
        reduced || working || isLocked ? nil : .spring(response: 0.30, dampingFraction: 0.82),
        value: recognizesPointer
      )
      .onHover { hovered = $0 }
      .task(
        id: MotionKey(
          reduced: reduced, working: working, greeting: greeting, locked: isLocked,
          completion: completionID)
      ) { await performFiniteGesture() }
      .onChange(of: reduced) { _, _ in resetGesture() }
      .onDisappear {
        animationEpoch = UUID()
        resetGesture()
      }
      .accessibilityHidden(true)
    }
    @MainActor private func performFiniteGesture() async {
      let epoch = UUID()
      animationEpoch = epoch
      resetGesture()
      defer { if animationEpoch == epoch { resetGesture() } }
      guard !reduced, !isLocked else {
        if let completionID { lastCompletion = completionID }
        return
      }
      // An actual terminal pulse can arrive just before the working flag settles; defer its nod.
      guard !working else { return }
      do {
        if let completionID, completionID != lastCompletion {
          lastCompletion = completionID
          withAnimation(.easeOut(duration: 0.14)) {
            nod = size * 0.045
            blink = true
          }
          try await Task.sleep(nanoseconds: 150_000_000)
          guard animationEpoch == epoch, !Task.isCancelled, !reduced else { return }
          withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            nod = 0
            blink = false
          }
          try await Task.sleep(nanoseconds: 260_000_000)
        } else if greeting && !greeted {
          greeted = true
          try await Task.sleep(nanoseconds: 180_000_000)
          guard animationEpoch == epoch, !Task.isCancelled, !reduced else { return }
          withAnimation(.easeOut(duration: 0.08)) { blink = true }
          try await Task.sleep(nanoseconds: 100_000_000)
          guard animationEpoch == epoch, !Task.isCancelled, !reduced else { return }
          withAnimation(.easeOut(duration: 0.14)) { blink = false }
          try await Task.sleep(nanoseconds: 150_000_000)
        }
      } catch { /* Cancellation leaves a neutral, usable pose; there is no retry or idle timer. */
      }
    }
    private func resetGesture() {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        blink = false
        nod = 0
      }
    }
  }

#endif

struct PipAppIcon: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 112).fill(SwitchPalette(.light).canvas)
      PipView(size: 440, live: false)
    }.padding(12)
  }
}
