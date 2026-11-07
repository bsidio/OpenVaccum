import SwiftUI

/// A milestone from Valetudo's statistics page. Values are Doubles because a few of them
/// are far beyond what an Int can hold.
struct Achievement: Identifiable, Equatable {
    let value: Double
    let title: String
    let detail: String

    var id: String { title }

    /// The totals that earn achievements, named as the robot reports them.
    enum Kind: String, CaseIterable, Identifiable {
        case time, area, count

        var id: Self { self }

        var label: String {
            switch self {
            case .time: return "Cleaning Time"
            case .area: return "Area Cleaned"
            case .count: return "Cleans"
            }
        }

        var totalLabel: String {
            switch self {
            case .time: return "Total Time"
            case .area: return "Total Area"
            case .count: return "Total Cleans"
            }
        }

        var pageTitle: String {
            switch self {
            case .time: return "Time Achievements"
            case .area: return "Area Achievements"
            case .count: return "Clean Achievements"
            }
        }

        var symbol: String {
            switch self {
            case .time: return "clock.fill"
            case .area: return "square.dashed.inset.filled"
            case .count: return "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .time: return Theme.cobalt
            case .area: return .teal
            case .count: return .indigo
            }
        }

        /// Highest first, as Valetudo lists them, so the first one reached is the latest award.
        var achievements: [Achievement] {
            switch self {
            case .time: return Achievement.time
            case .area: return Achievement.area
            case .count: return Achievement.count
            }
        }

        func latest(at amount: Double) -> Achievement? {
            achievements.first { amount >= $0.value }
        }

        /// The exact figure, as Valetudo's own statistics page gives it.
        func exact(_ amount: Double) -> String {
            switch self {
            case .time:
                return Self.clock(amount)
            case .area:
                return Measurement(value: amount / 10_000, unit: UnitArea.squareMeters)
                    .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(.fractionLength(2))))
            case .count:
                return amount.formatted(.number.precision(.fractionLength(0)))
            }
        }

        /// The same figure in whole words, because VoiceOver stumbles over "01h 00m 00s".
        func spoken(_ amount: Double) -> String {
            guard self == .time else { return exact(amount) }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .full
            return formatter.string(from: amount) ?? exact(amount)
        }

        private static func clock(_ seconds: Double) -> String {
            let whole = max(0, seconds.rounded(.down))
            let hours = (whole / 3600).rounded(.down).formatted(.number.precision(.integerLength(2...)))
            let minutes = Int(whole.truncatingRemainder(dividingBy: 3600) / 60)
            let rest = Int(whole.truncatingRemainder(dividingBy: 60))
            return "\(hours)h " + String(format: "%02dm %02ds", minutes, rest)
        }
    }
}

// MARK: - Valetudo's list

// Copied from Valetudo's StatisticsAchievements.ts. Area is in cm², time in seconds.
private extension Achievement {
    static let day: Double = 24 * 60 * 60

    /// A map edge in game units, one inch each, squared into cm².
    static func mapArea(units: Double) -> Double { (units * 2.54) * (units * 2.54) }

    static let area: [Achievement] = [
        .init(value: 25_690_000_000_000, title: "Saarland", detail: "Ei jo."),
        .init(value: mapArea(units: 32768), title: "Source Map",
              detail: "You've cleaned more than the maximum playable area of a full Source Engine (Half-Life 2) map"),
        .init(value: 500_000_000, title: "Leipziger Messe",
              detail: "You've cleaned more than the whole CCCongress: Leipziger Messe"),
        .init(value: mapArea(units: 8192), title: "GoldSrc Map",
              detail: "You've cleaned more than the maximum playable area of a full GoldSrc (Half-Life 1) map"),
        .init(value: 360_000_000, title: "CCH (Again)",
              detail: "You've cleaned more than the whole CCCongress: Congress Center Hamburg (post 2022)"),
        .init(value: 240_000_000, title: "CCH",
              detail: "You've cleaned more than the whole CCCongress: Congress Center Hamburg (pre 2021)"),
        .init(value: 100_000_000, title: "bcc",
              detail: "You've cleaned more than the whole CCCongress: bcc Berlin Congress Center"),
        .init(value: 1_620_000, title: "Sports", detail: "You've cleaned more than an entire volleyball court"),
        .init(value: 700_000, title: "Breathe", detail: "You've cleaned more than the approximate surface area of a human lung"),
        .init(value: 10_000, title: "Metric", detail: "You've cleaned more than the area of an entire A0 paper")
    ]

