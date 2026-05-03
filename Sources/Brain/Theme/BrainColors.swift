// BrainColors.swift
// brain-ios
//
// Project accent palette. Mirrored from web/src/lib/project-colors.ts in
// the brain repo so the iOS app and web app stay in visual sync. Each
// CSS HSL value (`hsl(H S% L%)`) is converted to SwiftUI's HSB form via
// the helper at the bottom of this file.
//
// Keep the slug list in lock-step with the web palette — the slug is
// the stable id used when wiring colour pickers in M40.

import SwiftUI

/// A named project accent color.
struct BrainColor: Identifiable, Hashable {
    let id: String        // slug, e.g. "violet"
    let name: String      // display name, e.g. "Violet"
    let color: Color
    /// Original CSS string the server stores in `Project.color`. We keep
    /// it so colour-picker → server roundtrips don't drift.
    let cssValue: String
}

enum BrainColors {

    static let violet  = makeColor(slug: "violet",  name: "Violet",  h: 262, s: 83, l: 58)
    static let indigo  = makeColor(slug: "indigo",  name: "Indigo",  h: 232, s: 80, l: 60)
    static let sky     = makeColor(slug: "sky",     name: "Sky",     h: 200, s: 90, l: 55)
    static let teal    = makeColor(slug: "teal",    name: "Teal",    h: 180, s: 60, l: 45)
    static let emerald = makeColor(slug: "emerald", name: "Emerald", h: 160, s: 64, l: 45)
    static let lime    = makeColor(slug: "lime",    name: "Lime",    h:  85, s: 65, l: 50)
    static let amber   = makeColor(slug: "amber",   name: "Amber",   h:  35, s: 92, l: 55)
    static let rose    = makeColor(slug: "rose",    name: "Rose",    h: 350, s: 80, l: 60)
    static let pink    = makeColor(slug: "pink",    name: "Pink",    h: 330, s: 75, l: 60)
    static let slate   = makeColor(slug: "slate",   name: "Slate",   h: 220, s: 15, l: 55)

    /// Ordered palette — same order as the web colour picker.
    static let palette: [BrainColor] = [
        violet, indigo, sky, teal, emerald, lime, amber, rose, pink, slate,
    ]

    static let `default`: BrainColor = violet

    /// Look up a swatch by slug. Returns `nil` for unknown values so callers
    /// can fall back to whatever the server stored verbatim.
    static func bySlug(_ slug: String) -> BrainColor? {
        palette.first { $0.id == slug }
    }
}

// MARK: - HSL → HSB

/// Build a `BrainColor` from CSS HSL values. SwiftUI's `Color` initialiser
/// takes HSB, so we convert; the conversion is pure math from the standard
/// HSL ↔ HSV formula.
private func makeColor(slug: String, name: String, h: Double, s: Double, l: Double) -> BrainColor {
    let hsb = hslToHsb(h: h, s: s / 100.0, l: l / 100.0)
    let color = Color(
        hue: h / 360.0,
        saturation: hsb.saturation,
        brightness: hsb.brightness
    )
    let cssValue = "hsl(\(Int(h)) \(Int(s))% \(Int(l))%)"
    return BrainColor(id: slug, name: name, color: color, cssValue: cssValue)
}

private func hslToHsb(h: Double, s: Double, l: Double) -> (saturation: Double, brightness: Double) {
    // Standard formula: V = L + S * min(L, 1 - L); S_v = (V - L) / min(V, 1 - V).
    let value = l + s * min(l, 1 - l)
    let saturation = value == 0 ? 0 : 2 * (1 - l / value)
    return (saturation: saturation, brightness: value)
}
