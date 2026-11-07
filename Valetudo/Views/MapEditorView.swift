import SwiftUI

private enum EditMode: String, CaseIterable, Identifiable {
    case rooms = "Rooms", limits = "No-Go", notes = "Annotations"
    var id: String { rawValue }
}

/// What the floating panel shows. One case per state, so it can never sit between two.
private enum PanelState: Equatable {
    case unsupported, undocked, roomHint, oneRoom(String), twoRooms, splitting(hasLine: Bool)
    case loading, failed, addShapes, drawing(PlanShape.Kind), shape(UUID)
}

private enum LoadState {
    case loading, ready, failed
}

/// Where someone was heading when unsaved changes stopped them.
private enum Exit {
    case close, mode(EditMode), refresh
}

private struct ShapesRequest: Hashable {
    let mode: EditMode
    let attempt: Int
}

private struct Backup: Identifiable {
    let id: String
    let number: Int
    let date: Date?

    var dateText: String? { date?.formatted(date: .abbreviated, time: .shortened) }
}

/// What a finger is holding, and what to put back if it turns out to be a pinch.
private struct ShapeGrab {
    let grip: ShapeGrip
    let original: PlanShape
    let scale: CGFloat
    let wasDirty: Bool
    var moved = false
}

/// What the robot last accepted. It only reports a save once its next map arrives, so for a
/// moment a reload would bring back the old list, and saving that would undo the change.
private struct SavedShapes {
    let mode: EditMode
    let shapes: [PlanShape]
    let time = Date.now

    var isFresh: Bool { Date.now.timeIntervalSince(time) < 10 }
}

/// The transform the canvas last drew with, for working out what a touch landed on. The canvas
/// owns zooming and panning, and this is a class because recording it mustn't redraw anything.
private final class CanvasReading {
    var transform: PlanTransform?
}

private extension PlanShape.Kind {
    var tileTitle: String {
        switch self {
        case .wall: return "Wall"
        case .noGo: return "No-Go Zone"
        case .noMop: return "No-Mop Zone"
        case .threshold: return "Threshold"
        case .curtain: return "Curtain"
        case .ramp: return "Ramp"
        }
    }

    var symbol: String {
        switch self {
        case .wall: return "line.diagonal"
        case .noGo: return "nosign"
        case .noMop: return "drop.degreesign.slash.fill"
        case .threshold: return "door.left.hand.open"
        case .curtain: return "curtains.closed"
        case .ramp: return "righttriangle.fill"
        }
    }

    /// The colour `PlanCanvas` draws this kind in, so a tile doubles as its legend.
    var tint: Color {
        switch self {
        case .wall, .noGo: return Theme.rose
        case .noMop: return .purple
        case .threshold, .curtain, .ramp: return Theme.amber
        }
    }
}

struct MapEditorView: View {
    /// Inner corner radius plus padding, so the panel's corners stay concentric with the picker's.
    private static let panelRadius: CGFloat = 25

    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: EditMode = .rooms
    @State private var selected: Set<String> = []
    @State private var splitting = false
    @State private var line: (CGPoint, CGPoint)?
    @State private var renaming = false
    @State private var newName = ""
    @State private var materials: [String] = []

    @State private var shapes: [PlanShape] = []
    @State private var restrictedTypes: [String] = []
    @State private var annotationTypes: [String] = []
    @State private var dirty = false
    @State private var edits = 0
    @State private var saving = false
    @State private var drawKind: PlanShape.Kind?
    @State private var draftShape: PlanShape?
    @State private var picked: UUID?
    @State private var grab: ShapeGrab?
    /// This touch missed the selected shape or became a pinch, so it belongs to the canvas.
    @State private var touchIgnored = false
    @GestureState private var touching = false
    @State private var canvasReading = CanvasReading()
    @State private var justSaved: SavedShapes?
    @State private var pendingExit: Exit?
    @State private var confirmReset = false
    @State private var confirmMapping = false
    @State private var restoring: Backup?
    @State private var backups: [Backup] = []
    @State private var showCoverage = false
    @State private var showHelp = false
    @State private var export: MapExport?
    @State private var exporting = false

    @State private var planLoaded = false
    @State private var planAttempt = 0
    @State private var shapesLoad: LoadState = .ready
    @State private var shapesAttempt = 0
    @State private var finishedLoad: ShapesRequest?

    @State private var panelHeight: CGFloat = 0
    /// Room for the panel's tallest usual state. The plan is fitted to this rather than to the
    /// panel's current height, so it stays still while the panel changes around it.
    @ScaledMetric(relativeTo: .subheadline) private var panelReserve: CGFloat = 150

    private var modes: [EditMode] {
        var list: [EditMode] = []
        if store.has(Cap.segmentEdit) || store.has(Cap.segmentRename) || store.has(Cap.segmentMaterial) { list.append(.rooms) }
        if store.has(Cap.restrictions) { list.append(.limits) }
        if store.has(Cap.annotations) { list.append(.notes) }
        return list
    }

    /// Valetudo's web interface only changes the map while the robot is docked, and nothing
    /// behind it checks, so the rule has to be kept here too.
    private var canModify: Bool { store.state.status == "docked" }

    private var shapesRequest: ShapesRequest { ShapesRequest(mode: mode, attempt: shapesAttempt) }

    private var canDraw: Bool {
        canModify && ((mode == .rooms && splitting) || (mode != .rooms && drawKind != nil))
    }

    private var pickedShape: PlanShape? { shapes.first { $0.id == picked } }

