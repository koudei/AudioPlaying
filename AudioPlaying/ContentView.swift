//
//  ContentView.swift
//  AudioPlaying
//
//  Created by 西室凱 on 2026/04/02.
//

import SwiftUI

struct ContentView: View {
    @State private var model = Model()
    @State private var sliderValue: Float = 440.0
    
    var body: some View {
        VStack(spacing: 24) {
            // ヘッダー部分
            HStack {
                Image(systemName: "waveform.path")
                    .font(.system(size: 30))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Prism Sine Generator")
                        .font(.headline)
                    Text("CoreAudio LPCM Real-time Output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                // 再生/停止ボタン
                Button(action: { model.isEngineRunning.toggle() }) {
                    Label(
                        model.isEngineRunning ? "Stop" : "Start",
                        systemImage: model.isEngineRunning ? "stop.fill" : "play.fill" // ここを systemImage に変更
                    )
                    .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isEngineRunning ? .red : .blue)
            }
            
            Divider()

            // デバイス選択
            VStack(alignment: .leading, spacing: 8) {
                Label("Output Device", systemImage: "speaker.wave.2")
                    .font(.subheadline).bold()
                Picker("", selection: $model.selectedDevice) {
                    Text("Select Device").tag(nil as AudioDevice?)
                    ForEach(model.devicelist, id: \.id) { device in
                        Text(AudioDevice.fetchName(for: device.id)).tag(device as AudioDevice?)
                    }
                }
                .labelsHidden()
            }

            // 周波数コントロール
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Frequency", systemImage: "tuningfork")
                        .font(.subheadline).bold()
                    Spacer()
                    Text("\(Int(sliderValue)) Hz")
                        .font(.system(.body, design: .monospaced))
                        .bold()
                        .foregroundStyle(.blue)
                }
                
                Slider(value: $model.hz, in: 20...2000, step: 1) {
                    Text("Frequency")
                } minimumValueLabel: {
                    Text("20Hz")
                } maximumValueLabel: {
                    Text("2kHz")
                }.onChange(of: sliderValue) { oldValue, newValue in
                    model.hz = Float32(newValue) // エンジンへの反映はこれだけでOK（描画は伴わない）
                }
                
                // プリセットボタン
                HStack {
                    ForEach([440, 880, 1000], id: \.self) { freq in
                        Button("\(freq)Hz") {
                            model.hz = Float32(freq)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding()
            .background(Color.primary.opacity(0.05))
            .cornerRadius(12)

            Spacer()
        }
        .padding(30)
        .frame(minWidth: 450, minHeight: 350)
    }
}
