import CoreGraphics
import Foundation
import Observation
import Vision

/// Pulls the MPEG-1 elementary stream out of an MPEG-TS byte stream.
/// Valetudo's camera feed is MPEG-1, which iOS can't decode, so `pl_mpeg` does that part.
struct TransportDemuxer {
    private var carry = Data()
    private var videoPID: Int?

    mutating func feed(_ data: Data) -> Data {
        carry.append(data)
        var output = Data()
        var i = carry.startIndex
        carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var o = 0
            while o + 188 <= b.count {
                guard b[o] == 0x47 else {
                    o += 1
                    continue
                }
                let start = b[o + 1] & 0x40 != 0
                let pid = (Int(b[o + 1]) & 0x1F) << 8 | Int(b[o + 2])
                let adaptation = (b[o + 3] >> 4) & 0x3
                var p = o + 4
                if adaptation == 2 || adaptation == 0 {
                    o += 188
                    continue
                }
                if adaptation == 3 { p += 1 + Int(b[p]) }
                let end = o + 188
                if p < end {
                    if start, p + 9 <= end, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1, b[p + 3] & 0xF0 == 0xE0 {
                        // A video PES header marks this PID as the camera.
                        videoPID = pid
                        p += 9 + Int(b[p + 8])
                    }
                    if pid == videoPID, p < end {
                        output.append(b.baseAddress! + p, count: end - p)
                    }
                }
                o += 188
            }
            i = carry.startIndex + o
        }
        carry.removeSubrange(carry.startIndex..<i)
        return output
    }
}

/// Decodes frames on a background queue. Only ever touched from that queue.
private final class FrameDecoder {
    private let buffer = plm_buffer_create_for_appending(256 * 1024)
    private let video: OpaquePointer?
    private var pixels: [UInt8] = []

    init() {
        video = plm_video_create_with_buffer(buffer, 0)
        plm_video_set_no_delay(video, 1)
    }

    deinit {
        plm_video_destroy(video)
        plm_buffer_destroy(buffer)
    }

    /// Returns the newest complete frame, dropping any older ones to stay live.
    func decode(_ data: Data) -> CGImage? {
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                _ = plm_buffer_write(buffer, UnsafeMutablePointer(mutating: base), raw.count)
            }
        }
        var newest: UnsafeMutablePointer<plm_frame_t>?
        while let frame = plm_video_decode(video) { newest = frame }
        guard let frame = newest else { return nil }

        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let stride = width * 4
        if pixels.count != stride * height { pixels = [UInt8](repeating: 255, count: stride * height) }
        pixels.withUnsafeMutableBufferPointer { plm_frame_to_rgba(frame, $0.baseAddress, Int32(stride)) }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Plays Valetudo's camera stream.
@MainActor @Observable
final class CameraStream: NSObject {
    enum Phase: Equatable { case connecting, live, failed(String) }

    /// Valetudo backs off for a minute after the camera fails, so retrying sooner can't help.
    static let noVideo = "No video from the robot. Some robots can only stream while they're away from the dock."
    /// Valetudo waits this long after the camera fails before it will try the camera again.
    static let backoff: TimeInterval = 61

    private(set) var frame: CGImage?
    private(set) var phase: Phase = .connecting

    private let request: URLRequest?
    private let queue = DispatchQueue(label: "camera.decode")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var stopped = true
    private var receivedFrame = false
    private var reconnect: Task<Void, Never>?
    private var failedAt: Date?
    @ObservationIgnored private nonisolated(unsafe) var demuxer = TransportDemuxer()
    @ObservationIgnored private nonisolated(unsafe) var decoder: FrameDecoder?

    init(client: Client) {
        request = try? client.streamRequest("\(Cap.root)/\(Cap.camera)/stream")
    }

    func start() {
        guard stopped else { return }
        guard let request else {
            phase = .failed("This robot's address isn't valid.")
            return
        }
        reconnect?.cancel()
        reconnect = nil
        failedAt = nil
        stopped = false
        receivedFrame = false
        phase = .connecting
        queue.sync {
            demuxer = TransportDemuxer()
            decoder = FrameDecoder()
        }
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    /// True when the robot sent no video at all, which on some robots means it's still docked.
    var hasNoVideo: Bool { phase == .failed(Self.noVideo) }

    /// The robot has just left its dock: try again as soon as Valetudo allows, so the owner
    /// doesn't have to notice and tap Try Again.
    func retryAfterLeavingDock() {
        guard hasNoVideo else { return }
        let wait = max(0, Self.backoff - Date().timeIntervalSince(failedAt ?? .distantPast))
        phase = .connecting
        reconnect?.cancel()
        reconnect = Task {
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self.start() }
        }
    }

    func stop() {
        reconnect?.cancel()
        reconnect = nil
        endConnection()
    }

    private func endConnection() {
        stopped = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func finished(status: Int?, error: Error?) {
        guard !stopped else { return }
        let hadVideo = receivedFrame
        endConnection()
        failedAt = Date()
        switch status {
        case 403:
            phase = .failed("The robot has stopped the video.")
        case 503:
            phase = .failed(Self.noVideo)
        default:
            guard hadVideo else {
                phase = .failed(Self.noVideo)
                return
            }
            // The stream was working, so this is most likely a network blip.
            phase = .connecting
            reconnect = Task {
                try? await Task.sleep(for: .seconds(2))
                // stop() cancels this, so video can't resume after the screen has gone.
                if !Task.isCancelled { self.start() }
            }
        }
    }
}

extension CameraStream: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let video = demuxer.feed(data)
        guard !video.isEmpty, let image = decoder?.decode(video) else { return }
        let box = ImageBox(image: image)
        Task { @MainActor in
            guard !self.stopped else { return }
            self.frame = box.image
            self.receivedFrame = true
            self.phase = .live
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in self.finished(status: status, error: error) }
    }
}

private struct ImageBox: @unchecked Sendable { let image: CGImage }

/// On-device image understanding with Apple's Vision framework. Nothing leaves the phone.
enum ImageLabeler {
    struct Finding: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let confidence: Float
    }

    /// Broad categories that are true of almost any room, so they tell you nothing.
    private static let vagueLabels: Set<String> = [
        "structure", "material", "conveyance", "textile", "wood_processed", "art",
        "decoration", "frame", "machine", "furniture", "room", "indoor"
    ]

    /// Scene labels, plus people and animals, which are worth calling out in a home.
    static func analyze(_ image: CGImage) async -> [Finding] {
        await Task.detached(priority: .utility) {
            let classify = VNClassifyImageRequest()
            let animals = VNRecognizeAnimalsRequest()
            let people = VNDetectHumanRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([classify, animals, people])

            var findings: [Finding] = []
            if let count = people.results?.count, count > 0 {
                findings.append(Finding(label: count == 1 ? "Person" : "\(count) people", confidence: 1))
            }
            for result in animals.results ?? [] {
                if let label = result.labels.first {
                    findings.append(Finding(label: label.identifier, confidence: label.confidence))
                }
            }
            // The general classifier is vague at floor level, so stay quiet unless it's confident.
            let scene = (classify.results ?? [])
                .filter { $0.confidence >= 0.5 && !vagueLabels.contains($0.identifier) }
                .prefix(3)
                .map { Finding(label: $0.identifier.replacingOccurrences(of: "_", with: " ").capitalized, confidence: $0.confidence) }
            return findings + scene
        }.value
    }
}
