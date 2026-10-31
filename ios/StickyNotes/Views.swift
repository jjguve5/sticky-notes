// The paper: the To do and Machines tabs, as on the desktop. Tap the box to finish (it leaves after a moment, Undo
// brings it back), tap the text to edit, swipe to delete, the bell sets a reminder.
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum Theme {
    static let paper = Color(hex: 0xfbf7ec)
    static let paper2 = Color(hex: 0xf6f0e0)
    static let ink = Color(hex: 0x2b2a27)
    static let inkSoft = Color(hex: 0x6f6a5e)
    static let inkFaint = Color(hex: 0xa8a190)
    static let rule = Color(hex: 0x5478a8, alpha: 0.13)
    static let margin = Color(hex: 0xd65c54, alpha: 0.35)
    static let accent = Color(hex: 0xd1543f)
    static let done = Color(hex: 0x3f8f5f)
    static let line: CGFloat = 44
    static let marginX: CGFloat = 44
}

extension Font {
    static func hand(_ size: CGFloat) -> Font { .custom("Caveat", size: size).weight(.semibold) }
}

extension View {
    func paperRow() -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
    }

    func ruled() -> some View {
        overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

// ------------------------------------------------------------------------------------------------ times
// "now", "5m", "2h", "3d"
func age(_ ms: Int) -> String {
    let m = (now() - ms) / 60000
    if m < 1 { return "now" }
    if m < 60 { return "\(m)m" }
    if m / 60 < 24 { return "\(m / 60)h" }
    return "\(m / 60 / 24)d"
}

func clock(_ ms: Int) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
}

// The time left on a reminder: "⏰ 4:59", or its time of day when it's an hour or more away
func countdown(_ at: Int) -> String {
    let left = max(0, at - now())
    let m = left / 60000
    let s = left % 60000 / 1000
    return m >= 60 ? "⏰ \(clock(at))" : "⏰ \(m):\(String(format: "%02d", s))"
}

// "5 min ago", "3 h ago", "yesterday", "4 days ago"
func ago(_ ms: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
    let minutes = (now() - ms) / 60000
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if Calendar.current.isDateInToday(date) || hours < 12 { return "\(hours) h ago" }
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
    return days <= 1 ? "yesterday" : "\(days) days ago"
}

func isToday(_ ms: Int?) -> Bool {
    guard let ms else { return false }
    return Calendar.current.isDateInToday(Date(timeIntervalSince1970: Double(ms) / 1000))
}

// Minutes from now ("45") or a time of day ("14:30", that time tomorrow if it's past)
func parseWhen(_ value: String) -> Int? {
    let v = value.trimmingCharacters(in: .whitespaces)
    if let match = v.wholeMatch(of: #/(\d{1,2})[:h.](\d{2})/#), let h = Int(match.1), let m = Int(match.2), h < 24, m < 60 {
        var date = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        if date <= Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        return Int(date.timeIntervalSince1970 * 1000)
    }
    if let minutes = Int(v), minutes > 0 { return now() + minutes * 60000 }
    return nil
}

// ------------------------------------------------------------------------------------------------ the note
struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tab") private var tab = "todo"
    @AppStorage("askedForServer") private var askedForServer = false
    @State private var settingsOpen = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.paper, Theme.paper2], startPoint: .top, endPoint: .bottom)
                .overlay(RadialGradient(colors: [.white.opacity(0.7), .clear], center: .topLeading, startRadius: 0, endRadius: 500))
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if tab == "todo" { TodoList() } else { MachineList() }
            }
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast?.id)
        .preferredColorScheme(.light)
        .tint(Theme.accent)
        .sheet(isPresented: $settingsOpen) { SettingsView() }
        .onReceive(ticker) { _ in store.tick() }
        // While the app is open: sync now and every 5 seconds
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if store.serverURL.isEmpty && !askedForServer {
                askedForServer = true
                settingsOpen = true
            }
            while !Task.isCancelled {
                await store.syncNow()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TabButton(title: "To do", count: "\(store.items.count)", active: tab == "todo") { tab = "todo" }
            let locked = store.machines.filter(\.locked).count
            TabButton(title: "Machines", count: locked > 0 ? "\(locked) 🔒" : "\(store.machines.count)", active: tab == "machines") { tab = "machines" }
            Spacer()
            Button { settingsOpen = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(syncColor).frame(width: 7, height: 7)
                    Image(systemName: "gearshape").font(.system(size: 17))
                }
                .foregroundStyle(Theme.inkFaint)
                .frame(height: 44)
            }
            .accessibilityLabel("Settings, \(store.sync.label)")
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.top, 6)
    }

    private var syncColor: Color {
        switch store.sync {
        case .off: return Theme.inkFaint.opacity(0.5)
        case .synced: return Theme.done
        case .failed: return Theme.accent
        }
    }
}

