// EditDialogChecks.swift
// brain-ios
//
// Debug-only sanity checks for the M40 edit dialogs. brain-ios has no
// test runner today (M37 spec); these run via a future debug menu, a
// `#Preview`-driven smoke step, or a CI hook that calls
// `BrainDebugEditDialogChecks.runAll()`.
//
// Why a separate file instead of an `#if DEBUG` block at the bottom of
// `EditTodoView.swift`: the debug code roughly doubles the line count
// of the host file, which trips swiftlint's `file_length` warning and
// makes the production code harder to read top-to-bottom. Splitting
// the checks here keeps the view file focused on the user-facing
// behaviour and gives the audit shim a stable home.

import Foundation

#if DEBUG

/// Source-level checks for the encode/decode round-trip on the M40
/// edit payloads, plus the title/notes split contract on
/// `EditTodoView`. Runs in debug builds only; production binaries
/// strip the entire enum.
enum BrainDebugEditDialogChecks {

    /// Encode → decode round-trip on `UpdateNotePayload`. Catches the
    /// case where an `enum CodingKeys` rename silently breaks the
    /// wire shape against the server's `NoteUpdate`.
    static func assertNotePayloadRoundTrip() {
        var payload = UpdateNotePayload()
        payload.content = "Ship migration\n\nCheck staging logs"
        payload.title = "Ship migration"
        payload.dueDate = "2026-05-12"
        payload.priority = "high"
        payload.project = "inbox"
        payload.section = "now"
        payload.url = "https://example.com"

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        do {
            let data = try encoder.encode(payload)
            // Round-trip via a Decodable mirror so we test the wire
            // shape, not the in-memory struct identity.
            struct Mirror: Decodable {
                let content: String?
                let title: String?
                let dueDate: String?
                let priority: String?
                let project: String?
                let section: String?
                let url: String?
                let startTime: String?
                let endTime: String?
                let location: String?
                enum CodingKeys: String, CodingKey {
                    case content, title
                    case dueDate = "due_date"
                    case priority, project, section, url
                    case startTime = "start_time"
                    case endTime = "end_time"
                    case location
                }
            }
            let mirror = try decoder.decode(Mirror.self, from: data)
            assert(mirror.content == payload.content, "content drift")
            assert(mirror.title == payload.title, "title drift")
            assert(mirror.dueDate == payload.dueDate, "due_date drift")
            assert(mirror.priority == payload.priority, "priority drift")
            assert(mirror.project == payload.project, "project drift")
            assert(mirror.section == payload.section, "section drift")
            assert(mirror.url == payload.url, "url drift")
        } catch {
            assertionFailure("UpdateNotePayload round-trip failed: \(error)")
        }
    }

    /// Encode → decode round-trip on `UpdateProjectPayload`.
    static func assertProjectPayloadRoundTrip() {
        var payload = UpdateProjectPayload()
        payload.name = "Apex"
        payload.color = "hsl(262 83% 58%)"
        payload.sortOrder = 3
        payload.archived = false

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        do {
            let data = try encoder.encode(payload)
            struct Mirror: Decodable {
                let name: String?
                let color: String?
                let sortOrder: Int?
                let archived: Bool?
                enum CodingKeys: String, CodingKey {
                    case name, color
                    case sortOrder = "sort_order"
                    case archived
                }
            }
            let mirror = try decoder.decode(Mirror.self, from: data)
            assert(mirror.name == payload.name, "name drift")
            assert(mirror.color == payload.color, "color drift")
            assert(mirror.sortOrder == payload.sortOrder, "sort_order drift")
            assert(mirror.archived == payload.archived, "archived drift")
        } catch {
            assertionFailure("UpdateProjectPayload round-trip failed: \(error)")
        }
    }

    /// Title/notes split + join is a round-trip identity for the
    /// canonical "title\n\nnotes" shape. Catches the off-by-one
    /// trimming bugs we'd otherwise discover only by editing twice.
    @MainActor
    static func assertSplitJoinRoundTrip() {
        let original = "Ship migration\n\nCheck staging logs\nThen ping team."
        let parts = TodoContentText.split(original, fallbackTitle: nil)
        assert(parts.title == "Ship migration", "title parse drift: \(parts.title)")
        assert(parts.notes == "Check staging logs\nThen ping team.", "notes parse drift: \(parts.notes)")
        let rejoined = TodoContentText.join(title: parts.title, notes: parts.notes)
        assert(rejoined == original, "split→join drift: \(rejoined)")
    }

    /// Title-only content (no notes section) round-trips without
    /// gaining a trailing newline.
    @MainActor
    static func assertTitleOnlyRoundTrip() {
        let original = "Ship migration"
        let parts = TodoContentText.split(original, fallbackTitle: nil)
        assert(parts.title == "Ship migration")
        assert(parts.notes == "")
        let rejoined = TodoContentText.join(title: parts.title, notes: parts.notes)
        assert(rejoined == original, "title-only round-trip drift: \(rejoined)")
    }

    /// Section spec mutation: add → rename → delete (local-state
    /// only). Mirrors the optimistic flow in `EditProjectView` so we
    /// can catch shape regressions without a live server.
    static func assertSectionSpecMutations() {
        var sections: [SectionMutationSpec] = [
            SectionMutationSpec(slug: "now", name: "Now", position: 0),
            SectionMutationSpec(slug: "next", name: "Next", position: 1),
        ]
        // Add
        sections.append(SectionMutationSpec(
            slug: "backlog",
            name: "Backlog",
            position: sections.count
        ))
        assert(sections.count == 3)
        assert(sections.last?.slug == "backlog")
        // Rename
        if let idx = sections.firstIndex(where: { $0.slug == "next" }) {
            sections[idx] = SectionMutationSpec(
                slug: "next",
                name: "Up next",
                position: sections[idx].position
            )
        }
        assert(sections.first(where: { $0.slug == "next" })?.name == "Up next")
        // Delete
        sections.removeAll { $0.slug == "backlog" }
        assert(sections.count == 2)
        assert(!sections.contains(where: { $0.slug == "backlog" }))
    }

    @MainActor
    static func runAll() {
        assertNotePayloadRoundTrip()
        assertProjectPayloadRoundTrip()
        assertSplitJoinRoundTrip()
        assertTitleOnlyRoundTrip()
        assertSectionSpecMutations()
    }
}

#endif
