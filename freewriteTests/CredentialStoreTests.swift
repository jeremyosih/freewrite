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

/// Whether this test build can write to the data-protection keychain (signed with a team ID).
/// Ad-hoc and unsigned builds get errSecMissingEntitlement, like the dev app.
private let hasDataProtectionKeychain: Bool = {
    let item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword, kSecAttrService: "app.humansongs.freewrite.tests.probe.\(UUID().uuidString)",
        kSecAttrAccount: "probe", kSecValueData: Data("x".utf8), kSecUseDataProtectionKeychain: true,
    ]
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
    SecItemDelete(item.filter { $0.key != kSecValueData } as CFDictionary)
    return true
}()

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

    private func saveInDataProtectionKeychain(_ credential: Credential, for provider: ProviderID) throws {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: store.service, kSecAttrAccount: provider.rawValue,
            kSecValueData: try JSONEncoder().encode(credential), kSecUseDataProtectionKeychain: true,
        ]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    }

    private func loginKeychainCopy(for provider: ProviderID) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: store.service, kSecAttrAccount: provider.rawValue]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Both keychains hold a copy (a build that gained a team ID after saving in the login keychain).
    @Test(.enabled(if: hasDataProtectionKeychain, "needs a build that can use the data-protection keychain"))
    func theDataProtectionCopyWinsAndBothAreCleanedUp() throws {
        defer { try? store.setCredential(nil, for: "openai") }
        try saveInLoginKeychain(.apiKey("sk-old-login"), for: "openai")
        try saveInDataProtectionKeychain(.apiKey("sk-new-protected"), for: "openai")
        #expect(try store.credential(for: "openai")?.apiKey == "sk-new-protected")
        #expect(try store.providers() == ["openai"])  // listed once
        // Saving goes to the data-protection keychain and drops the stale login copy.
        try store.setCredential(.apiKey("sk-saved"), for: "openai")
        #expect(!loginKeychainCopy(for: "openai"))
        #expect(try store.credential(for: "openai")?.apiKey == "sk-saved")
        // Signing out removes both.
        try saveInLoginKeychain(.apiKey("sk-old-login"), for: "openai")
        try store.setCredential(nil, for: "openai")
        #expect(try store.credential(for: "openai") == nil)
        #expect(!loginKeychainCopy(for: "openai"))
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
