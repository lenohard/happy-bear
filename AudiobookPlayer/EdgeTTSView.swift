import SwiftUI
import AVFoundation

struct EdgeTTSView: View {
    @AppStorage("edge_tts_voice") private var selectedVoice = "en-US-AriaNeural"
    @AppStorage("edge_tts_rate") private var rate = "+0%"
    @AppStorage("edge_tts_pitch") private var pitch = "+0Hz"
    
    @State private var isTesting = false
    @State private var testMessage = ""
    @State private var audioPlayer: AVAudioPlayer?
    
    private let ttsClient = EdgeTTSClient()
    
    private let voices = [
        "en-US-AriaNeural": "Aria (English US)",
        "en-US-GuyNeural": "Guy (English US)",
        "en-US-JennyNeural": "Jenny (English US)",
        "zh-CN-XiaoxiaoNeural": "Xiaoxiao (Chinese)",
        "zh-CN-YunxiNeural": "Yunxi (Chinese)"
    ]
    
    var body: some View {
        Form {
            Section(header: Text("Voice Settings")) {
                Picker("Voice", selection: $selectedVoice) {
                    ForEach(voices.keys.sorted(), id: \.self) { key in
                        Text(voices[key] ?? key).tag(key)
                    }
                }
                
                HStack {
                    Text("Rate")
                    Spacer()
                    TextField("Rate", text: $rate)
                        .multilineTextAlignment(.trailing)
                }
                
                HStack {
                    Text("Pitch")
                    Spacer()
                    TextField("Pitch", text: $pitch)
                        .multilineTextAlignment(.trailing)
                }
            }
            
            
            Section {
                Button(action: testVoice) {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text(isTesting ? "Generating..." : "Test Voice")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isTesting)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !testMessage.isEmpty {
                        Text(testMessage)
                            .font(.caption)
                            .foregroundColor(testMessage.contains("Error") ? .red : .green)
                    }
                    Text("These settings will be applied when playing Ebook text tracks.")
                }
            }
        }
        .navigationTitle("Edge TTS")
    }
    
    private func testVoice() {
        isTesting = true
        testMessage = ""
        
        // Test text based on selected voice
        let testText = selectedVoice.contains("zh-CN") 
            ? "你好，这是一个语音测试。" 
            : "Hello, this is a voice test."
        
        ttsClient.generateAudio(text: testText, voice: selectedVoice, rate: rate, pitch: pitch) { result in
            DispatchQueue.main.async {
                isTesting = false
                
                switch result {
                case .success(let data):
                    do {
                        // Create a temporary file to play the audio
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_voice.mp3")
                        try data.write(to: tempURL)
                        
                        // Play the audio
                        audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
                        audioPlayer?.play()
                        
                        testMessage = "✓ Voice test successful"
                    } catch {
                        testMessage = "Error: Failed to play audio - \(error.localizedDescription)"
                    }
                    
                case .failure(let error):
                    testMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
