import SwiftUI

/// The robot's map as a file, for use with other tools, named the way Valetudo names its exports.
struct MapExport: Identifiable {
    let file: URL
    var id: URL { file }

    /// The bytes come straight from the robot, because `RawMap` only keeps what the app draws.
    static func fetch(from client: Client) async throws -> MapExport {
        async let map = client.getData("/robot/state/map")
        async let about = client.getJSON("/valetudo")
        let (data, details) = try await (map, about)
        let time = Date.now.ISO8601Format().replacingOccurrences(of: "Z", with: "")
        let name = ["ValetudoMapExport", details["systemId"] as? String, time].compactMap { $0 }.joined(separator: "-")
        let safeName = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        let file = FileManager.default.temporaryDirectory.appending(path: "\(safeName).json")
        try data.write(to: file, options: .atomic)
        return MapExport(file: file)
    }
}

/// The system share sheet, which also offers Save to Files.
struct MapExportSheet: UIViewControllerRepresentable {
    let file: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
