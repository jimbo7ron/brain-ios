// SchemaFallbackChecks.swift
// brain-ios
//
// Source-level verification for `BrainApp.isSchemaIncompatibilityError`
// — the predicate that gates the destructive `ModelContainer` fallback
// in `BrainApp.init`. brain-ios has no test runner today (see CLAUDE.md
// — "Source-level verification only"); this file follows the same
// pattern as `NotFoundClassificationChecks.swift` (this PR) and
// `ServerDateChecks` from earlier polish rounds:
//
//   1. `BrainDebugSchemaFallbackChecks.runAll()` returns the list of
//      failures (empty list = green). Hookable from a future debug menu
//      or a one-shot CI step.
//   2. Each failed check fires `assertionFailure(...)` so debug builds
//      halt in the debugger when a regression lands.
//
// The actual destructive-fallback path (backup-then-wipe + retry)
// can't be exercised cleanly here without standing up a real
// `Application Support` directory and seeding it with a corrupt store.
// We therefore document those scenarios as manual TestFlight checks
// in the PR body and verify only the classifier in code. The
// classifier is the load-bearing decision: a wrong answer there means
// either (a) we wipe data on a non-recoverable error (the bug we're
// fixing) or (b) we crash on a real schema migration the user could
// have recovered from.

#if DEBUG

import Foundation

/// Bundle of debug-only verification cases for the polish-round
/// destructive-fallback narrowing. Production binaries strip the
/// entire enum.
enum BrainDebugSchemaFallbackChecks {

    /// Run every documented case. Returns a list of human-readable
    /// failure descriptions; an empty list means everything passed.
    /// Each failure also fires `assertionFailure` so debug builds
    /// halt in the debugger when a regression lands.
    @discardableResult
    static func runAll() -> [String] {
        var failures: [String] = []

        checkPersistentStoreErrorClassifiesAsSchemaIncompatibility(into: &failures)
        checkMigrationErrorClassifiesAsSchemaIncompatibility(into: &failures)
        checkDiskFullErrorIsNotSchemaIncompatibility(into: &failures)
        checkPermissionErrorIsNotSchemaIncompatibility(into: &failures)
        checkArbitraryNonCocoaErrorIsNotSchemaIncompatibility(into: &failures)
        checkOutOfRangeCocoaErrorIsNotSchemaIncompatibility(into: &failures)

        return failures
    }

    // MARK: - Cases

    /// Core Data / SwiftData typically surfaces a schema mismatch as
    /// `NSCocoaErrorDomain` code 134100
    /// (`NSPersistentStoreIncompatibleVersionHashError`). The
    /// classifier should accept this so the fallback runs and the
    /// existing store gets backed up + replaced.
    private static func checkPersistentStoreErrorClassifiesAsSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134100, userInfo: nil)
        guard BrainApp._debug_isSchemaIncompatibilityError(error) else {
            record(&failures, "NSCocoaError 134100 (incompatible version hash) should classify as schema-incompatibility")
            return
        }
    }

    /// Migration-missing error: `NSMigrationMissingSourceModelError`
    /// (134110). Same family as 134100 — must classify as
    /// schema-incompatibility so the fallback wipes the legacy store.
    private static func checkMigrationErrorClassifiesAsSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: NSCocoaErrorDomain, code: 134110, userInfo: nil)
        guard BrainApp._debug_isSchemaIncompatibilityError(error) else {
            record(&failures, "NSCocoaError 134110 (migration missing source model) should classify as schema-incompatibility")
            return
        }
    }

    /// Disk-full surfaces as POSIX `ENOSPC` (28) in `NSPOSIXErrorDomain`,
    /// NOT in `NSCocoaErrorDomain`. Must NOT classify as
    /// schema-incompatibility — wiping the store wouldn't help and
    /// would destroy user data. The production path crashes with
    /// `fatalError` instead so the TestFlight crash log surfaces it.
    private static func checkDiskFullErrorIsNotSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: nil)
        if BrainApp._debug_isSchemaIncompatibilityError(error) {
            record(&failures, "POSIX ENOSPC (disk full) must NOT classify as schema-incompatibility — would wipe data")
        }
    }

    /// File-system permissions: surfaces as `NSCocoaErrorDomain` in
    /// the 4xx range (e.g. `NSFileWriteNoPermissionError = 513`),
    /// well below the 134xxx persistent-store family. Must NOT
    /// classify as schema-incompatibility.
    private static func checkPermissionErrorIsNotSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: nil)
        if BrainApp._debug_isSchemaIncompatibilityError(error) {
            record(&failures, "NSCocoaError 513 (no write permission) must NOT classify as schema-incompatibility — would wipe data")
        }
    }

    /// Arbitrary non-Cocoa error (e.g. a third-party domain). Must
    /// NOT classify as schema-incompatibility — we have no signal
    /// that a wipe would help.
    private static func checkArbitraryNonCocoaErrorIsNotSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: "com.example.OtherDomain", code: 134100, userInfo: nil)
        if BrainApp._debug_isSchemaIncompatibilityError(error) {
            record(&failures, "non-Cocoa domain must NOT classify as schema-incompatibility even with the same code")
        }
    }

    /// Cocoa domain but outside the 134xxx persistent-store band
    /// (e.g. 4097 — `NSXPCConnectionInterrupted`). Must NOT classify
    /// as schema-incompatibility.
    private static func checkOutOfRangeCocoaErrorIsNotSchemaIncompatibility(into failures: inout [String]) {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: nil)
        if BrainApp._debug_isSchemaIncompatibilityError(error) {
            record(&failures, "Cocoa domain out-of-range code (4097) must NOT classify as schema-incompatibility")
        }
    }

    // MARK: - Helpers

    private static func record(_ failures: inout [String], _ message: String) {
        failures.append(message)
        assertionFailure(message)
    }
}

#endif
