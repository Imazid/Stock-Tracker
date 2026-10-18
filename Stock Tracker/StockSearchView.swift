//
//  StockSearchView.swift
//  Stock Tracker
//
//  The Search tab: recent searches and popular listings when idle, then ranked
//  US / ASX / crypto results with inline add. Built on `SymbolSearchView`.
//

import SwiftUI

struct StockSearchView: View {
    @StateObject private var model = SymbolSearchModel()
    @StateObject private var speech = SearchVoiceRecognizer()
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            SymbolSearchView(mode: .browse, model: model)
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { micButton }
                }
                .onDisappear {
                    if speech.isRecording { speech.stopRecording() }
                }
                .alert("Microphone access needed", isPresented: $speech.permissionDenied) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Turn on Microphone and Speech Recognition in Settings to search by voice.")
                }
        }
    }

    private var micButton: some View {
        Button {
            Haptics.tap()
            speech.toggle { transcript in model.query = transcript }
        } label: {
            Image(systemName: speech.isRecording ? "waveform" : "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(speech.isRecording ? DS.accent : theme.primaryText)
                .symbolEffect(.variableColor.iterative, isActive: speech.isRecording)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(speech.isRecording ? "Stop voice search" : "Search by voice")
        .accessibilityIdentifier("search.voice")
    }
}
