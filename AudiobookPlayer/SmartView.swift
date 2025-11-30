import SwiftUI

struct SmartView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager

    // Separate job counts for STT and TTS
    private var sttJobCount: Int {
        transcriptionManager.activeJobs.filter { !$0.sonioxJobId.hasPrefix("tts-") }.count
    }
    
    private var ttsJobCount: Int {
        transcriptionManager.activeJobs.filter { $0.sonioxJobId.hasPrefix("tts-") }.count
    }

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
                        SonioxSTTView()
                    } label: {
                        HStack {
                            Label("STT (Soniox)", systemImage: "waveform")
                            Spacer()
                            if sttJobCount > 0 {
                                BadgeView(count: sttJobCount)
                            }
                        }
                    }
                    
                    NavigationLink {
                        EdgeTTSView()
                    } label: {
                        HStack {
                            Label("TTS (Edge)", systemImage: "speaker.wave.2")
                            Spacer()
                            if ttsJobCount > 0 {
                                BadgeView(count: ttsJobCount)
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