struct TabButton: View {
    let title: String
    let count: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.hand(26))
                Text(count)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.ink.opacity(0.06), in: Capsule())
            }
            .foregroundStyle(active ? Theme.ink : Theme.inkFaint)
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2) }
        }
        .buttonStyle(.plain)
    }
}

struct ToastView: View {
    @EnvironmentObject private var store: Store
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.text).font(.system(size: 14)).lineLimit(1)
            if toast.undo != nil {
                Button("Undo") { withAnimation { store.undo() } }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.paper.opacity(0.16), in: Capsule())
            }
        }
        .foregroundStyle(Theme.paper)
        .padding(.leading, 16)
        .padding(.trailing, toast.undo != nil ? 6 : 16)
        .padding(.vertical, 6)
        .background(Theme.ink, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 9, y: 6)
    }
}

// The red margin line, under the boxes' column
struct Margin: View {
    var body: some View {
        Rectangle().fill(Theme.margin).frame(width: 1.5).padding(.leading, Theme.marginX).allowsHitTesting(false)
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text).font(.hand(24)).foregroundStyle(Theme.inkFaint).frame(maxWidth: .infinity).padding(.top, 28).paperRow()
    }
}

// ------------------------------------------------------------------------------------------------ to do
struct TodoList: View {
    @EnvironmentObject private var store: Store
    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.inkFaint).frame(width: Theme.marginX)
                TextField("Something to do…", text: $draft)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                    .focused($adding)
                    .submitLabel(.done)
                    .onSubmit {
                        withAnimation(.easeOut(duration: 0.18)) { store.add(draft) }
                        draft = ""
                        adding = true
                    }
                    .padding(.leading, 10)
            }
            .frame(height: Theme.line)
            .padding(.trailing, 14)
            .ruled()
            List {
                ForEach(store.items) { item in
                    TodoRow(item: item)
                        .paperRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.remove(item.id, verb: "Deleted") } label: { Label("Delete", systemImage: "xmark") }
                        }
                }
                if store.items.isEmpty { EmptyNote(text: "All done ✓") }
                Color.clear.frame(height: 70).paperRow() // room above the toast
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .overlay(alignment: .leading) { Margin() }
    }
}

struct CheckBox: View {
    let done: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(done ? Theme.done : Theme.inkFaint, lineWidth: 1.6)
            Tick().trim(from: 0, to: done ? 1 : 0).stroke(Theme.done, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 22, height: 22)
        .animation(.easeOut(duration: 0.22), value: done)
    }
}

struct Tick: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.275, y: r.height * 0.525))
        p.addLine(to: CGPoint(x: r.width * 0.425, y: r.height * 0.675))
        p.addLine(to: CGPoint(x: r.width * 0.725, y: r.height * 0.325))
        return p
    }
}

struct TodoRow: View {
    @EnvironmentObject private var store: Store
    let item: Item
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var picking = false
    @State private var customOpen = false
    @State private var custom = ""
    @State private var blink = false

