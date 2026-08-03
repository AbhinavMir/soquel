import AppKit
import XCTest
@testable import SoquelCore

final class BreadcrumbSeparatorTests: XCTestCase {
    /// The root's own label is "/", so a separator after it wrote "//".
    func testNoSlashAfterTheRoot() {
        XCTAssertFalse(PaneViewController.breadcrumbNeedsSeparator(after: "/", isLast: false))
    }

    func testASlashBetweenOrdinaryCrumbs() {
        XCTAssertTrue(PaneViewController.breadcrumbNeedsSeparator(after: "Users", isLast: false))
    }

    func testNothingAfterTheLastCrumb() {
        XCTAssertFalse(PaneViewController.breadcrumbNeedsSeparator(after: "Applications", isLast: true))
        XCTAssertFalse(PaneViewController.breadcrumbNeedsSeparator(after: "/", isLast: true))
    }

    /// The whole path, assembled the way the bar assembles it.
    private func render(_ names: [String]) -> String {
        var out = ""
        for (index, name) in names.enumerated() {
            out += name
            if PaneViewController.breadcrumbNeedsSeparator(after: name, isLast: index == names.count - 1) {
                out += "/"
            }
        }
        return out
    }

    func testAFullPathReadsAsAPath() {
        XCTAssertEqual(render(["/", "Applications"]), "/Applications")
        XCTAssertEqual(render(["/", "Users", "august", "Code"]), "/Users/august/Code")
        XCTAssertEqual(render(["/"]), "/")
    }
}

final class PermissionExplanationTests: XCTestCase {
    func testTheNotationIsUnchanged() {
        XCTAssertEqual(InspectorView.describe(mode: 0o755), "rwxr-xr-x (755)")
        XCTAssertEqual(InspectorView.describe(mode: 0o644), "rw-r--r-- (644)")
    }

    /// The tooltip says who can do what, in words.
    func testItNamesEachOfTheThreeAudiences() {
        let text = InspectorView.explain(mode: 0o644)
        XCTAssertTrue(text.contains("The owner can read it and change it"), text)
        XCTAssertTrue(text.contains("The group can read it"), text)
        XCTAssertTrue(text.contains("Everyone else can read it"), text)
    }

    func testNoPermissionsIsSaidPlainly() {
        XCTAssertTrue(InspectorView.explain(mode: 0o600).contains("cannot do anything with it"))
    }

    /// x on a folder is permission to go into it, not to run it.
    func testExecuteMeansSomethingElseOnAFolder() {
        XCTAssertEqual(InspectorView.phrase(for: 0o1, isDirectory: true), "can open it")
        XCTAssertEqual(InspectorView.phrase(for: 0o1, isDirectory: false), "can run it")
        XCTAssertEqual(InspectorView.phrase(for: 0o7, isDirectory: true),
                       "can list it, add and remove things and open it")
    }

    func testTheLegendSaysWhatTheLettersAre() {
        XCTAssertTrue(InspectorView.explain(mode: 0o755).contains("r read · w change · x"))
    }
}
