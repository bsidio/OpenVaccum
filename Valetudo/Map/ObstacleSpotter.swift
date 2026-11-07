import UIKit

/// Names obstacles the robot only called "Obstacle", by looking at their photos with Vision.
/// This happens on the phone. Photos are dropped once checked, and only the name is kept.
@MainActor
final class ObstacleSpotter {
    private static let attempts = 3

    /// Names by obstacle id, for this session.
    private(set) var recognized: [String: String] = [:]
    private var tries: [String: Int] = [:]
    private var checked = Set<String>()
    private var looking = false
    private let analyze: (CGImage) async -> [ImageLabeler.Finding]

    init(analyze: @escaping (CGImage) async -> [ImageLabeler.Finding] = ImageLabeler.analyze) {
        self.analyze = analyze
    }

    /// Checks any new photos one at a time, so a map full of obstacles can't flood the robot.
    /// `found` runs after each new name.
    func look(at obstacles: [FloorPlan.Obstacle], fetch: @escaping (String) async throws -> Data, found: @escaping () -> Void) {
        let waiting = obstacles.filter {
            $0.isUnnamed && $0.hasPhoto && !checked.contains($0.id) && tries[$0.id, default: 0] < Self.attempts
        }
        guard !looking, !waiting.isEmpty else { return }
        looking = true
        Task {
            defer { looking = false }
            for obstacle in waiting {
                tries[obstacle.id, default: 0] += 1
                guard let data = try? await fetch(obstacle.id) else { continue }
                checked.insert(obstacle.id)
                guard let image = UIImage(data: data)?.cgImage else { continue }
                if let name = Self.name(in: await analyze(image)) {
                    recognized[obstacle.id] = name
                    found()
                }
            }
        }
    }

    /// The most confident finding that has an icon. Anything else isn't worth showing on a map.
    static func name(in findings: [ImageLabeler.Finding]) -> String? {
        findings.first { FloorPlan.Obstacle.symbol(forLabel: $0.label) != FloorPlan.Obstacle.genericSymbol }?.label
    }
}
