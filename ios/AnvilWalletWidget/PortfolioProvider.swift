import WidgetKit

/// TimelineProvider that reads portfolio data from the shared App Group UserDefaults
/// and provides timeline entries to WidgetKit.
struct PortfolioProvider: TimelineProvider {

    // MARK: - Placeholder

    /// Shown while the widget is loading for the first time.
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: Date(), data: .placeholder)
    }

    // MARK: - Snapshot

    /// Shown in the widget gallery preview.
    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        if context.isPreview {
            completion(PortfolioEntry(date: Date(), data: .placeholder))
        } else {
            let data = WidgetData.load()
            completion(PortfolioEntry(date: Date(), data: data))
        }
    }

    // MARK: - Timeline

    /// Provides the actual timeline entries. We return a single entry with the
    /// current data and ask WidgetKit to refresh after 15 minutes.
    ///
    /// The main app also calls `WidgetCenter.shared.reloadAllTimelines()` whenever
    /// balances or prices change, which triggers a fresh call to this method.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let data = WidgetData.load()
        let entry = PortfolioEntry(date: Date(), data: data)

        // Refresh every 15 minutes as a fallback; the app also pushes updates proactively.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))

        completion(timeline)
    }
}
