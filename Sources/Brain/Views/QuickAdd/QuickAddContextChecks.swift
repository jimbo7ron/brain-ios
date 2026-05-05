// QuickAddContextChecks.swift
// brain-ios
//
// Debug-only sanity checks for the per-section add-todo plumbing
// added when ProjectDetailView grew a "+ Add to <Section>" row.
// brain-ios still has no test runner; these run via the same
// `runAll()` hook pattern as `EditDialogChecks` — wired into a
// future debug menu or a CI smoke step.
//
// The contract under test is small but load-bearing: existing
// callsites that say `QuickAddView()` keep their previous behaviour
// (no project, no section, no caption), and new callsites that pass
// a project id + section slug get those values threaded onto the
// wire payload + a human-readable caption above the input.

import Foundation

#if DEBUG

/// Source-level checks for `QuickAddView`'s optional context init.
/// Runs in debug builds only; production binaries strip the entire
/// enum.
@MainActor
enum BrainDebugQuickAddContextChecks {

    /// Default init must leave every context field nil so the Today
    /// FAB callsite (which still says `QuickAddView()`) keeps its
    /// previous behaviour: no project, no section, no caption, an
    /// inbox-style capture.
    static func assertDefaultInitHasNoContext() {
        let view = QuickAddView()
        assert(view.prefilledProjectID == nil, "default init should not pin a project")
        assert(view.prefilledSectionSlug == nil, "default init should not pin a section")
        assert(view.prefilledProjectName == nil, "default init should not pin a project name")
        assert(view.contextCaption == nil, "default init should not render a caption")
    }

    /// Init with a project id alone (no section): the context is
    /// remembered, but the caption only renders when there's a
    /// human-readable name to show. Without a name, fall back to nil
    /// so we never leak a UUID into the UI.
    static func assertProjectIDOnlyInit() {
        let view = QuickAddView(projectID: "11111111-1111-1111-1111-111111111111")
        assert(view.prefilledProjectID == "11111111-1111-1111-1111-111111111111")
        assert(view.prefilledSectionSlug == nil)
        assert(view.contextCaption == nil, "no project name → no caption")
    }

    /// Init with project id + name: caption reads "Adding to <Name>"
    /// without a section suffix.
    static func assertProjectNameCaption() {
        let view = QuickAddView(
            projectID: "abc",
            sectionSlug: nil,
            projectName: "Apex"
        )
        assert(view.contextCaption == "Adding to Apex", "caption mismatch: \(String(describing: view.contextCaption))")
    }

    /// Init with project + section + name: caption reads
    /// "Adding to <Name> · <slug>". Slug is the wire field, not the
    /// display name — that's intentional, the user picked the section
    /// header to land on so showing them the slug confirms which one.
    static func assertSectionCaption() {
        let view = QuickAddView(
            projectID: "abc",
            sectionSlug: "now",
            projectName: "Apex"
        )
        assert(view.prefilledProjectID == "abc")
        assert(view.prefilledSectionSlug == "now")
        assert(view.contextCaption == "Adding to Apex · now", "caption mismatch: \(String(describing: view.contextCaption))")
    }

    /// CreateNotePayload is the wire shape; verify that its `project`
    /// + `section` fields encode under the snake-case keys the server
    /// expects. Catches the case where a CodingKeys rename silently
    /// breaks the per-section capture.
    static func assertPayloadEncodesProjectAndSection() {
        let payload = CreateNotePayload(
            content: "Buy milk",
            title: nil,
            type: "todo",
            dueDate: nil,
            dueTime: nil,
            priority: nil,
            recurrence: nil,
            project: "abc",
            section: "now",
            url: nil,
            startTime: nil,
            endTime: nil,
            location: nil
        )
        do {
            let data = try JSONEncoder().encode(payload)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            assert(json["project"] as? String == "abc", "project missing or renamed on the wire")
            assert(json["section"] as? String == "now", "section missing or renamed on the wire")
        } catch {
            assertionFailure("CreateNotePayload encode failed: \(error)")
        }
    }

    static func runAll() {
        assertDefaultInitHasNoContext()
        assertProjectIDOnlyInit()
        assertProjectNameCaption()
        assertSectionCaption()
        assertPayloadEncodesProjectAndSection()
    }
}

#endif
