import CoreGraphics
import Foundation

/// A job as the robot's API takes it. The app sends these and `ConnectSheet` shows them, so
/// what someone copies into another application is exactly what the app would have sent.
struct JobRequest: Identifiable {
    let id = UUID()
    let capability: String
    let body: [String: Any]
    let purpose: String
    /// Zones and spots are coordinates on this map, so a new map can leave them pointing elsewhere.
    let usesCoordinates: Bool

    var path: String { "/api/v2\(Cap.root)/\(capability)" }

    /// Indented, and with its keys in a steady order so two looks at one job read the same.
    var text: String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func rooms(_ ids: [String], passes: Int, customOrder: Bool) -> JobRequest {
        JobRequest(capability: Cap.rooms,
                   body: ["action": "start_segment_action", "segment_ids": ids,
                          "iterations": passes, "customOrder": customOrder],
                   purpose: "To clean \(ids.count == 1 ? "this room" : "these rooms") with the current settings "
                       + "over MQTT or REST, use this payload.",
                   usesCoordinates: false)
    }

    /// `zones` are in map pixels, which the robot needs as centimetres.
    static func zones(_ zones: [CGRect], passes: Int, pixelSize: CGFloat) -> JobRequest {
        func point(_ x: CGFloat, _ y: CGFloat) -> [String: Int] { centimetres(CGPoint(x: x, y: y), pixelSize) }
        let body: [[String: Any]] = zones.map { z in
            ["points": [
                "pA": point(z.minX, z.minY), "pB": point(z.maxX, z.minY),
                "pC": point(z.maxX, z.maxY), "pD": point(z.minX, z.maxY)
            ]]
        }
        return JobRequest(capability: Cap.zones,
                          body: ["action": "clean", "zones": body, "iterations": passes],
                          purpose: "To clean \(zones.count == 1 ? "this area" : "these areas") with the current settings "
                              + "over MQTT or REST, use this payload.",
                          usesCoordinates: true)
    }

    /// `point` is in map pixels.
    static func go(to point: CGPoint, pixelSize: CGFloat) -> JobRequest {
        JobRequest(capability: Cap.goTo,
                   body: ["action": "goto", "coordinates": centimetres(point, pixelSize)],
                   purpose: "To send the robot to this spot over MQTT or REST, use this payload.",
                   usesCoordinates: true)
    }

    private static func centimetres(_ point: CGPoint, _ pixelSize: CGFloat) -> [String: Int] {
        ["x": Int((point.x * pixelSize).rounded()), "y": Int((point.y * pixelSize).rounded())]
    }
}
