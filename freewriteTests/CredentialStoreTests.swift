//
//  CredentialStoreTests.swift
//  freewriteTests
//
//  The Keychain credential store against the real Keychain (a throwaway service name).
//

import Foundation
import PiDurableKit
import Security
import Testing
@testable import freewrite

struct CredentialStoreTests {
    private let store = FreewriteCredentialStore(service: "app.humansongs.freewrite.tests.\(UUID().uuidString)")

    /// What an ad-hoc signed build does when the data-protection keychain refuses the write.
    private func saveInLoginKeychain(_ credential: Credential, for provider: ProviderID) throws {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: store.service,
            kSecAttrAccount: provider.rawValue, kSecValueData: try JSONEncoder().encode(credential),
        ]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    }

    @Test func aCredentialInTheLoginKeychainIsFound() throws {
        defer { try? store.setCredential(nil, for: "openai") }
        try saveInLoginKeychain(.apiKey("sk-test-login"), for: "openai")
        #expect(try store.credential(for: "openai")?.apiKey == "sk-test-login")
        #expect(try store.providers() == ["openai"])
        // Signing out removes it.
        try store.setCredential(nil, for: "openai")
        #expect(try store.credential(for: "openai") == nil)
        #expect(try store.providers().isEmpty)
    }

    @Test func savedCredentialsReadBack() throws {
        defer { try? store.setCredential(nil, for: "anthropic") }
        try store.setCredential(.apiKey("sk-ant-test"), for: "anthropic")
        #expect(try store.credential(for: "anthropic")?.apiKey == "sk-ant-test")
        try store.setCredential(.apiKey("sk-ant-test-2"), for: "anthropic")
        #expect(try store.credential(for: "anthropic")?.apiKey == "sk-ant-test-2")
        #expect(try store.providers() == ["anthropic"])
    }
}
