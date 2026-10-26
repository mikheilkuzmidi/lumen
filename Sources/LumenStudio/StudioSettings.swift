import Foundation
import LocalAuthentication
import Security
import SwiftUI
import LumenCore

/// Stores model service keys as generic passwords.
enum StudioKeychain {
    enum Account: String {
        case meta = "meta-api-key"
        case provider = "spark-open-api-key"
    }

    private static func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Lumen",
         kSecAttrAccount as String: account.rawValue]
    }

    static func read(account: Account = .meta, allowInteraction: Bool = true) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(message: "The saved key couldn't be read. Remove it and save it again.")
        }
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String, account: Account = .meta) throws {
        let query = query(account)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    static func remove(account: Account = .meta) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    static func runtimeKey(allowInteraction: Bool = true) throws -> String {
        let environmentKey = ProcessInfo.processInfo.environment["META_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let key = try read(allowInteraction: allowInteraction) { return key }
        } catch {
            if let environmentKey, !environmentKey.isEmpty { return environmentKey }
            throw error
        }
        if let environmentKey, !environmentKey.isEmpty { return environmentKey }
        throw LumenError.missingKey
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        throw KeychainError(message: message)
    }

    private struct KeychainError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct StudioSettingsView: View {
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var message: String?
    @State private var failed = false
    @State private var providerURL = StudioPreferences.providerURL
    @State private var providerModel = StudioPreferences.providerModel
    @State private var providerKey = ""
    @State private var hasProviderKey = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal")
                        .font(.title2)
                        .foregroundStyle(StudioStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Meta API key").font(.headline)
                        Text("Saved in this Mac’s Keychain. Read only when you run an edit.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                SecureField("Paste your API key", text: $key)
                    .textContentType(.password)
                    .onSubmit(save)
                HStack {
                    Button("Save Key", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove", role: .destructive, action: remove)
                        .disabled(!hasSavedKey)
                    Spacer()
                    if hasSavedKey {
                        Label("Key saved", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(StudioStyle.accent)
                    }
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Link("Get a key at dev.meta.ai ↗", destination: URL(string: "https://dev.meta.ai")!)
                Text("If no key is saved, Lumen reads META_API_KEY from its environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Muse Spark Open") {
                TextField("Provider base URL", text: $providerURL, prompt: Text("https://your-provider.example/v1"))
                TextField("Model ID", text: $providerModel)
                SecureField("Provider API key", text: $providerKey)
                    .textContentType(.password)
                Text("The provider plans and checks. SAM 3.1 and Muse Image still need your Meta key. The provider key stays in this Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save Provider", action: saveProvider)
                        .buttonStyle(.borderedProminent)
                    Button("Remove Provider Key", role: .destructive, action: removeProvider)
                        .disabled(!hasProviderKey)
                    Spacer()
                    if hasProviderKey { Text("Key saved").font(.caption).foregroundStyle(StudioStyle.accent) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 650)
        .onAppear {
            do {
                hasSavedKey = try StudioKeychain.read() != nil
                hasProviderKey = try StudioKeychain.read(account: .provider) != nil
            }
            catch { show(error) }
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try StudioKeychain.save(value)
            key = ""
            hasSavedKey = true
            message = "Your key is saved."
            failed = false
        } catch { show(error) }
    }

    private func remove() {
        do {
            try StudioKeychain.remove()
            key = ""
            hasSavedKey = false
            message = "The saved key was removed."
            failed = false
        } catch { show(error) }
    }

    private func show(_ error: any Error) {
        message = error.localizedDescription
        failed = true
    }

    private func saveProvider() {
        do {
            let enteredKey = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedKey = try enteredKey.isEmpty ? StudioKeychain.read(account: .provider) : enteredKey
            let provider = try StudioProvider(baseURL: providerURL, key: savedKey, modelID: providerModel)
            if !enteredKey.isEmpty { try StudioKeychain.save(provider.key, account: .provider) }
            StudioPreferences.providerURL = provider.baseURL.absoluteString
            StudioPreferences.providerModel = provider.modelID
            providerKey = ""
            hasProviderKey = true
            message = "Your provider is saved."
            failed = false
            NotificationCenter.default.post(name: .studioProviderChanged, object: nil)
        } catch { show(error) }
    }

    private func removeProvider() {
        do {
            try StudioKeychain.remove(account: .provider)
            providerKey = ""
            hasProviderKey = false
            message = "The provider key was removed."
            failed = false
            NotificationCenter.default.post(name: .studioProviderChanged, object: nil)
        } catch { show(error) }
    }
}

extension Notification.Name {
    static let studioProviderChanged = Notification.Name("LumenStudioProviderChanged")
}
