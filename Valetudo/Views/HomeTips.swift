import SwiftUI
import TipKit

/// First-run help for the plan. The hold tip waits for this one, so they appear one at a time.
struct RoomTip: Tip {
    @Parameter(.transient) static var mapIsReady: Bool = false

    var followsOrder = true

    var title: Text { Text("Tap a room to pick it") }

    var message: Text? {
        Text(followsOrder ? "Tap more to set the order. Nothing moves until you tap Clean."
                          : "Tap more to add them. Nothing moves until you tap Clean.")
    }

    var rules: [Rule] {
        #Rule(Self.$mapIsReady) { $0 == true }
    }
}

struct HoldTip: Tip {
    static let earned = Tips.Event(id: "holdTipEarned")
    @Parameter(.transient) static var canShow: Bool = false

    var hasZones = true

    var title: Text { Text("Touch and hold the floor") }

    var message: Text? {
        Text(hasZones ? "Lift to drop a pin. Keep dragging to mark a zone."
                      : "Lift to drop a pin, then drag it to move.")
    }

    var rules: [Rule] {
        #Rule(Self.$canShow) { $0 == true }
        #Rule(Self.earned) { $0.donations.count > 0 }
    }
}

@MainActor
enum HomeTips {
    private static var configured = false
    private static var canPin = false
    private static var roomTipIsUp = false
    private static var showing3D = false

    /// TipKit throws if it's configured twice, and Home can appear more than once.
    static func configure() {
        guard !configured else { return }
        configured = true
        try? Tips.configure()
    }

    static func update(_ rules: PickRules, hasPlan: Bool) {
        RoomTip.mapIsReady = hasPlan && rules.rooms && !rules.working && !rules.paused
        canPin = hasPlan && rules.canPin
        refreshHoldTip()
    }

    /// Holding only works on the flat plan, so the hold tip waits for it.
    static func planIs3D(_ on: Bool) {
        showing3D = on
        refreshHoldTip()
    }

    static func followRoomTip() async {
        for await status in RoomTip().statusUpdates {
            roomTipIsUp = status == .available
            refreshHoldTip()
        }
    }

    /// Never shown to a robot that can't do what it teaches, and never alongside the room tip.
    private static func refreshHoldTip() {
        HoldTip.canShow = canPin && !roomTipIsUp && !showing3D
    }
}
