import Foundation
import Security
import SwiftUI
import LumenCore

/// Stores the user's Meta key as a generic password.
enum StudioKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Lumen",
         kSecAttrAccount as String: "meta-api-key"]
    }

    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(message: "The saved Meta key couldn't be read. Remove it and save it again.")
        }
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) throws {
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

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    static func runtimeKey() throws -> String {
        if let key = try read() { return key }
        if let key = ProcessInfo.processInfo.environment["META_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty { return key }
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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 350)
        .onAppear {
            do { hasSavedKey = try StudioKeychain.read() != nil }
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
}