    private var canAdjust: Bool { canModify && !saving && drawKind == nil && pickedShape != nil }

    private var selectedRooms: [FloorPlan.Room] {
        store.plan?.rooms.filter { selected.contains($0.id) } ?? []
    }

    private var hasPlan: Bool { store.plan?.isEmpty == false }

    private var showsPicker: Bool { modes.count > 1 && !splitting && drawKind == nil }

    private var showsPanel: Bool {
        hasPlan && (showsPicker || panelState != .failed)
    }

    private var panelState: PanelState {
        if mode == .rooms {
            guard modes.contains(.rooms) else { return .unsupported }
            guard canModify else { return .undocked }
            if splitting { return .splitting(hasLine: line != nil) }
            let rooms = selectedRooms
            if rooms.count == 2 { return .twoRooms }
            return rooms.first.map { .oneRoom($0.id) } ?? .roomHint
        }
        switch shapesLoad {
        case .loading: return .loading
        case .failed: return .failed
        case .ready: break
        }
        guard canModify else { return .undocked }
        if let drawKind { return .drawing(drawKind) }
        return pickedShape.map { .shape($0.id) } ?? .addShapes
    }

    var body: some View {
        NavigationStack {
            dialogs(on: screen)
                .navigationDestination(isPresented: $showCoverage) { CoverageMapView() }
                .sheet(isPresented: $showHelp) { FloorPlanHelp(topic: helpTopic) }
                .sheet(item: $export) { MapExportSheet(file: $0.file).presentationDetents([.medium, .large]) }
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            let safeBottom = geo.safeAreaInsets.bottom
            let panelGap = max(safeBottom - 14, 14)
            VStack(spacing: 0) {
                if store.pendingMap {
                    pendingBanner.transition(.move(edge: .top).combined(with: .opacity))
                }
                ZStack(alignment: .bottom) {
                    planArea(bottomInset: reservedHeight + panelGap + 8)
                    if showsPanel {
                        panel.padding(.bottom, panelGap)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.pendingMap)
        }
        .ignoresSafeArea(.keyboard)
        .background(Theme.mist.ignoresSafeArea())
        .navigationTitle("Edit Floor Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { planMenu }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { requestExit(.close) }
                    .disabled(saving)
            }
        }
        .modifier(ToastHost(toast: store.toast))
        .task(id: planAttempt) { await load() }
        .task(id: shapesRequest) { await loadShapes() }
        .onChange(of: canModify) { _, docked in
            if !docked { stopEditing() }
        }
        .onChange(of: touching) { _, isTouching in
            if !isTouching { endTouch() }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .sensoryFeedback(.selection, trigger: picked)
        .sensoryFeedback(.impact(weight: .light), trigger: edits)
    }

    private func dialogs(on content: some View) -> some View {
        content
            .alert("Rename Room", isPresented: $renaming) {
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: rename)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // An alert rather than a confirmation dialog: on iOS 26 a dialog can show as a
            // popover and hide its cancel button, and Keep Editing has to stay visible.
            .alert(canModify ? "Save your changes?" : "Discard your changes?", isPresented: Binding(
                get: { pendingExit != nil }, set: { if !$0 { pendingExit = nil } }), presenting: pendingExit) { exit in
                if canModify {
                    Button("Save") {
                        Task {
                            // If the robot says no, stay here so the work isn't lost.
                            if await commit() { leave(exit) }
                        }
                    }
                }
                Button("Discard", role: .destructive) { leave(exit) }
                Button("Keep Editing", role: .cancel) {}
            } message: { _ in
                Text(canModify ? "Your changes to this floor plan haven't been saved."
                               : "They can't be saved until the robot is back on its dock.")
            }
            .confirmationDialog("Start a mapping pass?", isPresented: $confirmMapping, titleVisibility: .visible) {
                Button("Run a Mapping Pass") { store.startMappingPass() }
            } message: {
                Text("The robot drives around your home to make a new floor plan.")
            }
            .confirmationDialog("Erase this floor plan?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Erase Floor Plan", role: .destructive) { replacePlan(Cap.mapReset, ["action": "reset"], "Floor plan erased") }
            } message: {
                Text(eraseMessage)
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { restoring != nil }, set: { if !$0 { restoring = nil } }), titleVisibility: .visible, presenting: restoring) { backup in
                Button("Restore Backup", role: .destructive) {
                    replacePlan(Cap.mapSnapshot, ["action": "restore", "id": backup.id], "Backup restored")
                }
            } message: { backup in
                Text(restoreMessage(backup))
            }
    }

    // MARK: Plan

    private var reservedHeight: CGFloat {
        max(panelHeight, panelReserve + (modes.count > 1 ? 52 : 0))
    }

