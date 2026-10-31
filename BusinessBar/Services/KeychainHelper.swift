import Foundation
import Security

enum KeychainHelper {
    struct Operations {
        var add: (CFDictionary) -> OSStatus
        var copy: (CFDictionary) -> (OSStatus, AnyObject?)
        var delete: (CFDictionary) -> OSStatus

        static var live: Operations {
            Operations(add: { SecItemAdd($0, nil) }, copy: {
                var result: AnyObject?
                let status = SecItemCopyMatching($0, &result)
                return (status, result)
            }, delete: { SecItemDelete($0) })
        }
    }

    static func save(key: String, data: Data, operations: Operations = .live) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        _ = operations.delete(query as CFDictionary)
        
        let status = operations.add(query as CFDictionary)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    static func load(key: String, operations: Operations = .live) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        let (status, result) = operations.copy(query as CFDictionary)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw KeychainError.loadFailed(status)
        }
        
        return data
    }
    
    static func delete(key: String, operations: Operations = .live) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        let status = operations.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    enum KeychainError: Error {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
    }
}
