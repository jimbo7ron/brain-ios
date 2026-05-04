// SearchChecks.swift
// brain-ios
//
// M43 — debug-only sanity checks for the in-app search surface.
// brain-ios has no test runner yet, so regressions surface via
// `precondition` crashes invoked from a future debug hook. Same
// pattern as `ServerDateChecks` / `IntentChecks` /
// `EditDialogChecks` etc. already in the codebase.
//
// We check the JSON decode path (`searchNotes` returns
// `NoteListResponse`) using a hand-rolled fixture — the same shape
// the brain server emits. This catches the obvious regressions:
// CodingKeys drift, missing fields, type mismatches.

#if DEBUG

import Foundation

enum SearchChecks {

    /// Decode a fixture matching `GET /api/v1/notes?q=` and assert
    /// the typed shape lands cleanly. The fixture mirrors what
    /// `_note_to_response` emits server-side (see
    /// `brain/src/brain/server.py`).
    static func assertSearchResponseDecodes() {
        let fixture = #"""
        {
          "notes": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "short_id": "abc1",
              "title": "Pay tax",
              "content": "Pay tax",
              "type": "todo",
              "tags": ["finance"],
              "created_at": "2026-04-01T10:00:00",
              "updated_at": "2026-04-01T10:00:00",
              "archived": false,
              "todo": {
                "due_date": "2026-05-03",
                "due_time": null,
                "completed": false,
                "completed_at": null,
                "priority": "high",
                "recurrence": null,
                "project_id": null,
                "section": "now",
                "url": null,
                "url_title": null,
                "url_state": null,
                "url_fetched_at": null,
                "sort_order": 0
              },
              "appointment": null
            }
          ],
          "total": 1
        }
        """#
        let decoder = JSONDecoder()
        do {
            guard let data = fixture.data(using: .utf8) else {
                preconditionFailure("fixture should be UTF-8 encodable")
            }
            let response = try decoder.decode(NoteListResponse.self, from: data)
            precondition(response.total == 1, "expected total=1, got \(response.total)")
            precondition(response.notes.count == 1,
                         "expected 1 note, got \(response.notes.count)")
            let note = response.notes[0]
            precondition(note.title == "Pay tax",
                         "title round-trip failed: \(note.title ?? "nil")")
            precondition(note.todo?.dueDate == "2026-05-03",
                         "todo.due_date round-trip failed")
            precondition(note.todo?.priority == "high",
                         "todo.priority round-trip failed")
            precondition(note.tags == ["finance"],
                         "tags round-trip failed")
        } catch {
            preconditionFailure("search response decode failed: \(error)")
        }
    }

    /// Smoke-check the `BrainColors` palette is non-empty and that
    /// the violet accent is at the expected slug. M43's dark-mode
    /// pass relies on the palette resolving the same `cssValue` ->
    /// `Color` mapping it always has, so a regression there would
    /// silently break project-tinted rows.
    static func assertPaletteShape() {
        precondition(!BrainColors.palette.isEmpty,
                     "BrainColors.palette must not be empty")
        precondition(BrainColors.palette.contains(where: { $0.id == "violet" }),
                     "BrainColors.palette should contain violet")
        precondition(BrainColors.violet.cssValue == "hsl(262 83% 58%)",
                     "violet cssValue drifted: \(BrainColors.violet.cssValue)")
    }

    static func runChecks() {
        assertSearchResponseDecodes()
        assertPaletteShape()
    }
}

#endif
