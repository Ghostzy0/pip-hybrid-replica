// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Pip Hybrid contributors
//
// Original Pip Hybrid silhouette, drawn for this project from a blank path.
// These hand-authored cubic curves do not depend on an external mascot library.
// The companion artwork is docs/assets/pip-hybrid.svg.

import SwiftUI

/// A gently leaning, asymmetrical pebble. Color and facial features belong to
/// the caller, allowing the same silhouette to follow the app's theme.
struct PipPebble: Shape {
  func path(in rect: CGRect) -> Path {
    let side = min(rect.width, rect.height)
    guard side > 0 else { return Path() }
    let scale = side / 100

    // Fit a square canvas without stretching the character in a wide frame.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(
        x: rect.midX + (x - 50) * scale,
        y: rect.midY + (y - 50) * scale
      )
    }

    var outline = Path()
    outline.move(to: point(52, 9))
    outline.addCurve(
      to: point(88, 33),
      control1: point(66, 8),
      control2: point(82, 18)
    )
    outline.addCurve(
      to: point(85, 76),
      control1: point(94, 48),
      control2: point(93, 63)
    )
    outline.addCurve(
      to: point(46, 92),
      control1: point(77, 89),
      control2: point(62, 94)
    )
    outline.addCurve(
      to: point(11, 69),
      control1: point(30, 90),
      control2: point(17, 83)
    )
    outline.addCurve(
      to: point(17, 26),
      control1: point(5, 55),
      control2: point(8, 39)
    )
    outline.addCurve(
      to: point(52, 9),
      control1: point(26, 13),
      control2: point(38, 10)
    )
    outline.closeSubpath()
    return outline
  }
}
