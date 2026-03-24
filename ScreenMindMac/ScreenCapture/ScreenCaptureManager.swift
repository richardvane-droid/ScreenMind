import Foundation
import ScreenCaptureKit
import Vision
import CoreImage

/// Continuously captures the screen using ScreenCaptureKit and runs Vision OCR
/// to extract text. Invokes `onFrame` callback with the extracted text.
final class ScreenCaptureManager: NSObject, @unchecked Sendable {

    // MARK: - Callback
    var onFrame: ((String) -> Void)?

    // MARK: - Private state
    private var stream: SCStream?
    private var samplingInterval: Double = 30.0   // seconds between captures
    private var lastCaptureDate: Date?

    // App filter: bundle IDs to monitor or skip
    var filterMode: FilterMode = .blacklist
    var filteredBundleIDs: Set<String> = []

    // MARK: - Start / Stop

    func start() {
        Task { await setupAndStart() }
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // MARK: - Setup

    private func setupAndStart() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width / 2)     // 50% resolution — enough for OCR
            config.height = Int(display.height / 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // max 1 fps
            config.queueDepth = 2

            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
            try await stream?.startCapture()
        } catch {
            // Screen Recording permission denied or macOS < 13 — log and bail
            print("[ScreenCaptureManager] Failed to start: \(error)")
        }
    }

    // MARK: - OCR

    private func runOCR(on pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            self?.onFrame?(text)
        }
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.recognitionLevel = .fast    // Fast mode trades accuracy for speed
        request.usesLanguageCorrection = false
        try? handler.perform([request])
    }

    // MARK: - Sampling filter

    private func shouldCapture() -> Bool {
        guard let last = lastCaptureDate else { return true }
        return Date().timeIntervalSince(last) >= samplingInterval
    }

    // MARK: - App filter

    private func isFrontAppAllowed() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        switch filterMode {
        case .whitelist:
            return filteredBundleIDs.contains(bundleID)
        case .blacklist:
            return !filteredBundleIDs.contains(bundleID)
        }
    }

    enum FilterMode { case whitelist, blacklist }
}

// MARK: - SCStreamOutput

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              shouldCapture(),
              isFrontAppAllowed() else { return }
        lastCaptureDate = Date()
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        runOCR(on: imageBuffer)
    }
}
