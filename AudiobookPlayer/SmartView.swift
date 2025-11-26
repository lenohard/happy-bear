import SwiftUI

struct SmartView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AITabView()
                    } label: {
                        HStack {
                            Label(NSLocalizedString("ai_tab", comment: "AI tab"), systemImage: "sparkles")
                            Spacer()
                            if !aiGenerationManager.activeJobs.isEmpty {
                                BadgeView(count: aiGenerationManager.activeJobs.count)
                            }
                        }
                    }

                    NavigationLink {
                        TTSTabView()
                    } label: {
                        HStack {
                            Label(NSLocalizedString("tts_tab", comment: "TTS tab"), systemImage: "waveform")
                            Spacer()
                            if !transcriptionManager.activeJobs.isEmpty {
                                BadgeView(count: transcriptionManager.activeJobs.count)
                            }
                        }
                    }
                }
            }
            .navigationTitle("智能")
        }
    }
}

private struct BadgeView: View {
    let count: Int
    
    var body: some View {
        Text("\(count)")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
    }
}