    static let time: [Achievement] = [
        .init(value: 1.67e34 * 365.25 * day, title: "Proton Decay",
              detail: "50% of all matter in the universe might've already decayed into energy"),
        .init(value: 30 * day, title: "Subscription", detail: "One entire month of continuous cleaning"),
        .init(value: 7 * day, title: "A Week", detail: "More than an entire week of continuous cleaning"),
        // Apollo 11: liftoff on 16 July 1969 at 13:32 UTC, first step on 21 July at 02:56 UTC.
        .init(value: 109 * 3600 + 24 * 60, title: "Desolation",
              detail: "More than the time it took the Apollo 11 mission from liftoff to man setting foot on the moon"),
        .init(value: day, title: "A Day", detail: "More than an entire day of continuous cleaning"),
        .init(value: 3600, title: "An Hour", detail: "More than an entire hour of continuous cleaning")
    ]

    static let count: [Achievement] = [
        .init(value: 6.02214076e23, title: "1 Mole", detail: "The SI base unit for \"amount of substance\""),
        .init(value: 1337, title: "1337", detail: "r0b0t v4cuum h4x0r"),
        .init(value: 1024, title: "2^10", detail: "The true size of 1k"),
        .init(value: 1000, title: "1k", detail: "1000 cleanups"),
        .init(value: 512, title: "1 Block", detail: "Make sure to align your partitions"),
        .init(value: 365, title: "Daily Driver", detail: "One year of daily cleanups"),
        .init(value: 256, title: "1 Byte",
              detail: "The cleanup count has exceeded the limit of what can be stored in a single byte"),
        .init(value: 64, title: "Y2K38 Compliant", detail: "Enough bits to survive the next extinction event"),
        .init(value: 10, title: "Baby Steps", detail: "Your robot has done its first 10 cleanups")
    ]
}

// MARK: - Views

/// A seal carrying the total's symbol once earned, and a question mark until then.
private struct AchievementBadge: View {
    let kind: Achievement.Kind
    let earned: Bool
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 46

    var body: some View {
        ZStack {
            Image(systemName: "seal.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(earned ? Theme.cobalt : Theme.track)
            Image(systemName: earned ? kind.symbol : "questionmark")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(earned ? Theme.onCobalt : Theme.slate)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The latest award for one total, or a note that there isn't one yet.
struct AchievementRow: View {
    let kind: Achievement.Kind
    let amount: Double

    private var latest: Achievement? { kind.latest(at: amount) }

    var body: some View {
        HStack(spacing: 14) {
            AchievementBadge(kind: kind, earned: latest != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label)
                    .font(.footnote)
                    .foregroundStyle(Theme.slate)
                Text(latest?.title ?? "No Achievement Yet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let latest {
                    Text(latest.detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.slate)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct AchievementEntry: View {
    let achievement: Achievement
    let kind: Achievement.Kind
    let earned: Bool

    var body: some View {
        HStack(spacing: 14) {
            AchievementBadge(kind: kind, earned: earned)
            VStack(alignment: .leading, spacing: 3) {
                // Valetudo keeps unearned ones a surprise, so neither the name nor the target shows.
                Text(earned ? achievement.title : "Not Yet Achieved")
                    .font(.body.weight(earned ? .semibold : .regular))
                    .foregroundStyle(earned ? Theme.ink : Theme.slate)
                if earned {
                    Text(achievement.detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.slate)
                    Text("Achieved at \(kind.exact(achievement.value))")
                        .font(.footnote)
                        .foregroundStyle(Theme.slate)
                        .accessibilityLabel("Achieved at \(kind.spoken(achievement.value))")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Every achievement for one total, smallest first, so the list reads as a climb.
struct AchievementsView: View {
    @Environment(RobotStore.self) private var store
    let kind: Achievement.Kind

    private var amount: Double { store.total[kind.rawValue] ?? 0 }
    private var earnedCount: Int { kind.achievements.filter { amount >= $0.value }.count }

    var body: some View {
        List {
            Section {
                LabeledContent(kind.totalLabel, value: kind.exact(amount))
                    .accessibilityValue(kind.spoken(amount))
            } footer: {
                Text("\(earnedCount) of \(kind.achievements.count) achieved.")
            }
            Section {
                ForEach(kind.achievements.reversed()) { achievement in
                    AchievementEntry(achievement: achievement, kind: kind, earned: amount >= achievement.value)
                }
            }
        }
        .themedList()
        .navigationTitle(kind.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
