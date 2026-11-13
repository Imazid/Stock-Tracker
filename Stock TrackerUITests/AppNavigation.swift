import XCTest

extension XCUIApplication {
    /// Opens a place in the app by name: one of the five tabs (Home, Markets, Portfolio,
    /// Agents, Activity) or a Markets section (Watchlist, Search, News). Older tests used
    /// "Watchlist", "News" and "Search" as tabs; they now live inside Markets.
    @discardableResult
    func open(_ name: String, timeout: TimeInterval = 10) -> Bool {
        if ["Watchlist", "Search", "News"].contains(name) {
            guard tapTab("Markets", timeout: timeout) else { return false }
            let segment = segmentedControls["markets.section"].buttons[name]
            guard segment.waitForExistence(timeout: timeout) else { return false }
            if !segment.isSelected { segment.tap() }
            return true
        }
        return tapTab(name, timeout: timeout)
    }

    private func tapTab(_ name: String, timeout: TimeInterval) -> Bool {
        let button = tabBars.buttons[name].exists ? tabBars.buttons[name] : buttons[name].firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        return true
    }
}