    private var done: Bool { store.leaving[item.id] != nil }
    private var ringing: Bool { item.ringing == true }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { store.toggleDone(item.id) } label: {
                CheckBox(done: done).frame(width: Theme.marginX, height: Theme.line).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Keep" : "Done")

            Group {
                if editing {
                    TextField("", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(finish)
                        .padding(.horizontal, 4)
                        .background(Color(hex: 0xffeca0, alpha: 0.45), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, -4)
                } else {
                    Text(item.text)
                        .strikethrough(done, color: Theme.inkSoft)
                        .foregroundStyle(ringing ? .white : done ? Theme.inkFaint : Theme.ink)
                        .fontWeight(ringing ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if ringing {
                                store.stopRinging(item.id)
                            } else {
                                text = item.text
                                editing = true
                                focused = true
                            }
                        }
                }
            }
            .font(.system(size: 16))
            .padding(.leading, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 1)) { _ in when }
                .padding(.top, 14)
                .padding(.leading, 8)

            Button { picking = true } label: {
                Image(systemName: item.remindAt != nil || ringing ? "bell.fill" : "bell")
                    .font(.system(size: 15))
                    .foregroundStyle(ringing ? .white : item.remindAt != nil ? Theme.accent : Theme.inkFaint)
                    .rotationEffect(.degrees(ringing && blink ? 16 : 0))
                    .frame(width: 42, height: Theme.line)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.remindAt.map { "Reminder at \(clock($0))" } ?? "Remind me")
        }
        .padding(.trailing, 4)
        .background(ringing ? Theme.accent.opacity(blink ? 0.92 : 0.35) : .clear)
        .ruled()
        .contentShape(Rectangle())
        .onTapGesture { if ringing { store.stopRinging(item.id) } }
        .onAppear { animateRinging() }
        .onChange(of: ringing) { _, _ in animateRinging() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && editing { finish() }
        }
        .confirmationDialog(item.remindAt.map { "Reminder at \(clock($0))" } ?? "Remind me", isPresented: $picking, titleVisibility: .visible) {
            ForEach([5, 10, 15, 30], id: \.self) { m in
                Button("\(m) min") { store.setReminder(item.id, at: now() + m * 60000) }
            }
            Button("Custom…") {
                custom = ""
                customOpen = true
            }
            if item.remindAt != nil {
                Button("Remove", role: .destructive) { store.setReminder(item.id, at: nil) }
            }
        }
        .alert("Remind me", isPresented: $customOpen) {
            TextField("45 or 14:30", text: $custom).keyboardType(.numbersAndPunctuation)
            Button("Set") {
                if let at = parseWhen(custom) {
                    store.setReminder(item.id, at: at)
                } else {
                    store.showToast("Minutes (45) or a time (14:30)")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Minutes from now, or a time of day")
        }
    }

    // The age, or the time left on a reminder, or "now!" while it rings
    @ViewBuilder private var when: some View {
        if ringing {
            Text("now!").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
        } else if let at = item.remindAt {
            Text(countdown(at)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
        } else {
            Text(age(item.created)).font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        store.edit(item.id, text: text)
    }

    // Ringing: the row blinks and the bell shakes until it's tapped
    private func animateRinging() {
        if ringing {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { blink = true }
        } else {
            withAnimation(.default) { blink = false }
        }
    }
}

// ------------------------------------------------------------------------------------------------ machines
// People's machines by name and IP (tap the IP to copy it) and whether I locked them. The draft button stamps when
// I applied their draft (Undo takes it back); green when it was today. Long-press a row to rename or change the IP.
struct MachineList: View {
    @EnvironmentObject private var store: Store
    @State private var name = ""
    @State private var ip = ""
    @FocusState private var field: Field?

    enum Field { case name, ip }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.inkFaint).frame(width: Theme.marginX)
                TextField("Name", text: $name)
                    .focused($field, equals: .name)
                    .submitLabel(.next)
                    .onSubmit {
                        if ip.isEmpty {
                            field = .ip
                        } else {
                            add()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 2)
                TextField("IP address", text: $ip)
                    .focused($field, equals: .ip)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 16))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(height: Theme.line)
            .padding(.trailing, 14)
            .ruled()
            List {
                ForEach(store.machines) { machine in
                    MachineRow(machine: machine)
                        .paperRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { store.removeMachine(machine.id) } label: { Label("Delete", systemImage: "xmark") }
                        }
                }
                if store.machines.isEmpty { EmptyNote(text: "No machines yet") }
                Color.clear.frame(height: 70).paperRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .overlay(alignment: .leading) { Margin() }
    }

