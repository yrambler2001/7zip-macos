// UpdateActionSetTests.swift -- the Compress dialog's update mode from the command line's action set
// (UpdateGUI.cpp:284-312, :446-453; ArchiveCommandLine.cpp:866-945; PROGRESS 8.x "Dialog
// selection rules", 03 §2.4).

import XCTest

final class UpdateActionSetTests: XCTestCase {

    private func mode(_ argv: [String]) throws -> SevenZipDialogUpdateMode? {
        try SevenZipArguments.parse(argv).dialogUpdateMode
    }

    func testCommandsPickTheirDefaultSet() throws {
        XCTAssertEqual(try mode(["a", "-ad", "arc.7z", "f"]), .add)
        XCTAssertEqual(try mode(["u", "-ad", "arc.7z", "f"]), .update)
    }

    func testUSwitchesSelectFreshAndSync() throws {
        // Fresh = Update with r (new on disk, absent from the archive) ignored.
        XCTAssertEqual(try mode(["u", "-ur0", "-ad", "arc.7z", "f"]), .fresh)
        // Sync = Update with q (in the archive, gone from disk) ignored.
        XCTAssertEqual(try mode(["u", "-uq0", "-ad", "arc.7z", "f"]), .sync)
        // Add is Update with x and z compressed; spelled from `u`.
        XCTAssertEqual(try mode(["u", "-ux2z2", "-ad", "arc.7z", "f"]), .add)
        // Each string starts again from the command's default set (:921), so the last one wins:
        // x1 and z1 together make Update, z1 alone after x1 is none of the four.
        XCTAssertEqual(try mode(["a", "-ux1z1", "-ad", "arc.7z", "f"]), .update)
        XCTAssertNil(try mode(["a", "-ux1", "-uz1", "-ad", "arc.7z", "f"]))
    }

    func testAnUnlistedSetHasNoDialogMode() throws {
        // y0: "newer in the archive" ignored -- none of the four sets.
        XCTAssertNil(try mode(["a", "-uy0", "-ad", "arc.7z", "f"]))
    }

    func testANewArchiveCommandLeavesTheFirstOneAlone() throws {
        XCTAssertEqual(try mode(["u", "-up0q0!other.7z", "-ad", "arc.7z", "f"]), .update)
        XCTAssertEqual(try mode(["u", "-u-", "-ad", "arc.7z", "f"]), .update)
    }

    func testUnsupportedActionsAreRejected() throws {
        // kUpdatePairStateNotSupportedActions: p2, q2, r1.
        let parsed = try? SevenZipArguments.parse(["a", "-up2", "arc.7z", "f"])
        if let parsed { XCTAssertNil(parsed.updateActionSet) }
    }
}
