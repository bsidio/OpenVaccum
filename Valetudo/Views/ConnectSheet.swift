import SwiftUI
import UIKit

/// For anyone wiring the robot into something else: the request that starts what's picked.
struct ConnectSheet: View {
    let request: JobRequest
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(request.purpose)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if request.usesCoordinates {
                        Banner(text: "These coordinates can stop working if the floor plan changes.", tone: .neutral)
                    }
                    payload
                }
                .padding(Metric.gutter)
            }
            // Under the scrolling, so a long list of zones can't push it out of reach.
            .safeAreaInset(edge: .bottom) {
                copyButton
                    .padding(.horizontal, Metric.gutter)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .background(Theme.mist)
            .navigationTitle("Connect with Other Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var payload: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PUT \(request.path)")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.slate)
                .textSelection(.enabled)
            Text(request.text)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = request.text
            copied = true
            AccessibilityNotification.Announcement("Copied").post()
        } label: {
            Label(copied ? "Copied" : "Copy Payload", systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
