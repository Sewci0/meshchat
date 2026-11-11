import MeshChatCore
import MeshCoreKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension NotifyLevel: Identifiable {
    public var id: Self { self }
}

/// Settings › Notifications: iOS's permission, the master switch and what notifications show, the
/// defaults for rooms and channels and the conversations set differently, then what keeps working in
/// the background: staying connected over WiFi, and the radio's status on the lock screen.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = $model.notificationSettings
        let changed = model.notificationSettings.perConversation.keys.compactMap(ConversationID.init).sorted { model.title(of: $0) < model.title(of: $1) }
        Form {
            permission
            Section {
                Toggle("Notifications", isOn: s.enabled)
                Group {
                    Toggle("Show message text", isOn: s.showText)
                    Toggle("Sound", isOn: s.sound)
                    Toggle("Unread count on the app icon", isOn: s.badge)
                }
                .disabled(!model.notificationSettings.enabled)
            } footer: {
                Text("Message text also follows iOS's Show Previews setting, for the lock screen.")
            }
            Section {
                LabeledContent("Direct messages", value: NotifyLevel.all.label)
                Picker("Rooms", selection: s.roomDefault) { ForEach(NotifyLevel.allCases) { Text($0.label).tag($0) } }
                Picker("Channels", selection: s.channelDefault) { ForEach(NotifyLevel.allCases) { Text($0.label).tag($0) } }
            } header: {
                Text("By default")
            } footer: {
                Text("A mention is your name as @[\(model.me?.name ?? String(localized: "name"))], which Reply puts in front of a message. Each conversation can be set differently from its ••• menu, or by touching and holding it in Chats. Quiet ones, like channel chatter and messages more than 15 minutes old, go straight to Notification Center.")
            }
            .disabled(!model.notificationSettings.enabled)
            if !changed.isEmpty {
                Section {
                    ForEach(changed, id: \.self) { c in
                        LabeledContent(model.title(of: c), value: summary(c))
                            .swipeActions { Button("Reset") { model.notificationSettings.forget(c) }.tint(.accentColor) }
                    }
                } header: {
                    Text("Set differently")
                } footer: {
                    Text("Swipe to go back to the default.")
                }
            }
            Section {
                if case .wifi = model.savedRadio {
                    Toggle("Stay connected in the background", isOn: $model.keepRunningInBackground)
                    if model.keepRunningInBackground && model.backgroundBlocked {
                        Label("Location access is off for MeshChat, so iOS pauses it in the background.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        #if os(iOS)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        #endif
                    }
                }
                Toggle("Radio status on the lock screen", isOn: $model.lockScreenStatus)
                if !model.liveActivitiesAllowed {
                    Label("Live Activities are off for MeshChat in iOS Settings.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("In the background")
            } footer: {
                Text(background)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
    }

    @ViewBuilder private var permission: some View {
        switch model.notificationPermission {
        case .notAsked:
            Section {
                Button("Turn on notifications") { Task { await model.askNotificationPermission?() } }
            } footer: {
                Text("iOS asks once whether MeshChat may notify you.")
            }
        case .denied:
            Section {
                Label("Notifications are off for MeshChat in iOS Settings.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                #if os(iOS)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
                #endif
            }
        case .allowed, .unknown:
            EmptyView()
        }
    }

    private func summary(_ c: ConversationID) -> String {
        let s = model.notificationSettings, kind = model.kind(of: c)
        if let until = s.mutedUntil(c) {
            return until == .distantFuture ? String(localized: "Muted") : String(localized: "Muted until \(until.formatted(date: .omitted, time: .shortened))")
        }
        return s.level(for: c, kind: kind).label
    }

    private var background: String {
        let status = String(localized: "The lock screen status is a Live Activity; iOS ends it after 8 hours and MeshChat starts a new one when you next open it.")
        if case .wifi = model.savedRadio {
            return String(localized: "Over WiFi, iOS pauses MeshChat soon after you leave it. Staying connected uses iOS location updates at the coarsest accuracy, the only way iOS allows this: a little battery and a blue location pill. Your position isn't sent anywhere.") + " " + status
        }
        return String(localized: "Over Bluetooth, messages keep arriving while MeshChat is in the background. Notifications are made on this iPhone; nothing goes through a server.") + " " + status
    }
}

/// A conversation's notification choice, as a submenu: its level (or the default for its kind) and
/// muting for a while.
struct NotifyMenu: View {
    @Environment(AppModel.self) private var model
    let conversation: ConversationID

    var body: some View {
        let s = model.notificationSettings, kind = model.kind(of: conversation)
        let muted = s.mutedUntil(conversation)
        Menu {
            Picker("Notify", selection: Binding(get: { s.perConversation[conversation.description]?.level },
                                                set: { model.notificationSettings.set($0, for: conversation) })) {
                Text("Default: \(s.defaultLevel(kind).label)").tag(NotifyLevel?.none)
                ForEach(kind == .direct ? [NotifyLevel.all, .off] : NotifyLevel.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
            Divider()
            if let muted {
                Button { model.notificationSettings.mute(conversation, until: nil) } label: {
                    Label(muted == .distantFuture ? "Unmute" : "Unmute (muted until \(muted.formatted(date: .omitted, time: .shortened)))",
                          systemImage: "bell")
                }
            } else {
                Button { mute(3600) } label: { Label("Mute for 1 hour", systemImage: "bell.slash") }
                Button { mute(8 * 3600) } label: { Label("Mute for 8 hours", systemImage: "bell.slash") }
                Button { model.notificationSettings.mute(conversation, until: .distantFuture) } label: {
                    Label("Mute until I turn it back on", systemImage: "bell.slash")
                }
            }
        } label: {
            Label("Notifications", systemImage: s.effectiveLevel(for: conversation, kind: kind) == .off ? "bell.slash" : "bell")
        }
    }

    private func mute(_ seconds: TimeInterval) {
        model.notificationSettings.mute(conversation, until: .now.addingTimeInterval(seconds))
    }
}

/// A small bell-with-a-line on conversations that don't notify (off or muted).
struct SilencedMark: View {
    @Environment(AppModel.self) private var model
    let conversation: ConversationID

    var body: some View {
        if model.notificationSettings.effectiveLevel(for: conversation, kind: model.kind(of: conversation)) == .off {
            Image(systemName: "bell.slash.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Notifications off")
        }
    }
}
