//
//  DeviceIdentity.swift
//  Kurn
//
//  A per-install identifier stamped on every `Recording` this device
//  creates. Once iCloud sync mirrors rows to another device, only the one
//  that recorded may reconcile a row's capture or transcription state: the
//  other has no audio file and would otherwise mark a live recording as
//  needing recovery and sync that back.
//

import Foundation

enum DeviceIdentity {
    static let defaultsKey = "device.identity"

    /// Created on first use and kept for the life of the install.
    static let current: String = current(in: .standard)

    static func current(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: defaultsKey)
        return created
    }
}
