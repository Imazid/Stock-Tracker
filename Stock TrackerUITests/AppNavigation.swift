import XCTest

extension XCUIApplication {
    /// Opens a place in the app by name: one of the root tabs (Home, Markets, Portfolio,
    /// Private Markets, Agents, Activity) or a Markets section (Watchlist, Explore, Search, News). Older tests used
    /// "Watchlist", "News" and "Search" as tabs; they now live inside Markets.
    @discardableResult
    func open(_ name: String, timeout: TimeInterval = 10) -> Bool {
        if ["Watchlist", "Explore", "Search", "News"].contains(name) {
            guard tapTab("Markets", timeout: timeout) else { return false }
            let segment = segmentedControls["markets.section"].buttons[name]
            guard segment.waitForExistence(timeout: timeout) else { return false }
            if !segment.isSelected { segment.tap() }
            return true
        }
        return tapTab(name, timeout: timeout)
    }

    private func tapTab(_ name: String, timeout: TimeInterval) -> Bool {
        let tab = tabBars.buttons[name]
        if tab.exists {
            tab.tap()
            return true
        }
        let more = tabBars.buttons["More"]
        if more.exists {
            more.tap()
            let overflow = cells.containing(.staticText, identifier: name).firstMatch
            if overflow.waitForExistence(timeout: 3) {
                overflow.tap()
                return true
            }
            let overflowButton = buttons[name].firstMatch
            if overflowButton.exists {
                overflowButton.tap()
                return true
            }
        }
        let button = buttons[name].firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        return true
    }
}