    @ViewBuilder private func planArea(bottomInset: CGFloat) -> some View {
        if let plan = store.plan, !plan.isEmpty {
            if shapesLoad == .failed {
                failureView(title: mode == .limits ? "Can't Load No-Go Zones" : "Can't Load Annotations") {
                    shapesAttempt += 1
                }
                .padding(.bottom, 64)
            } else {
                canvas(plan, bottomInset: bottomInset)
            }
        } else if store.plan != nil {
            ContentUnavailableView {
                Label("No Floor Plan Yet", systemImage: "map")
            } description: {
                Text(store.planAdvice)
            }
            .frame(maxHeight: .infinity)
        } else if planLoaded {
            failureView(title: "Can't Load Floor Plan") { planAttempt += 1 }
        } else {
            ProgressView("Loading floor plan")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvas(_ plan: FloorPlan, bottomInset: CGFloat) -> some View {
        PlanCanvas(plan: plan, selected: selected, showsRobot: false, showsRestrictions: false,
                   drawing: canDraw || grab != nil,
                   insets: EdgeInsets(top: 12, leading: 14, bottom: bottomInset, trailing: 14),
                   overlay: { c, t in drawOverlay(c, t) },
                   onTap: { p, t in tap(p, t, plan) },
                   onDraw: { a, b in drew(a, b) },
                   onDrawEnd: finishDrawing)
            .simultaneousGesture(adjustGesture, including: canAdjust ? .all : .subviews)
            // A Canvas has nothing for VoiceOver to touch, so everything you can tap is also an action.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Floor plan with \(plan.roomCount)")
            .accessibilityValue(canvasValue)
            .accessibilityAddTraits(canDraw ? .allowsDirectInteraction : [])
            .accessibilityActions {
                if !canModify {
                    EmptyView()
                } else if mode == .rooms {
                    if modes.contains(.rooms), !splitting {
                        ForEach(plan.rooms) { room in
                            Button(selected.contains(room.id) ? "Deselect \(room.name)" : "Select \(room.name)") {
                                toggle(room.id, in: plan)
                            }
                        }
                    }
                } else if drawKind == nil {
                    ForEach(Array(shapes.enumerated()), id: \.element.id) { index, shape in
                        Button("Select \(shape.kind.tileTitle) \(index + 1)") { picked = shape.id }
                    }
                    if let shape = pickedShape, canAdjust, shape.isComplete { adjustActions(shape) }
                }
            }
    }

    /// Everything a drag can do to a selected shape, for people who can't drag.
    @ViewBuilder private func adjustActions(_ shape: PlanShape) -> some View {
        Button("Move Up") { nudgePicked(0, -1) }
        Button("Move Down") { nudgePicked(0, 1) }
        Button("Move Left") { nudgePicked(-1, 0) }
        Button("Move Right") { nudgePicked(1, 0) }
        Button("Make Larger") { changePicked { $0.scaled(by: 1.1) } }
        Button("Make Smaller") { changePicked { $0.scaled(by: 0.9) } }
        if shape.kind.isLine || shape.kind == .ramp {
            Button("Rotate Clockwise") { changePicked { $0.turned(by: .pi / 36) } }
            Button("Rotate Counterclockwise") { changePicked { $0.turned(by: -.pi / 36) } }
        }
        if shape.kind == .ramp {
            Button("Reverse Direction") { changePicked { $0.turned(by: .pi) } }
        }
    }

    private var canvasValue: String {
        if mode == .rooms {
            return selectedRooms.isEmpty ? "No room selected" : selectedRooms.map(\.name).joined(separator: " and ") + " selected"
        }
        if let pickedShape { return "\(pickedShape.kind.tileTitle) selected" }
        return shapes.count == 1 ? "1 item" : "\(shapes.count) items"
    }

    private func failureView(title: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: store.needsLogin ? store.readSymbol : "wifi.exclamationmark")
        } description: {
            Text(store.needsLogin ? RobotStore.loginAdvice
                                  : "Nothing has changed on the robot. Check that it's on and on the same network as this phone.")
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .tint(Theme.cobalt)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Loading

    private func load() async {
        if !modes.contains(mode), let first = modes.first { switchMode(to: first) }
        await store.refreshFloorPlan()
        planLoaded = true
        if shapesLoad == .failed { shapesAttempt += 1 }
        if store.has(Cap.segmentMaterial) {
            materials = (try? await store.client.getJSON("\(Cap.root)/\(Cap.segmentMaterial)/properties"))?["supportedMaterials"] as? [String] ?? []
        }
        if store.has(Cap.mapSnapshot) {
            let list = (try? await store.client.getList("\(Cap.root)/\(Cap.mapSnapshot)")) ?? []
            backups = Self.backups(from: list)
        }
        // The erase warning counts routines, which may have changed since the app started.
        if store.has(Cap.mapReset) { await store.loadSchedule() }
    }

    /// Newest first, because the firmware can list them in any order.
    private static func backups(from list: [[String: Any]]) -> [Backup] {
        let dated = list.compactMap { snapshot -> (id: String, date: Date?)? in
            (snapshot["id"] as? String).map { ($0, backupDate(snapshot["timestamp"])) }
        }
        let newestFirst = dated.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return newestFirst.enumerated().map { Backup(id: $1.id, number: $0 + 1, date: $1.date) }
    }

    private static func backupDate(_ raw: Any?) -> Date? {
        (raw as? String).flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
    }

    /// Saving replaces everything of this kind on the robot, so nothing can be added until
    /// the real list has arrived. A failure leaves the editor closed rather than empty.
    private func loadShapes() async {
        let request = shapesRequest
        // Coming back from the coverage map runs this again, which mustn't replace unsaved work.
        guard request != finishedLoad else { return }
        picked = nil
        shapes = []
        if let justSaved, justSaved.mode == mode, justSaved.isFresh {
            shapes = justSaved.shapes
            shapesLoad = .ready
            finishedLoad = request
            return
        }
        shapesLoad = mode == .rooms ? .ready : .loading
        do {
            switch mode {
            case .rooms: break
            case .limits: try await loadLimits()
            case .notes: try await loadAnnotations()
            }
            shapesLoad = .ready
            finishedLoad = request
        } catch is CancellationError {
            // Replaced by a newer request, which owns the state now.
        } catch {
            shapesLoad = .failed
        }
    }

    private func loadLimits() async throws {
        guard let size = store.plan?.pixelSize else { throw APIError(message: "The floor plan isn't loaded.") }
        let client = store.client
        let properties = try await client.getJSON("\(Cap.root)/\(Cap.restrictions)/properties")
        _ = try await Self.realMap(from: client)
        let body = try await client.getJSON("\(Cap.root)/\(Cap.restrictions)")
        let list = try Self.limits(from: body, pixelSize: size)
        try Task.checkCancellation()
        restrictedTypes = properties["supportedRestrictedZoneTypes"] as? [String] ?? ["regular"]
        shapes = list
    }

    /// After a restart Valetudo answers with no zones or annotations until the firmware sends
    /// its map. Saving replaces the whole list, so an empty one here would wipe the real ones.
    static func realMap(from client: Client) async throws -> RawMap {
        let map = try await client.get("/robot/state/map", as: RawMap.self)
        guard !map.isPlaceholder else { throw APIError(message: "The robot hasn't sent its map yet.") }
        return map
    }

    /// Read straight from the robot: the store keeps its last good plan when a refresh fails,
    /// and saving an old list would undo anything newer.
    private func loadAnnotations() async throws {
        let client = store.client
        let properties = try await client.getJSON("\(Cap.root)/\(Cap.annotations)/properties")
        let map = try await Self.realMap(from: client)
        try Task.checkCancellation()
        annotationTypes = properties["supportedAnnotationTypes"] as? [String] ?? []
        shapes = FloorPlan(map).annotations
    }

    /// All or nothing: saving replaces the whole set, so skipping an entry that can't be read
    /// here would delete it from the robot.
    private static func limits(from body: [String: Any], pixelSize size: CGFloat) throws -> [PlanShape] {
        let unreadable = APIError(message: "The robot's reply couldn't be read.")
        func read(_ names: [String], of entry: [String: Any]) throws -> [CGPoint] {
            let points = entry["points"] as? [String: Any]
            return try names.map { name in
                guard let point = points?[name] as? [String: Any],
                      let x = point["x"] as? Double, let y = point["y"] as? Double else { throw unreadable }
                return CGPoint(x: x / size, y: y / size)
            }
        }
        guard let walls = body["virtualWalls"] as? [[String: Any]],
              let zones = body["restrictedZones"] as? [[String: Any]] else { throw unreadable }
        let lines = try walls.map { PlanShape(kind: .wall, points: try read(["pA", "pB"], of: $0)) }
        let areas = try zones.map { zone -> PlanShape in
            let corners = try read(["pA", "pB", "pC", "pD"], of: zone)
            switch zone["type"] as? String {
            case "regular", nil: return PlanShape(kind: .noGo, points: corners)
            case "mop": return PlanShape(kind: .noMop, points: corners)
            default: throw unreadable
            }
        }
        return lines + areas
    }

    // MARK: Leaving

    private func requestExit(_ exit: Exit) {
        guard !saving else { return }
        if case .mode(let next) = exit, next == mode { return }
        if dirty {
            pendingExit = exit
        } else {
            leave(exit)
        }
    }

    private func leave(_ exit: Exit) {
        switch exit {
        case .close: dismiss()
        case .mode(let next): switchMode(to: next)
        case .refresh: refreshShapes()
        }
    }

    private func refreshShapes() {
        cancelDrawing()
        dirty = false
        shapesAttempt += 1
        Task { await store.refreshFloorPlan() }
    }

    private func switchMode(to next: EditMode) {
        selected = []
        endSplit()
        drawKind = nil
        draftShape = nil
        picked = nil
        dirty = false
        // Cleared here, not when the load starts, so the old mode's shapes are never on
        // screen in the new mode, where Save would send them to the wrong place.
        shapes = []
        shapesLoad = .loading
        finishedLoad = nil
        mode = next
    }

    // MARK: Drawing

    private func drawOverlay(_ context: GraphicsContext, _ t: PlanTransform) {
        canvasReading.transform = t
        for shape in shapes { draw(shape, highlighted: shape.id == picked, in: context, t) }
        if let draftShape { draw(draftShape, highlighted: true, in: context, t) }
        if canAdjust, let pickedShape {
            ShapeMarks.grips(on: pickedShape, color: pickedShape.kind.tint, in: context, t)
        }
        if let line {
            let ends = [t.toView(line.0), t.toView(line.1)]
            var path = Path()
            path.addLines(ends)
            // A band of floor behind the dashes, so they read on a picked room too.
            context.stroke(path, with: .color(Theme.floor), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            context.stroke(path, with: .color(Theme.cobalt), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
            for end in ends {
                let dot = Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12))
                context.fill(dot, with: .color(Theme.cobalt))
                context.stroke(dot, with: .color(Theme.floor), lineWidth: 2)
            }
        }
    }

    private func draw(_ shape: PlanShape, highlighted: Bool, in context: GraphicsContext, _ t: PlanTransform) {
        PlanCanvas.draw(shape, highlighted: highlighted, in: context, t)
        if shape.kind == .ramp { ShapeMarks.arrows(on: shape, color: shape.kind.tint, in: context, t) }
    }

    private func tap(_ point: CGPoint, _ t: PlanTransform, _ plan: FloorPlan) {
        guard canModify else { return }
        if mode == .rooms {
            if splitting {
                store.warn("Drag a line across the room")
            } else if modes.contains(.rooms), let id = plan.roomID(at: point) {
                toggle(id, in: plan)
            }
        } else if let drawKind {
            store.warn(drawInstruction(drawKind))
        } else if pickedShape?.grip(at: point, scale: t.scale) == nil {
            picked = shapes.last { $0.contains(point, tolerance: 18 / t.scale) }?.id
        }
    }

    /// Two rooms can only be joined, so a second room only stays selected if the robot can do that.
    private func toggle(_ id: String, in plan: FloorPlan) {
        selected.formIntersection(plan.rooms.map(\.id))
        if selected.contains(id) {
            selected.remove(id)
        } else if selected.count == 1, store.has(Cap.segmentEdit) {
            selected.insert(id)
        } else {
            selected = [id]
        }
    }

    private func drew(_ a: CGPoint, _ b: CGPoint) {
        if mode == .rooms {
            line = (a, b)
        } else if let kind = drawKind {
            let points = kind.isLine ? [a, PlanShape.snappedEnd(from: a, to: b)] : PlanShape.rectangle(a, b)
            draftShape = PlanShape(kind: kind, points: points)
        }
    }

    private func finishDrawing() {
        guard let size = store.plan?.pixelSize else { return }
        if mode == .rooms {
            // A slip of the finger isn't a split.
            if let line, hypot(line.1.x - line.0.x, line.1.y - line.0.y) * size < 25 {
                self.line = nil
                store.warn("Drag a longer line across the room")
            }
            return
        }
        defer { self.draftShape = nil }
        guard let draftShape else { return }
        guard draftShape.isBigEnough else {
            store.warn("Drag further to draw it")
            return
        }
        shapes.append(draftShape)
        dirty = true
        edits += 1
        drawKind = nil
        picked = draftShape.id
    }

    private func startDrawing(_ kind: PlanShape.Kind) {
        drawKind = kind
        picked = nil
        announce(drawInstruction(kind))
    }

    private func cancelDrawing() {
        drawKind = nil
        draftShape = nil
    }

    /// When the robot leaves the dock. Unsaved shapes stay, ready for when it's back.
    private func stopEditing() {
        selected = []
        endSplit()
        cancelDrawing()
        dropGrab()
        picked = nil
    }

    private func drawInstruction(_ kind: PlanShape.Kind) -> String {
        "Drag on the plan to add a \(kind.title.lowercased())"
    }

    private func startSplit(_ room: FloorPlan.Room) {
        splitting = true
        announce("Drag a line across \(room.name)")
    }

    private func endSplit() {
        splitting = false
        line = nil
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Adjusting

    /// Touches reach here as well as the canvas. One that lands on the selected shape takes over
    /// from panning at touch-down, and any other is left for the canvas to pan or zoom.
    private var adjustGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, isTouching, _ in isTouching = true }
            .onChanged(adjustPicked)
            // As well as the `touching` reset, which a tap too quick to redraw for can slip past.
            .onEnded { _ in endTouch() }
    }

    private func adjustPicked(_ touch: DragGesture.Value) {
        guard !touchIgnored, let t = canvasReading.transform,
              let index = shapes.firstIndex(where: { $0.id == picked }) else { return }
        let start = t.toMap(touch.startLocation)
        if grab == nil {
            guard let grip = shapes[index].grip(at: start, scale: t.scale) else {
                touchIgnored = true
                return
            }
            grab = ShapeGrab(grip: grip, original: shapes[index], scale: t.scale, wasDirty: dirty)
        }
        guard let held = grab else { return }
        // The plan changing size under a held finger means a second finger is zooming.
        guard held.scale == t.scale else { return dropGrab() }
        if !held.moved {
            // A tap isn't an edit, however much the finger wobbles.
            guard hypot(touch.translation.width, touch.translation.height) >= 6 else { return }
            grab?.moved = true
            dirty = true
            edits += 1
        }
        shapes[index].points = held.original.adjusted(held.grip, from: start, to: t.toMap(touch.location))
    }

    /// Puts a held shape back as it was, and leaves the rest of the touch to the canvas.
    private func dropGrab() {
        guard let grab, let index = shapes.firstIndex(where: { $0.id == grab.original.id }) else { return }
        shapes[index].points = grab.original.points
        dirty = grab.wasDirty
        self.grab = nil
        touchIgnored = true
    }

    private func endTouch() {
        grab = nil
        touchIgnored = false
    }

    private func nudgePicked(_ x: CGFloat, _ y: CGFloat) {
        // About 10 cm each time.
        let step = 10 / (store.plan?.pixelSize ?? 5)
        changePicked { $0.adjusted(.body, from: .zero, to: CGPoint(x: x * step, y: y * step)) }
    }

    private func changePicked(_ change: (PlanShape) -> [CGPoint]) {
        guard let index = shapes.firstIndex(where: { $0.id == picked }) else { return }
        shapes[index].points = change(shapes[index])
        dirty = true
        edits += 1
    }

    // MARK: Saving

    private func cm(_ p: CGPoint) -> [String: Int] {
        let size = store.plan?.pixelSize ?? 5
        return ["x": Int((p.x * size).rounded()), "y": Int((p.y * size).rounded())]
    }

    private func save() {
        Task { await commit() }
    }

    /// Sends the shapes and reports whether the robot accepted them. Anything drawn while
    /// that was under way stays marked as unsaved.
    @discardableResult
    private func commit() async -> Bool {
        guard !saving, requireDock() else { return false }
        let revision = edits
        let sent = shapes
        saving = true
        defer { saving = false }
        let accepted: Bool
        if mode == .limits {
            let walls: [[String: Any]] = shapes.filter { $0.kind == .wall }.map {
                ["points": ["pA": cm($0.points[0]), "pB": cm($0.points[1])]]
            }
            let zones: [[String: Any]] = shapes.filter { $0.kind != .wall }.map {
                ["type": $0.kind == .noMop ? "mop" : "regular",
                 "points": ["pA": cm($0.points[0]), "pB": cm($0.points[1]), "pC": cm($0.points[2]), "pD": cm($0.points[3])]]
            }
            accepted = await store.editPlan(Cap.restrictions, ["virtualWalls": walls, "restrictedZones": zones], done: "Changes saved")
        } else {
            accepted = await store.saveAnnotations(shapes.map { ["type": $0.kind.rawValue, "points": $0.points.map(cm)] }, done: "Changes saved")
        }
        if accepted { justSaved = SavedShapes(mode: mode, shapes: sent) }
        if accepted, edits == revision {
            dirty = false
            picked = nil
        }
        return accepted
    }

    /// For the rare path past a hidden control, such as an alert left open as the robot leaves.
    private func requireDock() -> Bool {
        if !canModify { store.warn("The robot needs to be on its dock for that") }
        return canModify
    }

    private func send(_ capability: String, _ body: [String: Any], _ message: String) {
        Task { await store.editPlan(capability, body, done: message) }
    }

    /// Leaves the screen alone until the robot says yes, so a refusal can be fixed and tried again.
    private func apply(_ capability: String, _ body: [String: Any], _ message: String, then finish: @escaping () -> Void) {
        saving = true
        Task {
            defer { saving = false }
            if await store.editPlan(capability, body, done: message) { finish() }
        }
    }

    /// For changes that swap the whole plan, which leaves anything on screen out of date.
    private func replacePlan(_ capability: String, _ body: [String: Any], _ message: String) {
        selected = []
        picked = nil
        endSplit()
        cancelDrawing()
        Task {
            guard await store.editPlan(capability, body, done: message) else { return }
            justSaved = nil
            dirty = false
            shapesAttempt += 1
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requireDock(), let room = selectedRooms.first, !name.isEmpty, name != room.name else { return }
        send(Cap.segmentRename, ["action": "rename_segment", "segment_id": room.id, "name": name], "Room renamed")
    }

    private func split() {
        guard requireDock(), let line, let room = selectedRooms.first else { return }
        apply(Cap.segmentEdit, ["action": "split_segment", "segment_id": room.id,
                                "pA": cm(line.0), "pB": cm(line.1)], "Room split") {
            endSplit()
            selected = []
        }
    }

    private func join() {
        guard requireDock(), selectedRooms.count == 2 else { return }
        apply(Cap.segmentEdit, ["action": "join_segments", "segment_a_id": selectedRooms[0].id,
                                "segment_b_id": selectedRooms[1].id], "Rooms joined") {
            selected = []
        }
    }

    private func deletePicked() {
        shapes.removeAll { $0.id == picked }
        picked = nil
        dirty = true
        edits += 1
    }

    /// Only here on the phone, like Delete. Nothing reaches the robot until Save.
    private func clearShapes() {
        cancelDrawing()
        shapes = []
        picked = nil
        dirty = true
        edits += 1
        announce("Cleared. Nothing changes on the robot until you save.")
    }

    private func exportMap() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                export = try await MapExport.fetch(from: store.client)
            } catch is CancellationError {
                // The screen went away, and so did the need for the file.
            } catch {
                store.report(error)
            }
        }
    }

    private func material(of room: FloorPlan.Room) -> String? {
        store.rooms.first { $0.id == room.id }?.material
    }

    private func materialBinding(_ room: FloorPlan.Room) -> Binding<String> {
        Binding(
            get: { material(of: room) ?? "" },
            set: { value in
                guard value != material(of: room), requireDock() else { return }
                send(Cap.segmentMaterial, ["action": "set_material", "segment_id": room.id, "material": value], "Floor type updated")
            })
    }

    // MARK: Top of the screen

    private var pendingBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelMessage(symbol: "map.fill", text: "A new floor plan is ready.", prominent: true)
            ReflowRow {
                PanelButton("Keep Current", symbol: "xmark") {
                    send(Cap.pendingMap, ["action": "reject"], "Kept the current floor plan")
                }
                PanelButton("Use New", symbol: "checkmark", style: .tinted) {
                    replacePlan(Cap.pendingMap, ["action": "accept"], "Using the new floor plan")
                }
            }
        }
        .padding(12)
        .glass(in: RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// Erasing leaves routines alone, so one for specific rooms keeps running with room numbers
    /// from the old plan, and the robot only records a failure in its own log.
    private var eraseMessage: String {
        let lost = "Rooms, names and no-go zones are lost, and the robot has to map your home again."
        let count = store.routines.filter { $0.enabled && $0.action.type == "segment_cleanup" }.count
        switch count {
        case 0: return lost
        case 1: return lost + " Your routine for specific rooms stays on and may clean the wrong rooms or fail without telling you, so check it afterwards."
        default: return lost + " Your \(count) routines for specific rooms stay on and may clean the wrong rooms or fail without telling you, so check them afterwards."
        }
    }

    private func restoreMessage(_ backup: Backup) -> String {
        let source = backup.dateText.map { "the backup from \($0)" } ?? "this backup"
        return "The current floor plan is replaced by \(source). Any changes you haven't saved are lost."
    }

    private var helpTopic: FloorPlanHelp.Topic {
        switch mode {
        case .rooms: return .rooms
        case .limits: return .noGo
        case .notes: return .annotations
        }
    }

    /// Says what Clear All really removes: this mode holds walls and no-mop zones too.
    private var shapesName: String { mode == .limits ? "Walls and Zones" : "Annotations" }

    private var planMenu: some View {
        Menu {
            if mode != .rooms, canModify, shapesLoad == .ready {
                Section {
                    Button { requestExit(.refresh) } label: {
                        Label("Refresh \(shapesName)", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive, action: clearShapes) {
                        Label("Clear All \(shapesName)", systemImage: "xmark")
                    }
                    .disabled(shapes.isEmpty)
                }
            }
            Section {
                Button { showCoverage = true } label: { Label("Robot Coverage Map", systemImage: "scribble.variable") }
                if hasPlan {
                    Button(action: exportMap) { Label("Export Map Data", systemImage: "square.and.arrow.up") }
                        .disabled(exporting)
                }
            }
            if store.has(Cap.mappingPass) {
                Button { confirmMapping = true } label: { Label("Run a Mapping Pass", systemImage: "map") }
            }
            ForEach(backups) { backup in
                Button { restoring = backup } label: {
                    Label("Restore Backup \(backup.number)", systemImage: "clock.arrow.circlepath")
                    if let date = backup.dateText { Text(date) }
                }
            }
            if store.has(Cap.mapReset) {
                Button(role: .destructive) { confirmReset = true } label: { Label("Erase Floor Plan", systemImage: "trash") }
            }
            Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Floor Plan Actions")
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 10) {
            panelContent.transition(.opacity)
            if showsPicker {
                SlidingPicker(options: modes, selection: mode, title: \.rawValue) { requestExit(.mode($0)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .glass(in: RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
        .padding(.horizontal, 14)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { panelHeight = max(panelHeight, $0) }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: panelState)
    }

    @ViewBuilder private var panelContent: some View {
        switch panelState {
        case .unsupported:
            PanelMessage(symbol: "info.circle.fill", text: "This robot can't edit rooms. Other floor plan actions are in the menu.")
        case .undocked:
            PanelMessage(symbol: "house.fill", text: undockedMessage)
        case .roomHint:
            PanelMessage(symbol: "hand.tap.fill", text: roomHint)
        case .oneRoom:
            if let room = selectedRooms.first { oneRoomPanel(room) }
        case .twoRooms:
            twoRoomsPanel
        case .splitting(let hasLine):
            splitPanel(hasLine: hasLine)
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(mode == .limits ? "Loading no-go zones" : "Loading annotations")
                    .font(.subheadline)
                    .foregroundStyle(Theme.slate)
            }
            .frame(maxWidth: .infinity, minHeight: Metric.hitTarget)
            .accessibilityElement(children: .combine)
        case .failed:
            EmptyView()
        case .addShapes:
            addShapesPanel
        case .drawing(let kind):
            PanelMessage(symbol: kind.symbol, tint: kind.tint, text: drawInstruction(kind), prominent: true)
            PanelButton("Cancel", symbol: "xmark", action: cancelDrawing)
        case .shape(let id):
            if let shape = shapes.first(where: { $0.id == id }) { shapePanel(shape) }
        }
    }

    private var undockedMessage: String {
        let subject = mode == .rooms ? "Rooms" : mode == .limits ? "No-go zones" : "Annotations"
        let rule = "\(subject) can only be edited while the robot is on its dock."
        return dirty ? rule + " Your unsaved changes stay here until then." : rule
    }

    private var roomHint: String {
        var verbs: [String] = []
        if store.has(Cap.segmentRename) { verbs.append("rename") }
        if store.has(Cap.segmentEdit) { verbs.append("split") }
        if !materials.isEmpty { verbs.append("set its floor type") }
        var text = verbs.isEmpty ? "Tap a room to select it." : "Tap a room to \(verbs.formatted(.list(type: .or)))."
        if store.has(Cap.segmentEdit) { text += " Tap two to join them." }
        return text
    }

    private func oneRoomPanel(_ room: FloorPlan.Room) -> some View {
        VStack(spacing: 8) {
            PanelHeader(title: room.name, subtitle: material(of: room).map(PresetKind.label)) { selected = [] }
            ReflowRow {
                if store.has(Cap.segmentRename) {
                    PanelTile(title: "Rename", symbol: "pencil") {
                        newName = room.name
                        renaming = true
                    }
                }
                if store.has(Cap.segmentEdit) {
                    PanelTile(title: "Split", symbol: "scissors") { startSplit(room) }
                }
                if !materials.isEmpty {
                    Menu {
                        Picker("Floor Type", selection: materialBinding(room)) {
                            ForEach(materials, id: \.self) { Text(PresetKind.label($0)).tag($0) }
                        }
                    } label: {
                        TileLabel(title: "Floor Type", symbol: "square.grid.3x3.fill", tint: Theme.cobalt)
                    }
                    .accessibilityValue(material(of: room).map(PresetKind.label) ?? "Not set")
                }
            }
        }
    }

    @ViewBuilder private var twoRoomsPanel: some View {
        if selectedRooms.count == 2 {
            VStack(spacing: 8) {
                PanelHeader(title: "\(selectedRooms[0].name) and \(selectedRooms[1].name)") { selected = [] }
                if store.has(Cap.segmentEdit) {
                    PanelButton(saving ? "Joining" : "Join Into One Room", symbol: "arrow.triangle.merge", style: .primary, action: join)
                        .disabled(saving)
                }
            }
        }
    }

    @ViewBuilder private func splitPanel(hasLine: Bool) -> some View {
        let name = selectedRooms.first?.name
        PanelMessage(symbol: "scissors", tint: Theme.cobalt,
                     text: hasLine ? "Split \(name ?? "the room") along this line?" : "Drag a line across \(name ?? "the room")",
                     prominent: true)
        ReflowRow {
            PanelButton("Cancel", symbol: "xmark", action: endSplit)
            PanelButton(saving ? "Splitting" : "Split Room", symbol: "scissors", style: .primary, action: split)
                .disabled(!hasLine || name == nil || saving)
        }
    }

    private var addKinds: [PlanShape.Kind] {
        if mode == .limits {
            var kinds: [PlanShape.Kind] = [.wall]
            if restrictedTypes.contains("regular") { kinds.append(.noGo) }
            if restrictedTypes.contains("mop") { kinds.append(.noMop) }
            return kinds
        }
        return annotationTypes.compactMap(PlanShape.Kind.init(rawValue:))
    }

    private var shapesHint: String {
        if addKinds.isEmpty { return shapes.isEmpty ? "Nothing added yet." : "Tap an item to change it." }
        return shapes.isEmpty ? "Choose a shape, then drag on the plan." : "Tap an item to change it, or add another."
    }

    @ViewBuilder private var addShapesPanel: some View {
        if dirty {
            PanelButton(saving ? "Saving" : "Save Changes", symbol: "checkmark", style: .primary, action: save)
                .disabled(saving)
        } else {
            PanelMessage(symbol: "hand.tap.fill", text: shapesHint)
        }
        if !addKinds.isEmpty {
            ReflowRow {
                ForEach(addKinds, id: \.self) { kind in
                    let count = shapes.filter { $0.kind == kind }.count
                    PanelTile(title: count == 0 ? kind.tileTitle : "\(kind.tileTitle) (\(count))",
                              symbol: kind.symbol, tint: kind.tint) { startDrawing(kind) }
                        .accessibilityLabel(kind.tileTitle)
                        .accessibilityValue(count == 0 ? "" : "\(count) added")
                        .accessibilityHint("Then drag on the plan to draw it")
                }
            }
        }
    }

    private func shapePanel(_ shape: PlanShape) -> some View {
        VStack(spacing: 8) {
            PanelHeader(title: shape.kind.tileTitle, subtitle: adjustHint(shape), symbol: shape.kind.symbol, tint: shape.kind.tint) {
                picked = nil
            }
            ReflowRow {
                PanelButton("Delete", symbol: "trash", style: .destructive, action: deletePicked)
                // Always here, so the panel's height can't change, and refit the plan, mid-drag.
                PanelButton(saving ? "Saving" : "Save Changes", symbol: "checkmark", style: .primary, action: save)
                    .disabled(saving || !dirty)
            }
        }
    }

    private func adjustHint(_ shape: PlanShape) -> String? {
        guard shape.isComplete else { return nil }
        switch shape.kind {
        case .ramp: return "Drag it to move it. Drag a corner to resize it, or the round handle to turn it."
        case .noGo, .noMop: return "Drag it to move it, or drag a corner to resize it."
        case .wall, .threshold, .curtain: return "Drag it to move it, or drag an end to change its length and angle."
        }
    }
}

// MARK: - Panel parts

/// Side by side, or stacked once accessibility text sizes leave no room for that.
private struct ReflowRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout { content }
    }
}

/// A sentence in the panel, with a symbol. Instructions are prominent and hints are not.
private struct PanelMessage: View {
    let symbol: String
    var tint: Color = Theme.cobalt
    let text: String
    var prominent = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(prominent ? .headline : .subheadline)
                .foregroundStyle(prominent ? Theme.ink : Theme.slate)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: Metric.hitTarget)
    }
}

