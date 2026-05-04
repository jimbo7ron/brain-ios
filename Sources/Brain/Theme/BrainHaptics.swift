// BrainHaptics.swift
// brain-ios
//
// M43 — single entry point for tactile feedback. Wraps
// `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` so
// call sites don't sprinkle `prepare()` + `impactOccurred()` boilerplate
// across the codebase, and so a future tweak (different intensities,
// platform check) is a one-file change.
//
// Each method instantiates a fresh generator and calls `prepare()`
// immediately before firing. `prepare()` warms the haptic engine so
// the perceived latency drops from ~50 ms to <10 ms — at the call
// sites where it matters (toggle complete, save success), the user
// would otherwise feel the haptic as a noticeable beat after the
// visual confirmation. We don't cache the generator across calls
// because the system reclaims the haptic engine after a short idle,
// and a stale generator can fail to fire on the second invocation.
//
// All entry points are `@MainActor`. UIKit's haptic generators are
// main-actor-isolated under strict concurrency, and every call site
// (button tap handler, async task on the main actor) is already
// there.
//
// Platform note: wrapped in `#if canImport(UIKit)` because SwiftUI
// previews on macOS hosts and any future Mac Catalyst path don't have
// `UIFeedbackGenerator`. The Mac haptic engine lives behind a
// completely separate API (`NSHapticFeedbackManager`); shimming it
// would be cosmetic since iOS is the only ship target today. Calls
// from non-UIKit hosts compile to no-ops.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Tactile-feedback helpers, mirroring the iOS HIG's three intensity
/// tiers plus the notification-style `.error` pattern. Use:
///
///   * `light()` — confirmations, dismiss, subtle "thing happened"
///     signals (pull-to-refresh complete, quick-add submit).
///   * `medium()` — committed mutations the user actively chose
///     (save in an edit dialog).
///   * `error()` — failed save / unrecoverable mistake. Uses the
///     three-pulse system error pattern, not a heavy impact, so the
///     user can distinguish it from a successful save by feel alone.
enum BrainHaptics {

    /// Light tap. Used at:
    ///   * `TodoRow.toggle()` — successful complete (M36).
    ///   * `QuickAddView.submit()` — dismiss after a successful create
    ///     (M39).
    ///   * `TodayView.refreshable` — sync completes (M34).
    @MainActor
    static func light() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// Medium tap. Used at edit-dialog Save (M40) so the user feels a
    /// stronger confirmation when they've committed a multi-field
    /// change vs. a single tap.
    @MainActor
    static func medium() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// Error pattern (three pulses). Reserved for failed save /
    /// rolled-back mutation. Distinct enough by feel that users learn
    /// "that didn't work" without needing to read the error banner.
    @MainActor
    static func error() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
        #endif
    }
}
