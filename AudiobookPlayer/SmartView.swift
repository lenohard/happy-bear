import SwiftUI

struct SmartView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var themeManager: ThemeManager

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
                            Label {
                                Text(NSLocalizedString("ai_tab", comment: "AI tab"))
                            } icon: {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(festiveIconColor)
                            }
                            Spacer()
                            if !aiGenerationManager.activeJobs.isEmpty {
                                BadgeView(count: aiGenerationManager.activeJobs.count)
                            }
                        }
                    }
                    .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)

                    NavigationLink {
                        SonioxSTTView()
                    } label: {
                        HStack {
                            Label {
                                Text("STT (Soniox)")
                            } icon: {
                                Image(systemName: "waveform")
                                    .foregroundStyle(festiveIconColor)
                            }
                            Spacer()
                            if sttJobCount > 0 {
                                BadgeView(count: sttJobCount)
                            }
                        }
                    }
                    .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)

                    NavigationLink {
                        EdgeTTSView()
                    } label: {
                        HStack {
                            Label {
                                Text("TTS (Edge)")
                            } icon: {
                                Image(systemName: "speaker.wave.2")
                                    .foregroundStyle(festiveIconColor)
                            }
                            Spacer()
                            if ttsJobCount > 0 {
                                BadgeView(count: ttsJobCount)
                            }
                        }
                    }
                    .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)
                }
            }
            .scrollContentBackground(themeManager.colors.isFestive ? .hidden : .visible)
            .background(themeManager.colors.isFestive ? Color.clear : Color(uiColor: .systemGroupedBackground))
            .navigationTitle(themeManager.colors.isFestive ? "❄️ 智能" : "智能")
        }
    }

    private var festiveIconColor: Color {
        themeManager.colors.isFestive ? themeManager.colors.festiveRed : .accentColor
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
