import AppKit
import SwiftUI
import VisionOneKit

/// Connects the creator's own free Cloudflare account with one token.
/// Vision One then makes the storage, the notes database and the share
/// server there, and every share page gets a link with notes, reactions
/// and insights. Nothing is hosted by Vision One.
struct ConnectCloudflareSheet: View {
    @ObservedObject private var connection = CloudflareConnection.shared
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private static let tokenPage = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!
    private static let signUp = URL(string: "https://dash.cloudflare.com/sign-up")!

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Share pages on your Cloudflare").textStyle(.title).foregroundStyle(Theme.text)
            if let account = connection.account, !connection.isConnecting {
                connected(account)
            } else {
                steps
            }
            HStack {
                Spacer()
                Button(connection.account == nil ? "Cancel" : "Done") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .background(Theme.canvas)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Free for most people: 10 GB of video (about 60 short videos) and 100,000 views a day. Cloudflare asks for a card to switch on video storage, but doesn't charge under those limits.")
                .textStyle(.body)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            numbered(1, "Sign in to Cloudflare, or make a free account.") {
                Button("Open Cloudflare") { NSWorkspace.shared.open(Self.signUp) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            numbered(2, "Turn on R2 (video storage) in the dashboard.") { EmptyView() }
            numbered(3, "Make an API token with these permissions: Workers Scripts Edit, Workers R2 Storage Edit, D1 Edit, Account Settings Read.") {
                Button("Open API tokens") { NSWorkspace.shared.open(Self.tokenPage) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            numbered(4, "Paste the token here.") {
                SecureField("Cloudflare API token", text: $token)
                    .textFieldStyle(.ink)
            }
            if let step = connection.step {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(CloudflareShareSetup.Step.allCases, id: \.self) { s in
                        HStack(spacing: 6) {
                            Image(systemName: mark(s, current: step))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .frame(width: 14)
                            Text(s.title).textStyle(.body).foregroundStyle(order(s) <= order(step) ? Theme.text : Theme.textMuted)
                        }
                    }
                    if connection.waitingForAddress {
                        Text("Cloudflare is switching your new address on. This can take a minute.")
                            .textStyle(.caption).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            if let error = connection.error {
                Notice(.error, lead: "Couldn't connect", detail: error)
            }
            Button(connection.isConnecting ? "Connecting…" : "Connect") {
                Task { await connection.connect(token: token) }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || connection.isConnecting)
            Text("The token stays in your Mac's keychain. Vision One uses it only to set up and update the share server.")
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connected(_ account: CloudflareShareAccount) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Connected. Share pages go to:").textStyle(.body).foregroundStyle(Theme.text)
            Mono(account.baseURL.absoluteString.replacingOccurrences(of: "https://", with: ""))
            HStack(spacing: Theme.Space.sm) {
                Button("Update the share server") {
                    if let saved = AIServices.shared.secrets.string(CloudflareSecretName.apiToken) {
                        Task { await connection.connect(token: saved) }
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                Button("Disconnect") { connection.disconnect() }
                    .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
            }
            Text("Disconnecting forgets the account on this Mac. Pages already up stay up.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
            if let error = connection.error { Notice(.error, lead: "Couldn't update", detail: error) }
        }
    }

    private func numbered<Extra: View>(_ n: Int, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Mono("\(n)").foregroundStyle(Theme.textMuted).frame(width: 14)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).textStyle(.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }

    private func order(_ step: CloudflareShareSetup.Step) -> Int {
        CloudflareShareSetup.Step.allCases.firstIndex(of: step) ?? 0
    }

    private func mark(_ step: CloudflareShareSetup.Step, current: CloudflareShareSetup.Step) -> String {
        order(step) < order(current) ? "checkmark" : (step == current ? "circle.dotted" : "circle")
    }
}
