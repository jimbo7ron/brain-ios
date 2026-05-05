// NewProjectChecks.swift
// brain-ios
//
// Debug-only sanity checks for `CreateProjectPayload`'s wire shape.
// brain-ios has no test runner today; these run via the same future
// debug menu / CI hook that calls
// `BrainDebugEditDialogChecks.runAll()` (see `EditDialogChecks.swift`
// for the convention).
//
// Why a separate file rather than appending to `EditDialogChecks.swift`:
// the create-project payload lives in the Projects view module
// alongside the view that mints it, and keeping its checks adjacent
// makes the test↔code wiring easy to grep. The checks here are
// independent of the M40 edit-dialog checks and don't need to share
// state with them.

import Foundation

#if DEBUG

/// Source-level checks for the encode/decode round-trip on
/// `CreateProjectPayload`. Catches the case where an `enum CodingKeys`
/// rename (e.g. someone "fixes" `sortOrder` → `sort_order` to match
/// Swift convention and breaks the wire shape) silently breaks parity
/// against the server's `ProjectCreate` schema.
enum BrainDebugNewProjectChecks {

    /// Encode → decode round-trip on `CreateProjectPayload`. The
    /// `Mirror` struct decodes against the *snake_cased* wire shape so
    /// any drift between Swift property name and JSON key is caught
    /// here rather than at runtime against the server.
    static func assertCreateProjectPayloadRoundTrip() {
        let payload = CreateProjectPayload(
            name: "Apex",
            color: "hsl(262 83% 58%)",
            sortOrder: 5
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        do {
            let data = try encoder.encode(payload)
            struct Mirror: Decodable {
                let name: String
                let color: String?
                let sortOrder: Int?
                enum CodingKeys: String, CodingKey {
                    case name, color
                    case sortOrder = "sort_order"
                }
            }
            let mirror = try decoder.decode(Mirror.self, from: data)
            assert(mirror.name == payload.name, "name drift")
            assert(mirror.color == payload.color, "color drift")
            assert(mirror.sortOrder == payload.sortOrder, "sort_order drift")
        } catch {
            assertionFailure("CreateProjectPayload round-trip failed: \(error)")
        }
    }

    /// Round-trip with the optional fields omitted — exercises the
    /// nil-skipping behaviour of `Encodable` on Optional properties.
    /// The server's `ProjectCreate` treats absent keys as "use the
    /// default", so the wire shape for a name-only create is just
    /// `{"name": "..."}`. Catches any future change that accidentally
    /// emits `null` for missing optionals.
    static func assertCreateProjectPayloadNameOnly() {
        let payload = CreateProjectPayload(
            name: "Solo",
            color: nil,
            sortOrder: nil
        )

        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(payload)
            // Decode loosely as a generic JSON dictionary so we can
            // assert on key presence (not just values).
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                assertionFailure("CreateProjectPayload didn't encode as a JSON object")
                return
            }
            assert(json["name"] as? String == "Solo", "name missing or wrong")
            assert(json["color"] == nil, "color should be omitted when nil")
            assert(json["sort_order"] == nil, "sort_order should be omitted when nil")
        } catch {
            assertionFailure("CreateProjectPayload name-only round-trip failed: \(error)")
        }
    }

    static func runAll() {
        assertCreateProjectPayloadRoundTrip()
        assertCreateProjectPayloadNameOnly()
    }
}

#endif
