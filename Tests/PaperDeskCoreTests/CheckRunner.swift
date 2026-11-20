import Foundation

// A dependency-free check runner for Macs that have Command Line Tools but not Xcode/XCTest.
@main
struct CheckRunner {
    @MainActor
    static func main() async {
        let suite = PaperDeskCoreTests()
        if let index = CommandLine.arguments.firstIndex(of: "--network-privacy"), index + 1 < CommandLine.arguments.count {
            do {
                try await suite.testNetworkPrivacy(baseURL: CommandLine.arguments[index + 1])
                print("PASS  AI production transport: same-origin redirects, cross-origin blocking and cookie isolation")
            } catch { print("FAIL  AI network privacy: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture"), index + 1 < CommandLine.arguments.count {
            do {
                try await suite.testLocalFixtureTransport(baseURL: CommandLine.arguments[index + 1])
                print("PASS  Local HTTP fixture: streaming, page changes, follow-up history and cancellation")
            } catch { print("FAIL  Local HTTP fixture: \(error)"); exit(1) }
            return
        }
        let checks: [(String, () async throws -> Void)] = [
            ("Storage migration preserves WAL data, nested folders, notes and conversations", { try await suite.testStorageMigrationPreservesWholeLibrary() }),
            ("Storage migration rejects conflicts and cleans up cancellation and corruption", { try await suite.testStorageMigrationFailureAndCancellation() }),
            ("Custom storage survives relaunch and never silently replaces unavailable libraries", { try suite.testStorageLocationPersistenceAndUnavailableDisk() }),
            ("Browser imports use custom storage and a stable native-host inbox", { try suite.testBrowserInboxWithCustomStorage() }),
            ("Credential denial recovery, session-only keys and account isolation", { try suite.testCredentialRecoveryAndSessionIsolation() }),
            ("Credential saving bypasses legacy reads and retains keys after failure", { try suite.testCredentialSaveDoesNotDependOnLegacyRead() }),
            ("Credential legacy lookup, successful retry and actionable errors", { try suite.testCredentialLegacyAndRetry() }),
            ("Visual pages: cross-page retrieval, scope and exact caption positions", { try suite.testVisualScopeAndProvenance() }),
            ("Visual requests: text compatibility, image allowlist and legacy history", { try suite.testVisualRequestCompatibility() }),
            ("Visual rendering, history persistence and original-file independence", { try await suite.testVisualRenderingAndPersistence() }),
            ("Automatic question scope, explicit local targets and manual overrides", { try suite.testAutomaticScopeUsesQuestionInsteadOfReadingPage() }),
            ("Document-wide retrieval, distant English evidence and follow-up context", { try suite.testDocumentRetrievalCoversDistantEvidenceAndFollowups() }),
            ("Automatic scope persistence, legacy contexts and request framing", { try suite.testAutomaticContextPersistenceAndPrompt() }),
            ("Background import queue: progress, multiple jobs, destinations and deduplication", { try await suite.testBackgroundQueueProgressAndDestinations() }),
            ("Background import queue: failure, cancellation, retry and deleted destinations", { try await suite.testBackgroundQueueFailureCancelRetryAndDeletedFolder() }),
            ("arXiv queries, Atom parsing, identifiers and unsafe responses", { try suite.testArxivParsingAndQueries() }),
            ("Library full-text search, arXiv import, deduplication and cloud metadata", { try await suite.testLibrarySearchAndArxivImport() }),
            ("arXiv transport, cache, paging, invalid downloads and cancellation", { try await suite.testArxivTransportAndCancellation() }),
            ("Import, deduplication, persistence and original-file independence", { try await suite.testImportDeduplicatesAndPersistsLibraryAndAnnotations() }),
            ("Invalid PDF leaves no library entry", { try await suite.testInvalidPDFDoesNotLeaveLibraryEntry() }),
            ("Text chunks resolve to exact PDF page ranges", { try await suite.testExtractedOffsetsResolveBackToExactPDFText() }),
            ("Export preserves notes, existing annotations and outline", { try await suite.testAnnotationExportPreservesExistingMarks() }),
            ("Retrieval budget and citation allowlist", { try suite.testRetrievalBudgetAndCitationsAreBoundedByRealSources() }),
            ("API URL validation", { try suite.testEndpointValidation() }),
            ("Chat request and response through fixture transport", { try await suite.testChatRequestAndAnswerThroughStubbedTransport() }),
            ("Authentication failure redacts remote payload", { try await suite.testAuthenticationFailureDoesNotExposeProviderPayload() }),
            ("Current page isolation and selection provenance", { try suite.testCurrentPageIsolationAndSelectionProvenance() }),
            ("Existing conversations and context persistence", { try suite.testLegacyConversationAndContextRoundTrip() }),
            ("SSE deltas, Unicode, citations and incomplete streams", { try suite.testSSEDecodingAndIncompleteStream() }),
            ("Streaming transport, JSON fallback and model discovery", { try await suite.testStreamingTransportAndModelDiscovery() }),
            ("Connection test contains no document; per-endpoint credentials", { try await suite.testConnectionPayloadContainsNoDocument() }),
            ("Cancellation stops an unfinished streaming response", { try await suite.testCancellationStopsPendingStream() }),
            ("Browser PDF transfer, source persistence and deduplication", { try suite.testBrowserTransferAndLibrary() }),
            ("Interrupted, invalid and oversized browser transfers", { try suite.testBrowserTransferRejectsInvalidAndInterruptedInput() }),
            ("Browser URL validation and legacy library compatibility", { try suite.testBrowserURLAndLegacyMetadata() }),
            ("Native message framing, Unicode and truncated input", { try suite.testNativeMessageFraming() }),
            ("Folders, rename, move, safe removal and legacy metadata", { try suite.testFoldersAndLegacyLibrary() }),
            ("Nested folders, scoped names, cycle prevention and safe subtree removal", { try suite.testNestedFoldersAndSafeRemoval() }),
            ("Nested cloud restore, parent remapping and legacy archive compatibility", { try suite.testNestedCloudRestoreAndValidation() }),
            ("Cloud restore preserves edits, deduplicates and repairs PDFs", { try suite.testCloudMergeAndRepair() }),
            ("Invalid cloud archives leave the library unchanged", { try suite.testCloudInvalidArchiveIsAtomic() }),
            ("Cloud commit order, incremental save, restore and cancellation", { try await suite.testCloudTransferCommitAndRoundTrip() }),
            ("Baidu path, redirect and credential encoding constraints", { try suite.testBaiduPathsAndCredentialsEncoding() }),
            ("Baidu OAuth, refresh, multipart upload and download protocol", { try await suite.testBaiduOAuthAndTransferProtocol() }),
            ("Baidu pending, failure, unsafe links and incomplete downloads", { try await suite.testBaiduRejectsUnsafeAndFailedResponses() })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS  \(name)") }
            catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}

struct CheckFailure: Error, CustomStringConvertible { let description: String }
func XCTFail(_ message: String) throws { throw CheckFailure(description: message) }
func XCTUnwrap<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "Expected a value at \(file):\(line)") }; return value
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, line: Int = #line) throws {
    let a = try lhs(), b = try rhs()
    guard a == b else { throw CheckFailure(description: "Expected equal values at line \(line): \(a) != \(b)") }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, line: Int = #line) throws {
    guard try lhs() != rhs() else { throw CheckFailure(description: "Expected different values at line \(line)") }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
    guard try value() else { throw CheckFailure(description: "Expected true at line \(line)") }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws { try XCTAssertTrue(try !value(), line: line) }
func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, line: Int = #line) throws { _ = try XCTUnwrap(value(), line: line) }
func XCTAssertGreaterThan<T: Comparable>(_ lhs: T, _ rhs: T, line: Int = #line) throws { try XCTAssertTrue(lhs > rhs, line: line) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T, line: Int = #line) throws { try XCTAssertTrue(lhs <= rhs, line: line) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, line: Int = #line) throws {
    do { _ = try expression() } catch { return }
    throw CheckFailure(description: "Expected an error at line \(line)")
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T) throws { _ = try expression() }