/// Names what's selected, with a way to let go of it.
private struct PanelHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = Theme.cobalt
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.slate)
                    .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Clear Selection")
        }
        .padding(.leading, 4)
    }
}

/// `ActionTile`'s symbol and label without its card, which would be a box on a box here.
private struct TileLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var disc: CGFloat = 40

    var body: some View {
        let wide = typeSize.isAccessibilitySize
        let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 5))
        layout {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: disc, height: disc)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(wide ? .leading : .center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            if wide { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, minHeight: Metric.hitTarget)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct PanelTile: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.cobalt
    let action: () -> Void

    var body: some View {
        Button(action: action) { TileLabel(title: title, symbol: symbol, tint: tint) }
            .buttonStyle(.pressable)
    }
}

/// A capsule button, matching the filled button in Home's remote.
private struct PanelButton: View {
    enum Style {
        case primary, secondary, tinted, destructive
    }

    let title: String
    let symbol: String
    var style: Style = .secondary
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, style: Style = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.action = action
    }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.onCobalt
        case .secondary: return Theme.ink
        case .tinted: return Theme.cobalt
        case .destructive: return Theme.rose
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .primary: return AnyShapeStyle(Theme.cobalt.gradient)
        case .secondary, .destructive: return AnyShapeStyle(Theme.track)
        case .tinted: return AnyShapeStyle(Theme.cobalt.opacity(0.14))
        }
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(background, in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }
}
