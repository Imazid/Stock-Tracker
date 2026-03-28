//
//  UserDefaults+Extensions.swift
//  Stock Tracker
//
//  Helper extensions for cleaner UserDefaults usage
//

import Foundation

extension UserDefaults {
    
    // MARK: - Codable Storage
    
    func setCodable<T: Codable>(_ value: T, forKey key: String) {
        if let encoded = try? JSONEncoder().encode(value) {
            set(encoded, forKey: key)
            synchronize()
        }
    }
    
    func getCodable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    
    // MARK: - Array Storage
    
    func setCodableArray<T: Codable>(_ array: [T], forKey key: String) {
        if let encoded = try? JSONEncoder().encode(array) {
            set(encoded, forKey: key)
            synchronize()
        }
    }
    
    func getCodableArray<T: Codable>(_ type: T.Type, forKey key: String) -> [T]? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }
}
