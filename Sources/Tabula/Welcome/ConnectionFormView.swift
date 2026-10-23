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
                Section("Sicurezza") {
                    Picker("Modalità", selection: $draft.safeMode) {
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
            Text("Connessione \(draft.driver.rawValue)").font(.headline)
            Spacer()
            Picker("", selection: $draft.driver) {
                ForEach(Driver.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding([.horizontal, .top], 20)
    }

    private var generalSection: some View {
        Section {
            TextField("Nome", text: $draft.name, prompt: Text("La mia connessione"))
            Picker("Tag", selection: $draft.tag) {
                ForEach(ConnectionTag.allCases, id: \.self) { tag in
                    Label { Text(tag.title) } icon: { Circle().fill(tag.color) }.tag(tag)
                }
            }
            TextField("Gruppo", text: $draft.group, prompt: Text("facoltativo"))
        }
    }

    private var postgresSection: some View {
        Section("Server") {
            TextField("Host/Socket", text: $draft.postgres.host, prompt: Text("127.0.0.1"))
            TextField("Porta", text: $draft.portText, prompt: Text("5432"))
            TextField("Utente", text: $draft.postgres.user, prompt: Text("user name"))
            HStack {
                SecureField("Password", text: $draft.password, prompt: Text("password"))
                    .disabled(draft.postgres.passwordStorage == .none)
                Picker("", selection: $draft.postgres.passwordStorage) {
                    Text("Salva nel Portachiavi").tag(PasswordStorage.keychain)
                    Text("Chiedi ogni volta").tag(PasswordStorage.askEveryTime)
                    Text("Nessuna password").tag(PasswordStorage.none)
                }
                .labelsHidden()
                .fixedSize()
            }
            TextField("Database", text: $draft.postgres.database, prompt: Text("database name"))
            Picker("Modalità SSL", selection: $draft.postgres.sslMode) {
                ForEach(SSLMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var dsqlSection: some View {
        Section {
            TextField("Endpoint", text: $draft.dsql.endpoint, prompt: Text("abc123.dsql.eu-west-1.on.aws"))
            TextField("Regione", text: $draft.dsql.region, prompt: Text(DSQLEndpoint.region(from: draft.dsql.endpoint) ?? "automatica"))
            Picker("Profilo AWS", selection: $draft.dsql.awsProfile) {
                Text("Catena predefinita").tag("")
                ForEach(profiles, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Ruolo admin", isOn: $draft.dsqlUsesAdmin)
            if !draft.dsqlUsesAdmin {
                TextField("Ruolo database", text: $draft.dsql.user, prompt: Text("app_reader"))
            }
            TextField("Database", text: $draft.dsql.database, prompt: Text("postgres"))
            Picker("Durata token", selection: $draft.dsql.tokenLifetimeSeconds) {
                Text("5 minuti").tag(300)
                Text("15 minuti").tag(900)
                Text("1 ora").tag(3600)
            }
        } header: {
            Text("Aurora DSQL")
        } footer: {
            Text("La password è un token IAM generato con la AWS CLI e le credenziali locali del profilo. Tabula lo rinnova da sola e ricrea la connessione prima del limite di 60 minuti di DSQL.")
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
                        Text("es. bash ~/scripts/db-tunnel-prod.sh")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Toggle("Apre un tunnel: attendi che \(endpointLabel) risponda", isOn: $draft.script.waitsForPort)
            Stepper("Attesa massima: \(draft.script.timeoutSeconds) s", value: $draft.script.timeoutSeconds, in: 5...300, step: 5)
        } header: {
            Text("Prima della connessione")
        } footer: {
            Text(draft.script.waitsForPort
                ? "Lo script gira in una shell di login (zsh) e può restare attivo: Tabula lo lancia solo se la porta non risponde già, lo rilancia se il tunnel cade e lo chiude con l'ultima finestra che lo usa."
                : "Lo script gira in una shell di login (zsh) a ogni connessione e deve terminare con successo prima che Tabula si colleghi.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var endpointLabel: String {
        switch draft.driver {
        case .postgres: "\(draft.postgres.host.isEmpty ? "host" : draft.postgres.host):\(draft.portText)"
        case .dsql: "l'endpoint"
        }
    }

    private var footer: some View {
        HStack {
            testStatus
            Spacer()
            Button("Annulla") { onFinish(nil, false) }.keyboardShortcut(.cancelAction)
            Button("Prova") { Task { await test() } }
            Button("Salva") { save(connect: false) }
            Button("Connetti") { save(connect: true) }.keyboardShortcut(.defaultAction)
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
            testState = .succeeded("Connesso come \(user)")
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
            try model.save(connection, password: draft.driver == .postgres ? draft.password : nil)
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
