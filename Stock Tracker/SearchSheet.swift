//
//  SearchSheet.swift
//  Stock Tracker
//

import SwiftUI
import Combine
import Speech
import AVFoundation

// MARK: - Speech Recognizer

@MainActor
final class SearchVoiceRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var permissionDenied = false

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: .current)

    func toggle(onResult: @escaping (String) -> Void) {
        isRecording ? stopRecording() : requestAndStart(onResult: onResult)
    }

    private func requestAndStart(onResult: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized:
                    self.startRecording(onResult: onResult)
                default:
                    self.permissionDenied = true
                }
            }
        }
    }

    private func startRecording(onResult: @escaping (String) -> Void) {
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in onResult(result.bestTranscription.formattedString) }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in self.stopRecording() }
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isRecording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Add symbols sheet

/// "Add to <list>" — the same search as the Search tab, where tapping a row
/// adds or removes it instead of opening details.
struct AddSymbolsSheet: View {
    var initialScope: SymbolSearchScope = .all
    @StateObject private var model = SymbolSearchModel()
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss

    private var listName: String {
        let i = marketData.activeWatchlistIndex
        return marketData.watchlistGroups.indices.contains(i) ? marketData.watchlistGroups[i].name : "Watchlist"
    }

    var body: some View {
        NavigationStack {
            SymbolSearchView(mode: .add, model: model)
                .navigationTitle("Add to \(listName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("addSymbols.done")
                    }
                }
                .onAppear { model.scope = initialScope }
        }
        .presentationDragIndicator(.visible)
    }
}