    private func add() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !ip.isEmpty else {
            field = name.isEmpty ? .name : .ip
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { store.addMachine(name: name, ip: ip) }
        self.name = ""
        self.ip = ""
        field = .name
    }
}

struct MachineRow: View {
    @EnvironmentObject private var store: Store
    let machine: Machine
    @State private var copied = false
    @State private var editing: Field?
    @State private var value = ""

    enum Field: String, Identifiable {
        case name = "Rename", ip = "Change IP"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { store.toggleLock(machine.id) } label: {
                Image(systemName: machine.locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(machine.locked ? .white : Theme.inkFaint)
                    .frame(width: 26, height: 26)
                    .background(machine.locked ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: Theme.marginX, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(machine.locked ? "Locked, tap when you unlock it" : "Not locked, tap when you lock it")

            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(machine.draftAppliedAt.map { "Draft \(ago($0))" } ?? "No draft yet")
                        .font(.system(size: 11.5))
                        .foregroundStyle(isToday(machine.draftAppliedAt) ? Theme.done : Theme.inkFaint)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            if machine.locked {
                Text("LOCKED").font(.system(size: 11, weight: .bold)).tracking(0.3).foregroundStyle(Theme.accent).padding(.trailing, 6)
            }

            Button { store.applyDraft(machine.id) } label: {
                Image(systemName: isToday(machine.draftAppliedAt) ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 16))
                    .foregroundStyle(isToday(machine.draftAppliedAt) ? Theme.done : machine.draftAppliedAt != nil ? Theme.inkSoft : Theme.inkFaint.opacity(0.7))
                    .frame(width: 38, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Applied a draft now")

            Button {
                store.copy(machine.ip)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    copied = false
                }
            } label: {
                Text(copied ? "copied" : machine.ip)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(copied ? Theme.done : Theme.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(copied ? Theme.done.opacity(0.2) : Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(machine.ip)")
        }
        .padding(.trailing, 12)
        .ruled()
        .contentShape(Rectangle())
        .contextMenu {
            Button { store.copy(machine.ip) } label: { Label("Copy IP", systemImage: "doc.on.doc") }
            Button { start(.name) } label: { Label("Rename…", systemImage: "pencil") }
            Button { start(.ip) } label: { Label("Change IP…", systemImage: "network") }
        }
        .alert(editing?.rawValue ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing) { field in
            TextField(field == .name ? "Name" : "IP address", text: $value)
                .keyboardType(field == .ip ? .numbersAndPunctuation : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                if field == .name { store.rename(machine.id, to: value) } else { store.setIP(machine.id, to: value) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func start(_ field: Field) {
        value = field == .name ? machine.name : machine.ip
        editing = field
    }
}

// ------------------------------------------------------------------------------------------------ settings
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/sync.php", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $token)
                } header: {
                    Text("Sync server")
                } footer: {
                    Text("The same URL and token as sync.json on the desktop. To-dos and machines sync; reminders stay on this phone.")
                }
                Section {
                    LabeledContent("Status", value: store.sync.label)
                    Button("Sync now") {
                        store.configure(url: url, token: token)
                        Task { await store.syncNow() }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.configure(url: url, token: token)
                        Task { await store.syncNow() }
                        dismiss()
                    }
                }
            }
            .onAppear {
                url = store.serverURL
                token = store.token
            }
        }
    }
}
