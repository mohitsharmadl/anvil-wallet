import SwiftUI
import CoreImage.CIFilterBuiltins

/// ReceiveView displays the user's wallet address and a QR code for receiving tokens.
struct ReceiveView: View {
    let chain: String
    let address: String

    @State private var showCopiedFeedback = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Chain indicator
            Text(chain.capitalized)
                .font(.headline)
                .foregroundColor(.accentGreen)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentGreen.opacity(0.1))
                .cornerRadius(20)

            // QR Code
            if let qrImage = generateQRCode(from: address) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(20)
                    .background(Color.white)
                    .cornerRadius(20)
                    .accessibilityLabel("QR code for \(chain.capitalized) address")
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.backgroundCard)
                    .frame(width: 260, height: 260)
                    .overlay(
                        Text("QR Code")
                            .foregroundColor(.textTertiary)
                    )
                    .accessibilityLabel("QR code unavailable")
            }

            // Address display
            VStack(spacing: 8) {
                Text("Your \(chain.capitalized) Address")
                    .font(.subheadline)
                    .foregroundColor(.textSecondary)

                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Your \(chain.capitalized) address: \(address)")

            // Copy button
            Button {
                SecurityService.shared.copyWithAutoClear(address, sensitive: false)
                Haptic.impact(.light)
                withAnimation {
                    showCopiedFeedback = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        showCopiedFeedback = false
                    }
                }
            } label: {
                HStack {
                    Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                    Text(showCopiedFeedback ? "Copied!" : "Copy Address")
                }
                .font(.headline)
                .foregroundColor(.accentGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentGreen.opacity(0.1))
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .accessibilityLabel(showCopiedFeedback ? "Address copied" : "Copy address")
            .accessibilityHint("Double tap to copy address to clipboard")

            // Share button
            Button {
                let activityVC = UIActivityViewController(
                    activityItems: [address],
                    applicationActivities: nil
                )
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share Address")
                }
                .font(.headline)
                .foregroundColor(.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.backgroundCard)
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .accessibilityLabel("Share address")
            .accessibilityHint("Double tap to share your address")

            // Warning
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.warning)
                    .font(.caption)

                Text("Only send \(chain.capitalized) tokens to this address. Sending other tokens may result in permanent loss.")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
            }
            .padding(12)
            .background(Color.warning.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Warning: Only send \(chain.capitalized) tokens to this address. Sending other tokens may result in permanent loss.")

            Spacer()
        }
        .background(Color.backgroundPrimary)
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - QR Code Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        guard let data = string.data(using: .ascii) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the QR code for a crisp image
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    NavigationStack {
        ReceiveView(
            chain: "ethereum",
            address: "0x1234567890abcdef1234567890abcdef12345678"
        )
    }
}
