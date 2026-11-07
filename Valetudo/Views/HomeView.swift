import SwiftUI
import TipKit

struct HomeView: View {
    /// Fit sits 8pt above the plan's inset, which already starts 10pt above the floating column.
    private static let fitLift = PlanColumn.reserved - 10

    @Environment(RobotStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var touches = PlanTouches()
    @State private var obstacle: FloorPlan.Obstacle?
    @State private var showRooms = false
    @State private var barHeight = Metric.barHeight
    @State private var planBottom: CGFloat = 0
    @State private var sheetInset: CGFloat = 0
    @State private var showControls = false
    @State private var showAlerts = false
    @State private var showEditor = false
    @State private var showDrive = false
    @State private var showCamera = false
    @State private var showCoverage = false
    @State private var showLogin = false
    @State private var confirmMapping = false
    @State private var export: MapExport?
    @State private var exporting = false
    @AppStorage("planIn3D") private var in3D = false

    /// Body may only read `picks.rooms`. Zones, the draft and the pin change on every frame
    /// of a drag, and reading them here would redraw the map's filters each time.
    private var picks: Picks { touches.picks }

    private var canDrive: Bool { store.has(Cap.drive) || store.has(Cap.driveSimple) }

    private var canEdit: Bool {
        // Backups live in the editor, and an empty plan is exactly when they're wanted.
        if store.has(Cap.mapSnapshot) { return true }
        guard store.plan?.isEmpty == false else { return false }
        return [Cap.segmentEdit, Cap.segmentRename, Cap.segmentMaterial, Cap.restrictions, Cap.annotations, Cap.mapReset]
            .contains(where: store.has)
    }

    /// Valetudo's own rule: while streaming is off, the camera isn't mentioned at all.
    private var showsCamera: Bool { store.has(Cap.camera) && store.cameraEnabled }

    private var hasMore: Bool {
        canEdit || canDrive || showsCamera || store.has(Cap.mappingPass) || hasPlan
    }

    private var hasPlan: Bool { store.plan?.isEmpty == false }

    private var alertsLabel: String {
        switch store.openEvents.count {
        case 0: return "Alerts"
        case 1: return "1 alert"
        case let count: return "\(count) alerts"
        }
    }

    /// The plan's rooms, or the robot's own list if the plan failed to load.
    private var roomChoices: [RoomChoice] {
        if let rooms = store.plan?.rooms, hasPlan {
            return rooms.map { RoomChoice(id: $0.id, name: $0.name, palette: $0.palette) }
        }
        return store.rooms.map { RoomChoice(id: $0.id, name: $0.title) }
    }

    private var planInsets: EdgeInsets {
        EdgeInsets(top: 12, leading: 14, bottom: max(barHeight + 20, sheetInset + 12), trailing: 14)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the plan, or the 3D view would cut off the shadows of these buttons.
            header.zIndex(1)
            planArea
        }
        .background(Theme.mist.ignoresSafeArea())
        .sheet(isPresented: $showControls) { ControlsSheet() }
        .sheet(isPresented: $showAlerts) { AlertsSheet() }
        .sheet(item: homeObstacle) { ObstacleSheet(obstacle: $0) }
        .sheet(isPresented: $showRooms, onDismiss: { sheetInset = 0 }) { roomsSheet }
        .fullScreenCover(isPresented: $showEditor) { MapEditorView() }
        .fullScreenCover(isPresented: $showDrive) { DriveView() }
        .fullScreenCover(isPresented: $showCamera) { CameraView() }
        .fullScreenCover(isPresented: $showCoverage) { coverage }
        .sheet(isPresented: $showLogin) { SignInSheet() }
        .sheet(item: $export) { MapExportSheet(file: $0.file).presentationDetents([.medium, .large]) }
        .confirmationDialog("Start a mapping pass?", isPresented: $confirmMapping, titleVisibility: .visible) {
            Button("Run a Mapping Pass") { store.startMappingPass() }
        } message: {
            Text("The robot drives around your home to make a new floor plan. If it already has one, this can replace it.")
        }
        .onAppear(perform: connectTouches)
        // Signing in again brings a new store, and these closures would keep the old one alive.
        .onChange(of: ObjectIdentifier(store)) { connectTouches() }
        .onChange(of: PickRules(store), initial: true) { _, rules in
            picks.rules = rules
            HomeTips.update(rules, hasPlan: hasPlan)
        }
        .onChange(of: hasPlan) { _, hasPlan in HomeTips.update(picks.rules, hasPlan: hasPlan) }
        .onChange(of: store.state.isActive) { _, active in robotChanged(active: active) }
        .onChange(of: store.planRevision) { if store.plan != nil { touches.planChanged(to: store.plan) } }
        .onChange(of: roomChoices) { old, new in roomsChanged(from: old, to: new) }
        .onChange(of: showRooms) { _, open in touches.sheetIsOpen = open }
        .onChange(of: in3D, initial: true) { _, on in
            picks.planIsZoomed = false
            HomeTips.planIs3D(on)
        }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
        .accessibilityAction(.magicTap) { if store.state.canPause, store.has(Cap.basic) { store.pause() } }
        .accessibilityAction(.escape) { withAnimation(PickMotion.settle) { picks.clear() } }
        .task {
            HomeTips.configure()
            await HomeTips.followRoomTip()
        }
    }

