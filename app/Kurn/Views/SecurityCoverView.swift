//
//  SecurityCoverView.swift
//  Kurn
//
//  Content hosted by the security cover window: the privacy placeholder, or
//  the lock screen. `AppSettings.requireAuthForRecordings` is always false,
//  so the lock screen (and its no-passcode Settings escape hatch, removed
//  with the toggle) is no longer reached.
//

import KurnCore
import SwiftUI

struct SecurityCoverView: View {
    let state: SecurityCoverState
    let gate: RecordingAccessGate
    let settings: AppSettings

    var body: some View {
        ZStack {
            // Painted unconditionally: a hosting controller's view is not
            // reliably opaque, and a cover that lets content show through is
            // not a cover.
            Theme.background.ignoresSafeArea()

            switch state {
            case .hidden:
                EmptyView()
            case .privacy:
                PrivacyCoverView()
            case .locked:
                LockedRecordingsView(gate: gate, showingSettings: .constant(false))
                    .task { await gate.authenticate() }
            }
        }
    }
}
