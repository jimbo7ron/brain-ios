// CoreCRUDTests.swift
// brain-ios — BrainUITests
//
// Tier 2 e2e harness: minimum-viable happy-path coverage for the core
// CRUD flows on the Today + Projects surfaces. Tests drive the
// running app via `XCUIApplication`, with `-uiTesting` injected so the
// `FakeBrainURLProtocol` answers every API call from the in-process
// `FakeBrainState`. Each test launches a fresh process — XCUITest's
// default — and `BrainApp.init` calls `FakeBrainState.shared.reset()`
// before applying any `-uiTestingSeed*` flags, so fixtures don't leak
// between tests.
//
// What's covered (this PR):
//   * Quick-add → todo lands on Today.
//   * Edit todo → updated title visible.
//   * Swipe-archive → row leaves the list.
//   * Toggle complete → row re-renders in the completed visual state.
//   * Create project → appears in Projects list.
//   * Add section to project → appears in EditProjectView.
//
// Out of scope (future PRs):
//   * Failure-path coverage (network errors, mutation queue poisoning,
//     status pill, per-row indicators).
//   * Cross-device sync flows.
//   * Search, filters, dark mode, accessibility audits.
//   * CI integration.
//   * Real-server e2e (Tier 3).

import XCTest

final class CoreCRUDTests: XCTestCase {

    override func setUpWithError() throws {
        // Continue running other tests after the first assertion failure
        // — the tests are independent and one regression shouldn't mask
        // the rest. Mirrors the convention in `Tests/BrainTests`.
        continueAfterFailure = false
    }

