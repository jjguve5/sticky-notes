// The list and the machines, saved on the phone and synced with the PHP backend (the same records as the desktop).
// Reminders (remindAt, ringing) are this phone's only: they become local notifications and never go to the server.
import AudioToolbox
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct Item: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var created: Int
    var remindAt: Int?
    var ringing: Bool?

    var shared: RecordData { RecordData(text: text, created: created) }
}

struct Machine: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var ip: String
    var locked: Bool
    var draftAppliedAt: Int?
    var created: Int

    var shared: RecordData { RecordData(created: created, name: name, ip: ip, locked: locked, draftAppliedAt: draftAppliedAt) }
}

// The shared fields of an item or a machine, as the server keeps them
struct RecordData: Codable, Equatable {
    var text: String?
    var created: Int?
    var name: String?
    var ip: String?
    var locked: Bool?
    var draftAppliedAt: Int?
}

struct Change: Codable {
    var type: String
    var id: String
    var deleted: Bool?
    var data: RecordData?
}

private struct SyncRequest: Encodable {
    var token: String
    var since: Int
    var changes: [Change]
}

private struct SyncReply: Decodable {
    var rev: Int
    var changes: [Change]
}

// What's on disk. dirty: "item:<id>" / "machine:<id>" changed here and not yet on the server (with a version, so a
// change made during a sync isn't taken as sent). rev: the last server revision seen (nil: never synced).
private struct Saved: Codable {
    var items: [Item] = []
    var machines: [Machine] = []
    var rev: Int?
    var dirty: [String: String] = [:]
}

enum SyncState: Equatable {
    case off
    case synced(Date)
    case failed(String)

    var label: String {
        switch self {
        case .off: return "Not set up"
        case .synced(let at): return "Synced \(at.formatted(date: .omitted, time: .standard))"
        case .failed(let why): return why
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}

func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

func uid() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String(now(), radix: 36) + String((0..<5).map { _ in chars.randomElement()! })
}

@MainActor
final class Store: ObservableObject {
    static let doneDelay: UInt64 = 3_500_000_000 // how long a ticked item stays before leaving

    @Published var items: [Item] = []
    @Published var machines: [Machine] = []
    @Published var leaving: [String: UUID] = [:] // ticked, about to leave
    @Published var toast: Toast?
    @Published var sync: SyncState = .off

    private var rev: Int?
    private var dirty: [String: String] = [:]
    private var syncing = false
    private var syncSoon: Task<Void, Never>?
    private var lastChime = Date.distantPast

    private let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("notes.json")

    var serverURL: String { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
    var token: String { UserDefaults.standard.string(forKey: "token") ?? "" }

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
            machines = saved.machines
            rev = saved.rev
            dirty = saved.dirty
        }
        if !serverURL.isEmpty { sync = .failed("Connecting…") }
    }

    private func save() {
        let saved = Saved(items: items, machines: machines, rev: rev, dirty: dirty)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    // A record changed here: saved now, sent shortly
    private func touch(_ type: String, _ id: String) {
        dirty["\(type):\(id)"] = uid()
        save()
        syncSoon?.cancel()
        syncSoon = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { await syncNow() }
        }
    }

