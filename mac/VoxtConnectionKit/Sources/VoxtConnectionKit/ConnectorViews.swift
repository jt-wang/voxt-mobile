import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The result next to a Connect button, in Settings and in the setup guide.
public struct ConnectFeedbackView: View {
    let feedback: ConnectorAppModel.ConnectFeedback
    public init(feedback: ConnectorAppModel.ConnectFeedback) { self.feedback = feedback }

    public var body: some View {
        Group {
            switch feedback {
            case .idle:
                EmptyView()
            case .waitingForApproval:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Click Allow in Voxt…")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Click Allow in Voxt…")
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Connecting…")
            case let .connected(text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            case let .failed(text):
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
        .accessibilityIdentifier("connectorConnectFeedback")
    }
}

/// The Add iPhone QR code, in Settings and in the setup guide.
public struct PairingQRCode: View {
    let code: ConnectorPairingCode
    var side: CGFloat
    public init(code: ConnectorPairingCode, side: CGFloat = 220) { self.code = code; self.side = side }

    public var body: some View {
        if let qrImage {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .padding(12)
                .background(.white)
                .accessibilityLabel("iPhone pairing QR code")
                .accessibilityIdentifier("connectorPairingQR")
        } else {
            Text("Could not draw the QR code. Cancel and try again.")
        }
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.url.absoluteString.utf8)
        filter.correctionLevel = "M"
        // Ten pixels per module, so the code stays sharp when a snapshot or a Retina screen redraws it.
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
