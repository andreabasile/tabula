import SwiftUI
import TabulaCore

struct ConnectionFormView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ConnectionDraft
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    private let profiles = AWSProfiles.load()
    let onFinish: (ConnectionConfig?, _ connect: Bool) -> Void

    init(draft: ConnectionDraft, onFinish: @escaping (ConnectionConfig?, Bool) -> Void) {
        _draft = State(initialValue: draft)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                generalSection
                switch draft.driver {
                case .postgres: postgresSection
                case .dsql: dsqlSection
                }
                scriptSection
                Section("Security") {
                    Picker("Mode", selection: $draft.safeMode) {
                        ForEach(SafeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 560)
        .onChange(of: draft.tag) { _, tag in
            if tag.isProduction, draft.safeMode == .silent { draft.safeMode = .alertWrites }
        }
    }

    private var header: some View {
        HStack {
            DriverIcon(kind: draft.makeConnection().kind, size: 28)
            Text("\(draft.driver.rawValue) Connection").font(.headline)
            Spacer()
            Picker(selection: $draft.driver) {
                ForEach(Driver.allCases) { Text($0.rawValue).tag($0) }
            } label: {}
            .labelsHidden()
            .fixedSize()
        }
        .padding([.horizontal, .top], 20)
    }

    private var generalSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("My Connection"))
            Picker("Tag", selection: $draft.tag) {
                ForEach(ConnectionTag.allCases, id: \.self) { tag in
                    Label { Text(tag.title) } icon: { Circle().fill(tag.color) }.tag(tag)
                }
            }
            TextField("Group", text: $draft.group, prompt: Text("optional"))
        }
    }

    private var postgresSection: some View {
        Section("Server") {
            TextField("Host/Socket", text: $draft.postgres.host, prompt: Text(verbatim: "127.0.0.1"))
            TextField("Port", text: $draft.portText, prompt: Text(verbatim: "5432"))
            TextField("User", text: $draft.postgres.user, prompt: Text("user name"))
            HStack {
                SecureField("Password", text: $draft.password, prompt: draft.passwordUnreadable ? Text("unchanged (Keychain not readable)") : Text("password"))
                    .disabled(draft.postgres.passwordStorage == .none)
                Picker(selection: $draft.postgres.passwordStorage) {
                    Text("Save to Keychain").tag(PasswordStorage.keychain)
                    Text("Ask every time").tag(PasswordStorage.askEveryTime)
                    Text("No password").tag(PasswordStorage.none)
                } label: {}
                .labelsHidden()
                .fixedSize()
            }
            TextField("Database", text: $draft.postgres.database, prompt: Text("database name"))
            Picker("SSL mode", selection: $draft.postgres.sslMode) {
                ForEach(SSLMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private var dsqlSection: some View {
        Section {
            TextField("Endpoint", text: $draft.dsql.endpoint, prompt: Text(verbatim: "abc123.dsql.eu-west-1.on.aws"))
            TextField("Region", text: $draft.dsql.region, prompt: Text(DSQLEndpoint.region(from: draft.dsql.endpoint) ?? String(localized: "automatic")))
            Picker("AWS profile", selection: $draft.dsql.awsProfile) {
                Text("Default chain").tag("")
                ForEach(profiles, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Admin role", isOn: $draft.dsqlUsesAdmin)
            if !draft.dsqlUsesAdmin {
                TextField("Database role", text: $draft.dsql.user, prompt: Text(verbatim: "app_reader"))
            }
            TextField("Database", text: $draft.dsql.database, prompt: Text(verbatim: "postgres"))
            Picker("Token lifetime", selection: $draft.dsql.tokenLifetimeSeconds) {
                Text("5 minutes").tag(300)
                Text("15 minutes").tag(900)
                Text("1 hour").tag(3600)
            }
        } header: {
            Text(verbatim: "Aurora DSQL")
        } footer: {
            Text("The password is an IAM token generated with the AWS CLI and the profile’s local credentials. Tabula renews it automatically and recreates the connection before DSQL’s 60-minute limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var scriptSection: some View {
        Section {
            TextEditor(text: $draft.script.script)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topLeading) {
                    if draft.script.script.isEmpty {
                        Text("e.g. bash ~/scripts/db-tunnel-prod.sh")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Toggle("Opens a tunnel: wait for \(endpointLabel) to respond", isOn: $draft.script.waitsForPort)
            Stepper("Max wait: \(draft.script.timeoutSeconds) s", value: $draft.script.timeoutSeconds, in: 5...300, step: 5)
        } header: {
            Text("Before connecting")
        } footer: {
            Text(draft.script.waitsForPort
                ? "The script runs in a login shell (zsh) and can keep running: Tabula launches it only if the port isn’t already responding, relaunches it if the tunnel drops, and stops it when the last window using it closes."
                : "The script runs in a login shell (zsh) on every connection and must finish successfully before Tabula connects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var endpointLabel: String {
        switch draft.driver {
        case .postgres: "\(draft.postgres.host.isEmpty ? String(localized: "host") : draft.postgres.host):\(draft.portText)"
        case .dsql: String(localized: "the endpoint")
        }
    }

    private var footer: some View {
        HStack {
            testStatus
            Spacer()
            Button("Cancel") { onFinish(nil, false) }.keyboardShortcut(.cancelAction)
            Button("Test") { Task { await test() } }
            Button("Save") { save(connect: false) }
            Button("Connect") { save(connect: true) }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var testStatus: some View {
        if let message = saveError ?? draft.validationMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else {
            switch testState {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .succeeded(let detail): Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private func test() async {
        guard draft.validationMessage == nil else { return }
        testState = .running
        let connection = draft.makeConnection()
        let password = draft.password
        let owner = UUID()
        let session = model.sessionFactory.makeSession(for: connection, owner: owner) { password.isEmpty ? nil : password }
        do {
            let result = try await session.execute("SELECT current_user, version()")
            let user = result.rows.first?.first?.displayText ?? "?"
            testState = .succeeded(String(localized: "Connected as \(user)"))
        } catch {
            testState = .failed(error.localizedDescription)
        }
        await session.close()
        await model.sessionFactory.tunnels.release(owner: owner)
    }

    private func save(connect: Bool) {
        guard draft.validationMessage == nil else { return }
        let connection = draft.makeConnection()
        do {
            try model.save(connection, password: draft.driver == .postgres ? draft.password : nil, keepingStoredPassword: draft.passwordUnreadable && draft.password.isEmpty)
            onFinish(connection, connect)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private enum TestState {
    case idle, running
    case succeeded(String)
    case failed(String)
}