    private func connectTouches() {
        touches.roomName = store.roomName
        // Only the binding: capturing this view would have `touches` keeping itself and the store alive.
        let photo = $obstacle
        touches.onObstacle = { photo.wrappedValue = $0 }
        touches.onRoomPicked = { RoomTip().invalidate(reason: .actionPerformed) }
        touches.onHeld = { HoldTip().invalidate(reason: .actionPerformed) }
        touches.onFailedDrag = { HoldTip.earned.sendDonation() }
    }

    // Only one sheet can be up at a time, so with the Rooms sheet open it presents the photo itself.
    private var homeObstacle: Binding<FloorPlan.Obstacle?> {
        Binding(get: { showRooms ? nil : obstacle }, set: { obstacle = $0 })
    }

    private var sheetObstacle: Binding<FloorPlan.Obstacle?> {
        Binding(get: { showRooms ? obstacle : nil }, set: { obstacle = $0 })
    }

    private var roomsSheet: some View {
        RoomsSheet(touches: touches, rooms: roomChoices, obstacle: sheetObstacle, onGo: go) { top in
            if let top { sheetInset = max(0, planBottom - top) }
        }
    }

    // MARK: Status

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.sentence)
                        .font(.largeTitle.bold())
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: store.sentence)
                        .accessibilityAddTraits(.isHeader)
                    if store.connected, let level = store.state.battery {
                        BatteryLabel(level: level, charging: store.state.charging)
                    }
                }
                Spacer(minLength: 0)
                GlassIconButton(symbol: store.openEvents.isEmpty ? "bell" : "bell.badge.fill", label: alertsLabel,
                                tint: store.openEvents.isEmpty ? Theme.ink : Theme.cobalt) { showAlerts = true }
                if hasMore { moreMenu }
            }
            ForEach(store.notices) { notice in
                Banner(text: notice.text, tone: notice.tone, action: action(for: notice))
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
        .animation(.snappy(duration: 0.25), value: store.notices)
    }

    private func action(for notice: RobotStore.Notice) -> (() -> Void)? {
        if notice.opensLogin { return { showLogin = true } }
        return notice.opensControls ? { showControls = true } : nil
    }

    private var moreMenu: some View {
        Menu {
            if canEdit {
                Button { showEditor = true } label: { Label("Edit Floor Plan", systemImage: "pencil.and.ruler") }
            }
            if canDrive {
                Button { showDrive = true } label: { Label("Drive Manually", systemImage: "gamecontroller") }
            }
            if showsCamera {
                Button { showCamera = true } label: { Label("Camera", systemImage: "video") }
            }
            if store.has(Cap.mappingPass) {
                Button { confirmMapping = true } label: { Label("Run a Mapping Pass", systemImage: "map") }
            }
            // A robot with an editor has these in there.
            if hasPlan, !canEdit {
                Button { showCoverage = true } label: { Label("Robot Coverage Map", systemImage: "scribble.variable") }
                Button(action: exportMap) { Label("Export Map Data", systemImage: "square.and.arrow.up") }
                    .disabled(exporting)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                .contentShape(Circle())
                .glass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("More")
    }

    private var coverage: some View {
        NavigationStack {
            CoverageMapView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showCoverage = false } }
            }
        }
    }

    private func exportMap() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                export = try await MapExport.fetch(from: store.client)
            } catch {
                store.report(error)
            }
        }
    }

    // MARK: Plan

    private var planArea: some View {
        plan
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) { planBottom = $0 }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        PlanColumn(touches: touches, hasPlan: hasPlan, in3D: $in3D) { showRooms = true }
                        RoomTipSlot(picks: picks, followsOrder: store.roomOrderSupported)
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { [picks] in picks.floatHeight = $0 }
                    // Until the robot has answered once, there's nothing to offer.
                    if !store.capabilities.isEmpty {
                        HomeBar(picks: picks, height: $barHeight, onGo: go) { showControls = true }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                NoteSlot(picks: picks, barTop: barHeight + 18, sheetInset: sheetInset)
            }
    }

    @ViewBuilder private var plan: some View {
        if let plan = store.plan, !plan.isEmpty {
            let active = store.connected && store.state.isActive
            ZStack {
                if in3D {
                    DollhouseView(plan: plan, picked: picks.rooms, numbered: store.roomOrderSupported, active: active,
                                  paused: store.connected && store.state.isUnfinished,
                                  bottomInset: planInsets.bottom, resetLift: Self.fitLift,
                                  onRoom: touches.pick(room:), onObstacle: { touches.onObstacle($0) })
                        .transition(.opacity)
                } else {
                    flatPlan(plan, active: active).transition(.opacity)
                }
            }
            // The last map the robot sent, which may be out of date until it answers again.
            .opacity(store.connected ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.25), value: in3D)
        } else if !store.connected || store.mapLoadFailed {
            planFailed
        } else if store.hasLoaded {
            FirstPlanGuide(bottomInset: planInsets.bottom) { confirmMapping = true }
        } else {
            ProgressView("Loading floor plan")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func flatPlan(_ plan: FloorPlan, active: Bool) -> some View {
        let insets = planInsets
        return PlanCanvas(
            plan: plan, selected: Set(picks.rooms), active: active,
            paused: store.connected && store.state.isUnfinished, insets: insets,
            touches: touches, order: store.roomOrderSupported ? picks.rooms : [],
            pickLayer: { [touches] t in AnyView(PickLayer(touches: touches, plan: plan, t: t, insets: insets)) },
            fitLift: Self.fitLift)
    }

    /// The banner above says why when the robot isn't answering, so this only offers the way out.
    private var planFailed: some View {
        ContentUnavailableView {
            Label("Can't Load the Floor Plan", systemImage: "map")
        } description: {
            if store.connected { Text("The robot is answering, but its map didn't arrive.") }
        } actions: {
            if store.needsLogin {
                Button("Sign In") { showLogin = true }
            } else {
                Button("Try Again") { Task { await store.retry() } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Changes from outside

    /// The robot started without the primary: a schedule, or another app. Our own start is
    /// ignored here because its picks are cleared when the robot's answer comes back.
    private func robotChanged(active: Bool) {
        guard active, !picks.sending, picks.kind != .nothing else { return }
        picks.robotStartedAlone(cleaning: store.state.status == "cleaning")
        showRooms = false
    }

    private func roomsChanged(from old: [RoomChoice], to new: [RoomChoice]) {
        let gone = picks.keepRooms(in: Set(new.map(\.id)))
        let names = gone.compactMap { id in old.first { $0.id == id }?.name }
        // A new store after signing in again starts with no rooms, which isn't the plan changing.
        if !names.isEmpty, store.hasLoaded { picks.say(PickNote.gone(names)) }
    }

    private func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .background: picks.enteredBackground()
        case .active: picks.becameActive()
        default: break
        }
    }

    // MARK: Starting

    private func go() {
        guard !picks.sending, let job = picks.job(on: store.plan) else { return }
        picks.beginSending()
        Task {
            if await picks.deliver(job, to: store) {
                finished(job)
            } else {
                robotChanged(active: store.state.isActive)
            }
        }
    }

    private func finished(_ job: Picks.Job) {
        PlanHaptic.success.play()
        showRooms = false
        if job != .start { HoldTip.earned.sendDonation() }
    }
}

/// The first-run tip. It steps aside when it would be in the way or wrong: zoomed in it would
/// cover Fit, and with a pin or zones a tap on a room no longer picks it. It's a view of its
/// own so that reading these doesn't rebuild the plan.
private struct RoomTipSlot: View {
    let picks: Picks
    let followsOrder: Bool

    /// By kind, because a first stretch has no pin and no zone yet, and the tip would flash back.
    private var isInTheWay: Bool { picks.planIsZoomed || picks.kind == .pin || picks.kind == .zones }

    var body: some View {
        if !isInTheWay {
            TipView(RoomTip(followsOrder: followsOrder), arrowEdge: .bottom)
                // Any larger and the tip covers the rooms it's telling you to tap.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.horizontal, 14)
        }
    }
}

/// The note slot sits 8pt above the bar, and above anything floating there. It's a view of
/// its own so a note appearing doesn't rebuild the plan.
private struct NoteSlot: View {
    let picks: Picks
    let barTop: CGFloat
    let sheetInset: CGFloat

    private var bottom: CGFloat {
        if sheetInset > 0 { return sheetInset + 8 }
        if picks.planIsZoomed { return barTop + PlanColumn.reserved * 2 }
        return barTop + (picks.floatHeight > 0 ? picks.floatHeight + 8 : 0)
    }

    var body: some View {
        ZStack {
            if let note = picks.note {
                BarNote(text: note.text) { picks.dismiss(note) }
                    .id(note.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.bottom, bottom)
        .animation(.snappy(duration: 0.22), value: picks.note)
    }
}

private struct BatteryLabel: View {
    let level: Int
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var body: some View {
        Label("\(level)%", systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(level < 20 && !charging ? Theme.rose : Theme.slate)
            .contentTransition(.numericText())
            .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
    }
}

extension RobotStore {
    /// Some robots only draw a plan on a mapping pass, so a clean wouldn't help.
    var planAdvice: String {
        has(Cap.mappingPass) ? "Run a mapping pass and the robot will draw one." : "Run a clean and the robot will draw one."
    }
}

/// What the robot saw, with Apple's on-device labels alongside.
struct ObstacleSheet: View {
    let obstacle: FloorPlan.Obstacle
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var findings: [ImageLabeler.Finding] = []
    @State private var failed = false
    @State private var attempt = 0

    private var photosOn: Bool { store.switches[.obstaclePhotos] == true }

    /// The title already says what this is, so it isn't listed again.
    private var alsoSeen: [String] {
        findings.map(\.label).filter { $0 != obstacle.recognized }
    }

    /// Why there's no photo, from the one thing the owner can change to the one they can't.
    private var noPhotoReason: String {
        if !store.has(Cap.obstaclePhotos) { return "This robot doesn't save obstacle photos." }
        if store.switches[.obstaclePhotos] == false { return "Turn on Save Obstacle Photos in Settings to keep them from now on." }
        return failed ? "The photo didn't arrive. Check that the robot is on, then try again."
                      : "The robot didn't save a photo of this obstacle."
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
                        .accessibilityLabel("Photo of the obstacle")
                    if !alsoSeen.isEmpty {
                        Label("Also seen: " + alsoSeen.joined(separator: ", "), systemImage: "eye")
                            .font(.subheadline)
                            .foregroundStyle(Theme.slate)
                    }
                } else if obstacle.hasPhoto, store.switches[.obstaclePhotos] == nil, !failed {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if !obstacle.hasPhoto || !photosOn || failed {
                    ContentUnavailableView {
                        Label("No Photo", systemImage: "photo")
                    } description: {
                        Text(noPhotoReason)
                    } actions: {
                        if failed {
                            Button("Try Again") {
                                failed = false
                                attempt += 1
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
                if obstacle.recognized != nil {
                    Text("Recognized on this phone. The robot called it \(obstacle.label).")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                }
                Spacer(minLength: 0)
            }
            .padding(Metric.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle(obstacle.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: [attempt, photosOn ? 1 : 0]) {
                guard obstacle.hasPhoto, photosOn else { return }
                do {
                    let data = try await store.client.getData("\(Cap.root)/\(Cap.obstaclePhotos)/img/\(obstacle.id)")
                    guard let decoded = UIImage(data: data) else {
                        failed = true
                        return
                    }
                    image = decoded
                    if let cg = decoded.cgImage { findings = await ImageLabeler.analyze(cg) }
                } catch is CancellationError {
                } catch {
                    failed = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
