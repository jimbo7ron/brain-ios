// BrainSymbols.swift
// brain-ios
//
// SF Symbol constants, mirrored from the Lucide icons used in the web UI.
// Centralising them means a future icon swap is a one-line change rather
// than a grep across every view.

import Foundation

enum BrainSymbols {

    // MARK: - Section icons (Today view, M34)

    /// Lucide `Zap` — "Now" section.
    static let now = "bolt.fill"

    /// Lucide `ArrowRight` — "Next" section.
    static let next = "arrow.right"

    /// Lucide `Clock` — "Later" section.
    static let later = "clock"

    /// Lucide `AlertCircle` — Overdue badge.
    static let overdue = "exclamationmark.circle.fill"

    /// Lucide `CalendarClock` — Due Today.
    static let dueToday = "calendar"

    /// Lucide `CalendarRange` — "Coming up" section. Distinct from
    /// `dueToday` so the two adjacent sections read as visually
    /// different at a glance.
    static let comingUp = "calendar.badge.clock"

    /// Lucide `MapPin` — Appointments.
    static let location = "mappin.and.ellipse"

    /// Lucide `Inbox` — the "Inbox" virtual project (todos with
    /// no `project_id`). Mirrors the inbox/tray metaphor the web uses
    /// for the same surface in the sidebar.
    static let inbox = "tray"

    // MARK: - App chrome

    /// Brain glyph used as the app icon and splash mark. `brain.head.profile`
    /// has been available since iOS 16; `brain` is the simpler alternative.
    static let appGlyph = "brain.head.profile"

    static let settings = "gearshape"
    static let signOut = "rectangle.portrait.and.arrow.right"
    static let signIn = "arrow.right.square"

    // MARK: - Common actions

    static let add = "plus"
    static let archive = "archivebox"
    static let edit = "pencil"
    static let chevronRight = "chevron.right"
    static let circle = "circle"
    static let checkmarkCircle = "checkmark.circle.fill"
}