    /// Test 1 — Quick-add a todo, assert it appears on Today.
    ///
    /// Types `"buy milk today"` so the QuickAddParser extracts a due
    /// date matching the local "today", which lands the row in the
    /// "Due today" section of `TodayView` (the Today surface only
    /// shows todos with a due date).
    func testCreateTodoViaQuickAdd_appearsInTodayList() {
        let app = TestApp.launchSignedIn()

        // Tap the quick-add FAB.
        let fab = app.buttons["today.quick-add-button"]
        XCTAssertTrue(fab.awaitExistence())
        fab.tap()

        // Type into the field, then submit.
        let field = app.textFields["quick-add.field"]
        XCTAssertTrue(field.awaitExistence())
        field.tap()
        field.typeText("buy milk today")

        let submit = app.buttons["quick-add.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        // The todo should appear in the Today list. The parser strips
        // the trailing "today" token from the title, leaving "buy milk".
        let title = app.staticTexts["buy milk"]
        XCTAssertTrue(title.awaitExistence(timeout: 5))
    }

    /// Test 2 — Edit a seeded todo's content, assert the new title
    /// renders in place. The seed uses a deterministic id so we can
    /// locate the row's `todo-title-<id>` element directly.
    func testEditTodoContent_persistsChange() {
        let id = TestApp.TestID.editTodo
        let app = TestApp.launchSignedIn(
            seedingTodosWithIDs: [(title: "old title", id: id)]
        )

        // Wait for the row to come in via the post-launch sync.
        let titleLabel = app.staticTexts["todo-title-\(id)"]
        XCTAssertTrue(titleLabel.awaitExistence(timeout: 8))

        // Long-press to open EditTodoView. The row's gesture is
        // `.onLongPressGesture(minimumDuration: 0.4)`, so a duration
        // of 0.6 clears the threshold with margin.
        titleLabel.press(forDuration: 0.6)

        // Edit the title field. The hydrate fills it with "old title";
        // we replace via select-all (long-press in field, then type).
        let field = app.textFields["edit-todo.title-field"]
        XCTAssertTrue(field.awaitExistence())
        field.tap()
        field.press(forDuration: 1.0)
        // "Select All" menu item — a fresh long-press in a TextField
        // surfaces it on iOS 17+.
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText("new title")

        let save = app.buttons["edit-todo.save-button"]
        XCTAssertTrue(save.awaitExistence())
        save.tap()

        // The row's title element re-renders. SwiftUI may keep the
        // same identifier; assert the visible text changed.
        let updated = app.staticTexts["new title"]
        XCTAssertTrue(updated.awaitExistence(timeout: 5))
    }

    /// Test 3 — Swipe-archive removes the row from Today.
    func testSwipeArchiveTodo_removesFromList() {
        let id = TestApp.TestID.archiveTodo
        let app = TestApp.launchSignedIn(
            seedingTodosWithIDs: [(title: "archive me", id: id)]
        )

        let row = app.staticTexts["todo-title-\(id)"]
        XCTAssertTrue(row.awaitExistence(timeout: 8))

        row.swipeLeft()

        let archiveButton = app.buttons["Archive"]
        XCTAssertTrue(archiveButton.awaitExistence(timeout: 3))
        archiveButton.tap()

        // The row should leave the list. We wait by polling the
        // element's `exists` flag — XCUIElement queries are live, so
        // the absence resolves once SwiftUI's `@Query` re-runs.
        let removed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        wait(for: [removed], timeout: 5)
    }

    /// Test 4 — Tap the complete circle. The optimistic flip lands on
    /// `note.completed = true`, which removes the row from
    /// `TodayView`'s `openTodos` filter (`!completed && !archived &&
    /// dueDate != nil`) — the row leaves the list and the section
    /// renders the empty placeholder "Nothing due today.". This is
    /// the same UX a user sees after completing the only due-today
    /// todo, so the test mirrors the production signal directly.
    ///
    /// Why we don't assert on a strikethrough/visual flip on the same
    /// row: `TodayView`'s `openTodos` partition removes completed
    /// todos before they reach the @Query subscribers — there's no
    /// "completed but still in Due today" state to observe. A future
    /// PR that exercises a "Done today" affordance can tighten the
    /// completed-style assertion against a list that keeps completed
    /// rows.
    func testToggleComplete_removesFromDueTodayList() {
        let id = TestApp.TestID.completeTodo
        let app = TestApp.launchSignedIn(
            seedingTodosWithIDs: [(title: "ship it", id: id)]
        )

        let title = app.staticTexts["todo-title-\(id)"]
        XCTAssertTrue(title.awaitExistence(timeout: 8))

        let circle = app.buttons["todo-complete-\(id)"]
        XCTAssertTrue(circle.awaitExistence())
        XCTAssertEqual(circle.label, "Mark complete")
        circle.tap()

        // The row should leave the Due-today section. Wait on the
        // empty-state placeholder so the assertion is robust against
        // SwiftUI's render cadence.
        let placeholder = app.staticTexts["Nothing due today."]
        XCTAssertTrue(placeholder.awaitExistence(timeout: 5))
        XCTAssertFalse(title.exists, "Completed row should be filtered out of openTodos.")
    }

    /// Test 5 — Create a project from the Projects tab; assert the
    /// row appears in the list.
    func testCreateProject_appearsInProjectsList() {
        let app = TestApp.launchSignedIn()

        // Navigate to the Projects tab. Tab buttons surface the
        // localised label as their accessibility identifier on iOS.
        app.tabBars.buttons["Projects"].tap()

        let newProjectButton = app.buttons["projects.new-project-button"]
        XCTAssertTrue(newProjectButton.awaitExistence(timeout: 5))
        newProjectButton.tap()

        let nameField = app.textFields["new-project.name-field"]
        XCTAssertTrue(nameField.awaitExistence())
        nameField.tap()
        nameField.typeText("Work")

        let createButton = app.buttons["new-project.create-button"]
        XCTAssertTrue(createButton.isEnabled)
        createButton.tap()

        // The optimistic insert lands a SwiftData row immediately,
        // so the new "Work" entry should appear in the list.
        let projectName = app.staticTexts["Work"]
        XCTAssertTrue(projectName.awaitExistence(timeout: 5))
    }

    /// Test 6 — Add a section to a seeded project from EditProjectView.
    func testAddSectionToProject_appearsInProjectDetail() {
        let id = TestApp.TestID.sectionProj
        let app = TestApp.launchSignedIn(
            seedingProjectsWithIDs: [(name: "Inbox+", id: id)]
        )

        app.tabBars.buttons["Projects"].tap()

        let row = app.otherElements["project-row-\(id)"]
        // ProjectRow is wrapped in NavigationLink; the link surfaces as
        // an `otherElement` or `cell` depending on the iOS version. Try
        // both before falling back to a static-text query on the name.
        if !row.waitForExistence(timeout: 5) {
            // Fallback: tap the row containing the project name.
            let nameText = app.staticTexts["Inbox+"]
            XCTAssertTrue(nameText.awaitExistence(timeout: 5))
            nameText.tap()
        } else {
            row.tap()
        }

        // Open the edit sheet.
        let editButton = app.buttons["project-detail.edit-button"]
        XCTAssertTrue(editButton.awaitExistence(timeout: 5))
        editButton.tap()

        // Add a "Drafts" section.
        let sectionField = app.textFields["edit-project.new-section-field"]
        XCTAssertTrue(sectionField.awaitExistence())
        sectionField.tap()
        sectionField.typeText("Drafts")

        let addSection = app.buttons["edit-project.add-section-button"]
        XCTAssertTrue(addSection.awaitExistence())
        addSection.tap()

        // The new section should render in the sections list inside
        // the same edit sheet.
        let drafts = app.staticTexts["Drafts"]
        XCTAssertTrue(drafts.awaitExistence(timeout: 5))
    }
}
