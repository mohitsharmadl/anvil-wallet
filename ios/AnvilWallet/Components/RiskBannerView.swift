import SwiftUI

/// Displays a risk assessment banner with expandable findings.
/// Green for safe, yellow for warning, red for danger.
struct RiskBannerView: View {
    let assessment: RiskAssessment
    @State private var isExpanded = false

    private var bannerColor: Color {
        switch assessment.overallLevel {
        case .safe: return .success
        case .warning: return .warning
        case .danger: return .error
        }
    }

    private var iconName: String {
        switch assessment.overallLevel {
        case .safe: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.shield.fill"
        }
    }

    var body: some View {
        if assessment.findings.isEmpty {
            // Safe — minimal banner
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.success)
                Text("No risks detected")
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)
                Spacer()
            }
            .padding(12)
            .background(Color.success.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName)
                            .foregroundColor(bannerColor)

                        Text(headerText)
                            .font(.subheadline.bold())
                            .foregroundColor(bannerColor)

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(bannerColor)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)

                // Expanded findings
                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(assessment.findings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(colorForLevel(finding.level))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.title)
                                        .font(.caption.bold())
                                        .foregroundColor(.textPrimary)
                                    Text(finding.detail)
                                        .font(.caption)
                                        .foregroundColor(.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            .background(bannerColor.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .onAppear {
                // Auto-expand for danger
                if assessment.overallLevel == .danger {
                    isExpanded = true
                }
            }
        }
    }

    private var headerText: String {
        let count = assessment.findings.count
        switch assessment.overallLevel {
        case .safe:
            return "No risks detected"
        case .warning:
            return "\(count) warning\(count == 1 ? "" : "s") detected"
        case .danger:
            return "\(count) risk\(count == 1 ? "" : "s") detected — review carefully"
        }
    }

    private func colorForLevel(_ level: RiskLevel) -> Color {
        switch level {
        case .safe: return .success
        case .warning: return .warning
        case .danger: return .error
        }
    }
}
