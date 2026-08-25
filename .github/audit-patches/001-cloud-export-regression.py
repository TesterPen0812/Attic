from pathlib import Path

path = Path("AtticTests/TaskStoreTests.swift")
source = path.read_text()
needle = "    func testCloudSyncProtectionKeepsOverlappingImportsProtectedUntilRefresh() {\n"
test = '''    func testCloudSyncProtectionDoesNotMarkFailedExportAsCovered() {
        let failedExportID = UUID()
        let retryExportID = UUID()
        var protection = CloudSyncProtectionState()

        protection.noteLocalSave()
        protection.apply(CloudSyncEventUpdate(
            id: failedExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.apply(CloudSyncEventUpdate(
            id: failedExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: false,
            errorMessage: "Network unavailable"
        ))

        XCTAssertTrue(
            protection.protectsExport,
            "A failed CloudKit export must leave the local save protected until a later successful export covers it."
        )

        protection.apply(CloudSyncEventUpdate(
            id: retryExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.apply(CloudSyncEventUpdate(
            id: retryExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))

        XCTAssertFalse(protection.protectsExport)
    }

'''
if needle not in source:
    raise SystemExit("Cloud sync test insertion point not found")
if "testCloudSyncProtectionDoesNotMarkFailedExportAsCovered" in source:
    raise SystemExit("Regression test already exists")
path.write_text(source.replace(needle, test + needle, 1))
print("test: reproduce failed CloudKit export protection gap")
