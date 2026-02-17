import SwiftUI
import AVFoundation

/// QRScannerView provides camera-based QR code scanning for wallet addresses.
///
/// Uses AVCaptureSession with the back camera to detect QR codes.
/// When a valid QR code is found, the result is passed back via the `onScan` callback.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss

    let onScan: (String) -> Void

    @State private var isScanning = true
    @State private var scannedCode: String?
    @State private var showPermissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                QRCameraPreview(
                    isScanning: $isScanning,
                    scannedCode: $scannedCode,
                    showPermissionDenied: $showPermissionDenied
                )
                .ignoresSafeArea()

                // Overlay with scanning frame
                VStack {
                    Spacer()

                    // Scanning frame
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.accentGreen, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .overlay(
                            // Corner accents
                            GeometryReader { _ in
                                // Top-left corner
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 30))
                                    path.addLine(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: 30, y: 0))
                                }
                                .stroke(Color.accentGreen, lineWidth: 4)
                            }
                        )

                    Spacer()

                    // Instructions
                    VStack(spacing: 8) {
                        Text("Scan QR Code")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Point your camera at a wallet address QR code")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.bottom, 40)
                }

                // Permission denied overlay
                if showPermissionDenied {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.textTertiary)

                        Text("Camera Access Required")
                            .font(.headline)
                            .foregroundColor(.textPrimary)

                        Text("Please enable camera access in Settings to scan QR codes.")
                            .font(.body)
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)

                        Button("Open Settings") {
                            if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsUrl)
                            }
                        }
                        .buttonStyle(.primary)
                        .padding(.horizontal, 40)
                    }
                    .padding()
                    .background(Color.backgroundPrimary)
                }
            }
            .onChange(of: scannedCode) { _, newValue in
                if let code = newValue {
                    isScanning = false
                    onScan(code)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

/// Wraps AVCaptureSession in a UIView for SwiftUI.
struct QRCameraPreview: UIViewRepresentable {
    @Binding var isScanning: Bool
    @Binding var scannedCode: String?
    @Binding var showPermissionDenied: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            context.coordinator.setupSession(in: view)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        context.coordinator.setupSession(in: view)
                    } else {
                        showPermissionDenied = true
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                showPermissionDenied = true
            }
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let parent: QRCameraPreview
        var captureSession: AVCaptureSession?

        init(parent: QRCameraPreview) {
            self.parent = parent
        }

        func setupSession(in view: UIView) {
            let session = AVCaptureSession()
            self.captureSession = session

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }

            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds

            DispatchQueue.main.async {
                view.layer.addSublayer(previewLayer)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard parent.isScanning,
                  let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = metadataObject.stringValue else {
                return
            }

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            parent.scannedCode = stringValue
            captureSession?.stopRunning()
        }
    }
}

#Preview {
    QRScannerView { code in
        print("Scanned: \(code)")
    }
}
