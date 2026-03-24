import ReplayKit
import Vision
import CoreImage

/// Layer 2 — ReplayKit Broadcast Upload Extension.
/// Only activated by the user when watching 抖音 or 微信公众号.
/// Captures screen frames at ~0.1 fps (one frame per 10 seconds),
/// runs Vision OCR, and shares results with the main app via App Group.
class SampleHandler: RPBroadcastSampleHandler {

    // App Group shared container
    private let appGroupID = "group.com.screenmind.app"
    private var lastProcessedDate: Date?
    private let processingInterval: TimeInterval = 10.0   // 1 frame per 10 seconds

    // MARK: - Broadcast lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Notify main app that Layer 2 is active
        writeToAppGroup(key: "layer2_active", value: "true")
    }

    override func broadcastFinished() {
        writeToAppGroup(key: "layer2_active", value: "false")
        writeToAppGroup(key: "latest_ocr_text", value: "")
    }

    override func broadcastPaused() {
        writeToAppGroup(key: "layer2_active", value: "paused")
    }

    override func broadcastResumed() {
        writeToAppGroup(key: "layer2_active", value: "true")
    }

    // MARK: - Sample processing

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        // Throttle: process at most once per 10 seconds
        if let last = lastProcessedDate,
           Date().timeIntervalSince(last) < processingInterval { return }
        lastProcessedDate = Date()

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        runOCR(on: imageBuffer)
    }

    // MARK: - OCR

    private func runOCR(on pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            self?.writeToAppGroup(key: "latest_ocr_text", value: text)
            self?.writeToAppGroup(key: "ocr_timestamp", value: "\(Date().timeIntervalSince1970)")
        }
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.recognitionLevel = .fast
        try? handler.perform([request])
    }

    // MARK: - App Group shared storage

    private func writeToAppGroup(key: String, value: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(value, forKey: key)
    }
}
