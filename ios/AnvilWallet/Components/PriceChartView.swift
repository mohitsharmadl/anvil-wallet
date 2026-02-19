import SwiftUI
import Charts

/// Displays an interactive price history chart for a token.
///
/// Features:
///   - Line chart rendered with Swift Charts (iOS 16+)
///   - Time range selector pills (1D, 1W, 1M, 3M, 1Y, ALL)
///   - Price change indicator (absolute + percentage, green/red)
///   - Drag-to-scrub: touch and drag along the chart to see price at any point
///   - Loading and error states
struct PriceChartView: View {

    let token: TokenModel

    @State private var selectedRange: PriceTimeRange = .week
    @State private var pricePoints: [PricePoint] = []
    @State private var isLoading = true
    @State private var hasError = false
    @State private var selectedPoint: PricePoint?
    @State private var isDragging = false

    private let service = PriceHistoryService.shared

    // MARK: - Computed

    /// The price displayed at the top: either the scrubbed point or the latest.
    private var displayPrice: Double {
        if let point = selectedPoint {
            return point.price
        }
        return pricePoints.last?.price ?? token.priceUsd
    }

    /// The reference price: start of the selected range.
    private var startPrice: Double {
        pricePoints.first?.price ?? token.priceUsd
    }

    /// Absolute price change for the selected range.
    private var priceChange: Double {
        displayPrice - startPrice
    }

    /// Percentage price change for the selected range.
    private var priceChangePercent: Double {
        guard startPrice > 0 else { return 0 }
        return (priceChange / startPrice) * 100
    }

    /// Whether the price change is positive (or zero).
    private var isPositive: Bool {
        priceChange >= 0
    }

    /// Color for the chart line and change indicator.
    private var trendColor: Color {
        isPositive ? .accentGreen : .error
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            // Price header
            priceHeader

            // Chart area
            if isLoading {
                loadingView
            } else if hasError || pricePoints.isEmpty {
                errorView
            } else {
                chartContent
            }

            // Time range selector
            timeRangeSelector
        }
        .padding(.horizontal, 20)
        .task {
            await loadData()
        }
    }

    // MARK: - Price Header

    private var priceHeader: some View {
        VStack(spacing: 4) {
            Text(formatPrice(displayPrice))
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: displayPrice)

            if !pricePoints.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))

                    Text(formatChange(priceChange))
                        .font(.subheadline.weight(.semibold).monospacedDigit())

                    Text("(\(formatPercent(priceChangePercent)))")
                        .font(.subheadline.monospacedDigit())

                    Text(selectedRange.rawValue)
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                }
                .foregroundColor(trendColor)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.15), value: priceChange)
            }

            if let point = selectedPoint {
                Text(formatDate(point.date, range: selectedRange))
                    .font(.caption)
                    .foregroundColor(.textTertiary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private var chartContent: some View {
        Chart(pricePoints) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Price", point.price)
            )
            .foregroundStyle(trendColor)
            .interpolationMethod(.catmullRom)

            AreaMark(
                x: .value("Date", point.date),
                y: .value("Price", point.price)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [trendColor.opacity(0.2), trendColor.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                updateSelectedPoint(at: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in
                                isDragging = false
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedPoint = nil
                                }
                            }
                    )
            }
        }
        .frame(height: 200)
        .animation(.easeInOut(duration: 0.3), value: selectedRange)
    }

    /// Y-axis domain with a small padding so the line doesn't touch edges.
    private var yDomain: ClosedRange<Double> {
        let prices = pricePoints.map(\.price)
        guard let minPrice = prices.min(), let maxPrice = prices.max(), minPrice < maxPrice else {
            let p = pricePoints.first?.price ?? 0
            return (p * 0.99)...(p * 1.01)
        }
        let padding = (maxPrice - minPrice) * 0.08
        return (minPrice - padding)...(maxPrice + padding)
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        HStack(spacing: 0) {
            ForEach(PriceTimeRange.allCases) { range in
                Button {
                    guard range != selectedRange else { return }
                    selectedRange = range
                    selectedPoint = nil
                    Task { await loadData() }
                } label: {
                    Text(range.rawValue)
                        .font(.caption.weight(range == selectedRange ? .bold : .medium))
                        .foregroundColor(range == selectedRange ? .white : .textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            range == selectedRange
                                ? AnyShapeStyle(trendColor)
                                : AnyShapeStyle(Color.clear)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.backgroundCard)
        .clipShape(Capsule())
    }

    // MARK: - Loading & Error

    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.backgroundCard)
            .frame(height: 200)
            .overlay(ProgressView())
    }

    private var errorView: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.backgroundCard)
            .frame(height: 200)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundColor(.textTertiary)
                    Text("Price data unavailable")
                        .font(.caption)
                        .foregroundColor(.textTertiary)
                    Button("Retry") {
                        Task { await loadData() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentGreen)
                }
            )
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        hasError = false

        let points = await service.fetchHistory(
            symbol: token.symbol,
            contractAddress: token.contractAddress,
            chain: token.chain,
            range: selectedRange
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            pricePoints = points
            isLoading = false
            hasError = points.isEmpty
        }
    }

    // MARK: - Drag Interaction

    private func updateSelectedPoint(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotFrame = geometry[proxy.plotFrame!]
        let xPosition = location.x - plotFrame.origin.x

        guard xPosition >= 0, xPosition <= plotFrame.width else { return }

        guard let date: Date = proxy.value(atX: xPosition) else { return }

        // Find the closest point to the scrubbed date
        let closest = pricePoints.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })

        if let closest {
            selectedPoint = closest
        }
    }

    // MARK: - Formatters

    private func formatPrice(_ price: Double) -> String {
        if price >= 1 {
            return String(format: "$%.2f", price)
        } else if price >= 0.01 {
            return String(format: "$%.4f", price)
        } else if price > 0 {
            return String(format: "$%.6f", price)
        }
        return "$0.00"
    }

    private func formatChange(_ change: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        if abs(change) >= 1 {
            return String(format: "%@$%.2f", sign, change)
        } else {
            return String(format: "%@$%.4f", sign, change)
        }
    }

    private func formatPercent(_ percent: Double) -> String {
        String(format: "%+.2f%%", percent)
    }

    private func formatDate(_ date: Date, range: PriceTimeRange) -> String {
        let formatter = DateFormatter()
        switch range {
        case .day:
            formatter.dateFormat = "h:mm a"
        case .week:
            formatter.dateFormat = "EEE, MMM d"
        case .month, .threeMonths:
            formatter.dateFormat = "MMM d, yyyy"
        case .year, .all:
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }
}
