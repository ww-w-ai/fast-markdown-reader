import XCTest
import AppKit
@testable import FastMDReader

/// AppKit appends AutoFill to the reader's context menu after we build it, so the removal runs on
/// items we never created. These tests pin the two things that could go wrong: matching too little
/// (the item survives) and matching too much (Services, or one of our own items, disappears).
final class ContextMenuTests: XCTestCase {
    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    func testMatchesBySelectorNameRegardlessOfTitle() {
        let i = item("완전히 다른 제목", action: NSSelectorFromString("_autoFillWithContact:"))
        XCTAssertTrue(ReaderTextView.isAutoFill(i))
    }

    func testMatchesASubmenuWhoseItemsAreAutoFill() {
        let parent = item("Anything")
        let sub = NSMenu()
        sub.addItem(item("Card", action: NSSelectorFromString("autoFillCreditCard:")))
        parent.submenu = sub
        XCTAssertTrue(ReaderTextView.isAutoFill(parent))
    }

    /// The fallback for a submenu AppKit hasn't populated yet — title only, so it must be tight.
    func testMatchesLocalisedTitlesWhenThereIsNoSelector() {
        for title in ["AutoFill", "Auto Fill", "자동 완성", "自動入力"] {
            XCTAssertTrue(ReaderTextView.isAutoFill(item(title)), "should match \(title)")
        }
    }

    func testLeavesServicesAndOurOwnItemsAlone() {
        for title in ["Services", "서비스", "Copy", "Edit…", "Move Block…", "Delete Block…", "Select All"] {
            XCTAssertFalse(ReaderTextView.isAutoFill(item(title)), "must not remove \(title)")
        }
    }

    func testTidySeparatorsClosesTheGapWithoutTouchingRealItems() {
        let menu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(item("Copy"))
        menu.addItem(.separator())
        menu.addItem(.separator())      // the gap left where AutoFill used to be
        menu.addItem(item("Services"))
        menu.addItem(.separator())
        ReaderTextView.tidySeparators(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Copy", "", "Services"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }
}
