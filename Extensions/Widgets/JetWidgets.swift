import SwiftUI
import WidgetKit
import AppIntents
import JetCapture

@main
struct JetWidgets: WidgetBundle {
    var body: some Widget {
        CaptureWidget()
        QuickCaptureControl()
        NewHandwrittenNoteControl()
    }
}

// MARK: Home Screen and Lock Screen widget

struct CaptureEntry: TimelineEntry {
    let date: Date
    let waiting: Int
    let snapshot: WidgetSnapshot
}

struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry {
        CaptureEntry(date: .now, waiting: 0, snapshot: WidgetSnapshot(vaultName: "Notes", recents: [
            .init(path: "Ideas.md", title: "Ideas", isInk: false),
            .init(path: "Sketch.ink", title: "Sketch", isInk: true),
            .init(path: "Daily/Today.md", title: "Today", isInk: false),
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        // The app reloads this whenever captures arrive or are filed; the hourly refresh is a backstop.
        completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func current() -> CaptureEntry {
        CaptureEntry(date: .now, waiting: CaptureInbox.shared?.pendingCount ?? 0, snapshot: WidgetSnapshot.load())
    }
}

struct CaptureWidget: Widget {
    static let kind = "JetCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CaptureProvider()) { entry in
            CaptureWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Capture")
        .description("Jot something down, open today's note, or jump back into a recent note.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct CaptureWidgetView: View {
    let entry: CaptureEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.title2)
            }
            .widgetURL(JetLink.action(.capture).url)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Jet", systemImage: "square.and.pencil").font(.headline)
                Text(entry.waiting > 0 ? "\(entry.waiting) waiting to file" : "Quick capture").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(JetLink.action(.capture).url)
        case .accessoryInline:
            Label("Quick capture", systemImage: "square.and.pencil")
                .widgetURL(JetLink.action(.capture).url)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "square.and.pencil").font(.largeTitle).foregroundStyle(.tint)
                Spacer()
                Text("Quick Capture").font(.headline)
                if entry.waiting > 0 { Text("\(entry.waiting) waiting").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(JetLink.action(.capture).url)
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                Actions()
                RecentNotes(snapshot: entry.snapshot, limit: 3)
            }
        default:
            VStack(alignment: .leading, spacing: 16) {
                Actions()
                RecentNotes(snapshot: entry.snapshot, limit: 6)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct Actions: View {
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            tile("Capture", "square.and.pencil", .action(.capture))
            tile("Today", "calendar", .action(.daily))
            tile("Note", "doc.text", .action(.newNote))
            tile("Draw", "applepencil.tip", .action(.newInk))
        }
    }

    private func tile(_ title: String, _ symbol: String, _ link: JetLink) -> some View {
        Link(destination: link.url) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct RecentNotes: View {
    let snapshot: WidgetSnapshot
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if snapshot.recents.isEmpty {
                Text("Open Jet to see your notes here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.recents.prefix(limit)) { note in
                Link(destination: JetLink.open(vault: snapshot.vaultID, path: note.path).url) {
                    Label(note.title, systemImage: note.isInk ? "scribble" : "doc.text")
                        .font(.footnote)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Note titles are redacted when the device is locked.
                        .privacySensitive()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Control Center

struct QuickCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "JetQuickCaptureControl") {
            ControlWidgetButton(action: QuickCaptureIntent()) {
                Label("Quick Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("Quick Capture")
        .description("Jot something down in Jet.")
    }
}

struct NewHandwrittenNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "JetNewHandwrittenNoteControl") {
            ControlWidgetButton(action: NewHandwrittenNoteIntent()) {
                Label("Handwritten Note", systemImage: "applepencil.tip")
            }
        }
        .displayName("Handwritten Note")
        .description("Start a new handwritten note in Jet.")
    }
}