    func showToast(_ text: String, undo: (() -> Void)? = nil) {
        let toast = Toast(text: text, undo: undo)
        self.toast = toast
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.toast?.id == toast.id { self.toast = nil }
        }
    }

    func undo() {
        let action = toast?.undo
        toast = nil
        action?()
    }

    // ------------------------------------------------------------------------------------------------ to-dos
    func add(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = Item(id: uid(), text: text, created: now())
        items.insert(item, at: 0)
        touch("item", item.id)
    }

    // Ticked: struck through for a moment (tick again to keep it), then it leaves
    func toggleDone(_ id: String) {
        if leaving[id] != nil {
            leaving[id] = nil
            return
        }
        let ticket = UUID()
        leaving[id] = ticket
        Task {
            try? await Task.sleep(nanoseconds: Self.doneDelay)
            guard leaving[id] == ticket else { return }
            withAnimation(.easeOut(duration: 0.25)) { remove(id, verb: "Done") }
        }
    }

    func remove(_ id: String, verb: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.ringing = nil
        leaving[id] = nil
        cancelReminder(id)
        touch("item", id)
        showToast("\(verb): \(items.isEmpty ? "list clear" : truncate(item.text))") { [weak self] in
            guard let self else { return }
            self.items.insert(item, at: min(index, self.items.count))
            self.touch("item", id)
            self.schedule(item)
        }
    }

    func edit(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty {
            remove(id, verb: "Deleted")
        } else if text != items[index].text {
            items[index].text = text
            touch("item", id)
            schedule(items[index])
        }
    }

    // ------------------------------------------------------------------------------------------------ reminders
    func setReminder(_ id: String, at: Int?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].remindAt = at
        items[index].ringing = nil
        save()
        schedule(items[index])
    }

    // The notification that rings it when the app isn't open
    private func schedule(_ item: Item) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [item.id])
        guard let at = item.remindAt, at > now() else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Reminder"
        content.body = item.text
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(at - now()) / 1000), repeats: false)
        center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
    }

    private func cancelReminder(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    // Tapping a ringing item stops it (the item stays on the list)
    func stopRinging(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].ringing = nil
        save()
        cancelReminder(id)
    }

    // Every second while the app is open: due reminders ring, and a ringing one chimes every 4 seconds
    func tick() {
        let time = now()
        var rang = false
        for index in items.indices where (items[index].remindAt ?? .max) <= time && items[index].ringing != true {
            items[index].remindAt = nil
            items[index].ringing = true
            rang = true
        }
        if rang { save() }
        if items.contains(where: { $0.ringing == true }) && Date().timeIntervalSince(lastChime) >= 4 {
            lastChime = Date()
            AudioServicesPlayAlertSound(SystemSoundID(1007))
        }
    }

    // ------------------------------------------------------------------------------------------------ machines
    private func updateMachine(_ id: String, _ change: (inout Machine) -> Void) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        change(&machines[index])
        touch("machine", id)
    }

    func addMachine(name: String, ip: String) {
        let machine = Machine(id: uid(), name: name, ip: ip, locked: false, draftAppliedAt: nil, created: now())
        machines.append(machine)
        touch("machine", machine.id)
    }

    func toggleLock(_ id: String) { updateMachine(id) { $0.locked.toggle() } }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { updateMachine(id) { $0.name = name } }
    }

    func setIP(_ id: String, to ip: String) {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        if !ip.isEmpty { updateMachine(id) { $0.ip = ip } }
    }

    // Stamped when I apply their draft (Undo takes it back)
    func applyDraft(_ id: String) {
        guard let machine = machines.first(where: { $0.id == id }) else { return }
        let previous = machine.draftAppliedAt
        updateMachine(id) { $0.draftAppliedAt = now() }
        showToast("Draft applied: \(machine.name)") { [weak self] in
            self?.updateMachine(id) { $0.draftAppliedAt = previous }
        }
    }

    func removeMachine(_ id: String) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        let machine = machines.remove(at: index)
        touch("machine", id)
        showToast("Deleted: \(machine.name)") { [weak self] in
            guard let self else { return }
            self.machines.insert(machine, at: min(index, self.machines.count))
            self.touch("machine", id)
        }
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    // ------------------------------------------------------------------------------------------------ sync
    func configure(url: String, token: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url != serverURL || token != self.token else { return }
        UserDefaults.standard.set(url, forKey: "serverURL")
        UserDefaults.standard.set(token, forKey: "token")
        // Another server: everything here goes up to it, and all of it comes down
        rev = nil
        save()
        objectWillChange.send()
    }

    func syncNow() async {
        guard let url = URL(string: serverURL), url.scheme != nil, !token.isEmpty else {
            sync = .off
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        if rev == nil {
            for item in items { dirty["item:\(item.id)"] = dirty["item:\(item.id)"] ?? uid() }
            for machine in machines { dirty["machine:\(machine.id)"] = dirty["machine:\(machine.id)"] ?? uid() }
        }
        let sent = dirty
        let changes = sent.keys.map { key -> Change in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let type = parts[0]
            let id = parts.count > 1 ? parts[1] : ""
            if type == "item", let item = items.first(where: { $0.id == id }) {
                return Change(type: type, id: id, data: item.shared)
            }
            if type == "machine", let machine = machines.first(where: { $0.id == id }) {
                return Change(type: type, id: id, data: machine.shared)
            }
            return Change(type: type, id: id, deleted: true)
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(SyncRequest(token: token, since: rev ?? 0, changes: changes))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                sync = .failed(code == 403 ? "Wrong token" : "Server answered \(code)")
                return
            }
            let reply = try JSONDecoder().decode(SyncReply.self, from: data)
            // Up, unless changed again meanwhile
            for (key, version) in sent where dirty[key] == version {
                dirty[key] = nil
            }
            apply(reply.changes)
            rev = reply.rev
            save()
            sync = .synced(Date())
        } catch {
            sync = .failed(error.localizedDescription)
        }
    }

    // The other devices' changes, except for records changed here since (those go up next)
    private func apply(_ records: [Change]) {
        var itemsChanged = false
        var machinesChanged = false
        for r in records where dirty["\(r.type):\(r.id)"] == nil {
            if r.type == "item" {
                let index = items.firstIndex { $0.id == r.id }
                guard r.deleted != true, let d = r.data else {
                    if let index {
                        cancelReminder(r.id)
                        leaving[r.id] = nil
                        items.remove(at: index)
                        itemsChanged = true
                    }
                    continue
                }
                let fresh = Item(id: r.id, text: d.text ?? "", created: d.created ?? 0)
                if let index {
                    if items[index].shared != fresh.shared {
                        items[index].text = fresh.text
                        items[index].created = fresh.created
                        schedule(items[index])
                        itemsChanged = true
                    }
                } else {
                    items.append(fresh)
                    itemsChanged = true
                }
            } else if r.type == "machine" {
                let index = machines.firstIndex { $0.id == r.id }
                guard r.deleted != true, let d = r.data else {
                    if let index {
                        machines.remove(at: index)
                        machinesChanged = true
                    }
                    continue
                }
                let fresh = Machine(id: r.id, name: d.name ?? "", ip: d.ip ?? "", locked: d.locked ?? false, draftAppliedAt: d.draftAppliedAt, created: d.created ?? 0)
                if let index {
                    if machines[index] != fresh {
                        machines[index] = fresh
                        machinesChanged = true
                    }
                } else {
                    machines.append(fresh)
                    machinesChanged = true
                }
            }
        }
        if itemsChanged { items.sort { $0.created > $1.created } }
        if machinesChanged { machines.sort { $0.created < $1.created } }
    }
}

func truncate(_ s: String) -> String {
    s.count > 28 ? String(s.prefix(27)) + "…" : s
}
