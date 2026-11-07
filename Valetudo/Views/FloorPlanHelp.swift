import SwiftUI

/// Valetudo's help for each part of the floor plan editor, in plainer words.
struct FloorPlanHelp: View {
    enum Topic {
        case rooms, noGo, annotations
    }

    private struct Entry: Identifiable {
        var id: String { title }
        let title: String
        let text: String
    }

    let topic: Topic
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch topic {
        case .rooms: return "Rooms"
        case .noGo: return "No-Go Zones"
        case .annotations: return "Annotations"
        }
    }

    private var entries: [Entry] {
        switch topic {
        case .rooms:
            return roomEntries
        case .noGo:
            return [
                Entry(title: "What These Do",
                      text: "Walls and no-go zones keep the robot out of a place. No-mop zones only keep it out while it's mopping. Not every robot offers each of these, and most limit how many you can add."),
                Entry(title: "Don't Rely on Them Alone",
                      text: "A robot can lose track of where it is, and it then ignores these limits until it finds its place again. Don't let them be the only thing preventing damage."),
                Entry(title: "Saving",
                      text: "Nothing reaches the robot until you save. This screen also won't pick up changes made elsewhere until you choose Refresh in the menu.")
            ]
        case .annotations:
            return [
                Entry(title: "What These Do",
                      text: "Annotations tell the robot about things it might not work out by itself. Not every robot offers each of these."),
                Entry(title: "Thresholds",
                      text: "Something the robot sees as an obstacle is really a step it can cross if it tries harder."),
                Entry(title: "Ramps",
                      text: "There's a route the robot can take to reach a certain area. The arrows show the ramp's direction."),
                Entry(title: "Curtains",
                      text: "What looks like an obstacle isn't one, and the robot can drive straight into it.")
            ]
        }
    }

    /// Splitting and joining only come up on robots that can do them.
    private var roomEntries: [Entry] {
        var list = [
            Entry(title: "What Rooms Are",
                  text: "The robot divides your floor plan into rooms by itself, so you can clean just the ones you choose. They don't have to be real rooms. One could be the area around a dining table."),
            Entry(title: "If You See No Rooms",
                  text: "Let the robot finish a full clean and return to its dock by itself, which is usually when it works out the rooms. Some robots also need Keep the Floor Plan Between Runs turned on first.")
        ]
        if store.has(Cap.segmentEdit) {
            list.insert(Entry(title: "If a Split Doesn't Work",
                              text: "Draw the line across the whole room, not just part of it. Lining it up exactly between two walls often stops it working. Some layouts need a few splits, then joining some of the parts back together."),
                        at: 1)
            list.append(Entry(title: "Deleting a Room",
                              text: "Rooms can't be deleted, but you can join one into the room next to it."))
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            GroupTitle(entry.title)
                            Text(entry.text)
                                .font(.subheadline)
                                .foregroundStyle(Theme.slate)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Metric.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.mist.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
