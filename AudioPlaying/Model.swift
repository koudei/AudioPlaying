//
//  Model.swift
//  AudioPlaying
//
//  Created by 西室凱 on 2026/04/02.
//

import CoreAudio
import Combine

func getPropertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress{
    let address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return address
}

func loadAudioDevices() -> [AudioDevice]{
    var aggregateDeviceList:[AudioObjectID] = []
    var realDeviceList:[AudioObjectID]  = []
    var devicesAddress = getPropertyAddress(selector: kAudioHardwarePropertyDevices)
    var propertySize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &propertySize)
    let deviceCount = Int(propertySize) / MemoryLayout<AudioObjectID>.stride
    var deviceList: [AudioObjectID] = [AudioObjectID](repeating: 0, count: deviceCount)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &propertySize, &deviceList)
    
    for id in deviceList {
        var propertyAddress = getPropertyAddress(selector: kAudioDevicePropertyTransportType)
        propertySize = UInt32(MemoryLayout<UInt32>.stride)
        var transportType: UInt32 = 0
        AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &propertySize, &transportType)
        
        if transportType == kAudioDeviceTransportTypeAggregate {
            aggregateDeviceList.append(id)
        } else {
            realDeviceList.append(id)
        }
    }
    var list:[AudioDevice] = []
    for dev in realDeviceList {
        list.append(AudioDevice(id: dev))
    }
    return list
}

struct AudioDevice{
    var name: String
    var id: AudioDeviceID
    
    init(id: AudioDeviceID) {
        self.id = id
        self.name = ""
        self.name = getName()
        
    }
    
    func getName() -> String{
        var n: String = ""
        var size: UInt32 = 0
        var address = getPropertyAddress(selector: kAudioObjectPropertyName)
        var s_err = withUnsafeMutablePointer(to: &size) { size in
            AudioObjectGetPropertyDataSize(id, &address, 0, nil, size)
        }
        var err = withUnsafeMutablePointer(to: &n) { n in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, n)
        }
        return n
    }
}

@Observable
class Model: ObservableObject {
    // デバイスリスト（UI表示用
    var devicelist: [AudioDevice] = []
    
    // 選択中のデバイス
    var selectedDevice: AudioDevice? = nil {
        didSet {
            if let device = selectedDevice {
                changeDevice(device: device)
            }
        }
    }
    
    // 周波数（スライダー等と連動）
    var hz: Float32 = 440.0 {
        didSet {
            // エンジンへの反映は即座に行う（音の遅延を防ぐ）
            engine.hz = hz
        }
    }
    
    // エンジンのインスタンス
    private var engine: AudioEngine = AudioEngine()
    
    // エンジンの稼働状態
    var isEngineRunning: Bool = false {
        didSet {
            if isEngineRunning {
                startEngine()
            } else {
                stopEngine()
            }
        }
    }
    init() {
        self.devicelist = loadAudioDevices()
        self.hz = 440.0
        self.engine = AudioEngine()
    }

    /// デバイスを変更する
    func changeDevice(device: AudioDevice) {
        // AudioEngine.mm の adaptToDevice: が内部で呼ばれる
        // すでに再生中の場合は、停止・再開の処理も engine 側で行われます
        engine.deviceID = device.id
    }

    /// 周波数を更新する
    func changeFrequency(next_hz: Float32) {
        // atomic プロパティ経由で安全に即座に反映される
        engine.hz = next_hz
    }

    /// 再生を開始する
    func startEngine() {
        engine.isRunning = true
    }

    /// 再生を停止する
    func stopEngine() {
        engine.isRunning = false
    }
}

extension AudioDevice: Hashable {
    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func fetchName(for id: AudioDeviceID) -> String {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        if status == noErr {
            return name as String
        }
        return "Unknown Device (\(id))"
    }
}
