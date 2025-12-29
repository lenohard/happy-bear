import SwiftUI

struct SmartView: View {
    @EnvironmentObject private var transcriptionManager: TranscriptionManager
    @EnvironmentObject private var aiGenerationManager: AIGenerationManager
    @EnvironmentObject private var themeManager: ThemeManager
    @AppStorage("remoteJobsEnabled") private var remoteJobsEnabled = false
    private let remoteJobPrefix = "remote:"
    private let remoteAIJobMetadataKey = "remote_job_id"

    // Separate job counts for STT and TTS
    private var sttJobCount: Int {
        sttLocalJobCount
    }
    
    private var ttsJobCount: Int {
        transcriptionManager.activeJobs.filter { $0.sonioxJobId.hasPrefix("tts-") }.count
    }

    private var aiLocalJobCount: Int {
        aiGenerationManager.activeJobs.filter { !isRemoteAIJob($0) }.count
    }

    private var sttLocalJobCount: Int {
        transcriptionManager.activeJobs.filter {
            !$0.sonioxJobId.hasPrefix("tts-") &&
            !$0.sonioxJobId.hasPrefix(remoteJobPrefix)
        }.count
    }

    private var remoteAIJobCount: Int {
        aiGenerationManager.activeJobs.filter { isRemoteAIJob($0) }.count
    }

    private var remoteRunningJobCount: Int {
        let remoteSTT = transcriptionManager.activeJobs.filter { $0.sonioxJobId.hasPrefix(remoteJobPrefix) }.count
        return remoteSTT + remoteAIJobCount
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        RemoteJobsView()
                    } label: {
                        HStack {
                            Label {
                                Text("Jobs")
                            } icon: {
                                Image(systemName: "tray.full")
                                    .foregroundStyle(festiveIconColor)
                            }
                            Spacer()
                            if remoteJobsEnabled && remoteRunningJobCount > 0 {
                                BadgeView(count: remoteRunningJobCount)
                            }
                        }
                    }
                    .listRowBackground(themeManager.colors.isFestive ? themeManager.colors.secondaryBackground.opacity(0.8) : nil)

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
                            if aiLocalJobCount > 0 {
                                BadgeView(count: aiLocalJobCount)
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

    private func isRemoteAIJob(_ job: AIGenerationJob) -> Bool {
        job.decodedMetadata()?.extras?[remoteAIJobMetadataKey] != nil
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
