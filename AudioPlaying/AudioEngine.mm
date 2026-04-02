//
//  AudioEngine.m
//  AudioPlaying
//
//  Created by 西室凱 on 2026/04/02.
//

#import "AudioEngine.h"
#import <vector>
#import <atomic>
#import <cmath>
#import <Accelerate/Accelerate.h>

// --- Helper Functions ---

constexpr AudioObjectPropertyAddress PropertyAddress(AudioObjectPropertySelector selector,
                                                     AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
                                                     AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) noexcept {
    return {selector, scope, element};
}

static OSStatus deviceChangedListener(AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void* inClientData) noexcept;
static OSStatus ioproc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void*) noexcept;

// --- Implementation ---

@interface AudioEngine () {
@public
    // スレッドセーフなメンバ変数
    std::atomic<float> _hz;
    std::atomic<bool> _isRunning;
    
    // サイン波の位相保持用（オーディオスレッドのみでアクセスするためatomic不要だが安全策で）
    double _currentPhase;
    double _sampleRate;
}

@property (readwrite, nonatomic) AudioDeviceIOProcID IOProcID;

@end

@implementation AudioEngine

@synthesize deviceID = _deviceID;
@synthesize IOProcID = _IOProcID;

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceID = kAudioObjectUnknown;
        _hz = 440.0f; // デフォルトA4
        _isRunning = false;
        _currentPhase = 0.0;
        _sampleRate = 44100.0; // 仮。デバイス設定後に更新
        _IOProcID = nullptr;
    }
    return self;
}

// --- Properties ---

// hzのGetter/Setter
- (float)hz { return _hz.load(); }
- (void)setHz:(float)hz { _hz.store(hz); }

// runningのGetter/Setter
- (BOOL)isRunning { return _isRunning.load(); }
- (void)setRunning:(BOOL)running {
    if (_isRunning == running) return;
    
    if (running) {
        [self startIO];
    } else {
        [self stopIO];
    }
}

- (void)setDeviceID:(AudioObjectID)deviceID {
    if (_deviceID == deviceID) return;
    [self adaptToDevice:deviceID];
}

// --- Device Logic ---

- (BOOL)adaptToDevice:(AudioObjectID)deviceID {
    // 1. 変更前に動いていたら止める
    BOOL wasRunning = self.isRunning;
    if (wasRunning) {
        [self stopIO];
    }
    
    [self unregisterListeners];
    _deviceID = deviceID;
    
    if (_deviceID != kAudioObjectUnknown) {
        [self updateSampleRate];
        [self registerListeners];
        
        // 2. 変更後に元の状態に戻す
        if (wasRunning) {
            return [self startIO];
        }
    }
    return YES;
}

- (void)updateSampleRate {
    Float64 sr = 0;
    UInt32 size = sizeof(sr);
    AudioObjectPropertyAddress addr = PropertyAddress(kAudioDevicePropertyNominalSampleRate);
    OSStatus err = AudioObjectGetPropertyData(_deviceID, &addr, 0, NULL, &size, &sr);
    if (err == noErr) {
        _sampleRate = sr;
    }
}

- (BOOL)startIO {
    if (_deviceID == kAudioObjectUnknown || _IOProcID != nullptr) return NO;
    
    OSStatus err = AudioDeviceCreateIOProcID(_deviceID, ioproc, (__bridge void*)self, &_IOProcID);
    if (err != noErr) return NO;
    
    err = AudioDeviceStart(_deviceID, _IOProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(_deviceID, _IOProcID);
        _IOProcID = nullptr;
        return NO;
    }
    
    _isRunning.store(true);
    NSLog(@"AudioEngine: Started");
    return YES;
}

- (void)stopIO {
    if (_deviceID == kAudioObjectUnknown || _IOProcID == nullptr) return;
    
    AudioDeviceStop(_deviceID, _IOProcID);
    AudioDeviceDestroyIOProcID(_deviceID, _IOProcID);
    _IOProcID = nullptr;
    _isRunning.store(false);
    NSLog(@"AudioEngine: Stopped");
}

// --- Listeners ---

- (void)registerListeners {
    if (_deviceID == kAudioObjectUnknown) return;
    auto addr = PropertyAddress(kAudioDevicePropertyDeviceIsAlive);
    AudioObjectAddPropertyListener(_deviceID, &addr, deviceChangedListener, (__bridge void*)self);
}

- (void)unregisterListeners {
    if (_deviceID == kAudioObjectUnknown) return;
    auto addr = PropertyAddress(kAudioDevicePropertyDeviceIsAlive);
    AudioObjectRemovePropertyListener(_deviceID, &addr, deviceChangedListener, (__bridge void*)self);
}

@end

// --- C-Style Callbacks ---

static OSStatus deviceChangedListener(AudioObjectID, UInt32, const AudioObjectPropertyAddress* inAddresses, void* inClientData) noexcept {
    AudioEngine* engine = (__bridge AudioEngine*)inClientData;
    // デバイスが死んだ場合はリセット
    [engine adaptToDevice:kAudioObjectUnknown];
    return noErr;
}

static OSStatus ioproc(AudioObjectID inDevice,
                       const AudioTimeStamp* inNow,
                       const AudioBufferList* inInputData,
                       const AudioTimeStamp* inInputTime,
                       AudioBufferList* outOutputData,
                       const AudioTimeStamp* inOutputTime,
                       void* inClientData) noexcept {
    
    AudioEngine* engine = (__bridge AudioEngine*)inClientData;
    
    float currentHz = engine->_hz.load();
    float sampleRate = (float)engine->_sampleRate;
    float phaseStep = (float)(2.0 * M_PI * currentHz / sampleRate);
    float amplitude = 0.4f; // 0.5だと少し大きい場合があるので安全策で0.4
    
    float startPhase = (float)engine->_currentPhase;
    UInt32 totalFrames = 0;

    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; ++i) {
        AudioBuffer& buffer = outOutputData->mBuffers[i];
        float* data = (float*)buffer.mData;
        // そのバッファに含まれる「1チャンネルあたりの」フレーム数
        UInt32 numFrames = buffer.mDataByteSize / (buffer.mNumberChannels * sizeof(float));
        totalFrames = numFrames; // 後の位相更新用

        for (UInt32 ch = 0; ch < buffer.mNumberChannels; ++ch) {
            // 各チャンネルの書き出し開始位置（インターリーブ対応）
            float* channelData = data + ch;
            float chStartPhase = startPhase;
            
            // vDSP_vramp の第4引数（ストライド）にチャンネル数を指定
            // これにより L,R,L,R の L だけ、あるいは R だけを埋められる
            vDSP_vramp(&chStartPhase, &phaseStep, channelData, buffer.mNumberChannels, numFrames);
            
            // サイン波変換と音量調整もストライドを考慮して行う
            int n = (int)numFrames;
            // vvsinf はストライド指定が難しいため、もしインターリーブなら
            // 一旦別バッファで作るのが安全ですが、まずは簡易的に以下で試してください
            for (UInt32 f = 0; f < numFrames; ++f) {
                float* samplePtr = channelData + (f * buffer.mNumberChannels);
                *samplePtr = sinf(*samplePtr) * amplitude;
            }
        }
    }
    
    // 精度維持のため、ここでの fmodf が生命線です！
    engine->_currentPhase = fmodf(startPhase + (phaseStep * totalFrames), (float)(2.0 * M_PI));
    
    return kAudioHardwareNoError;
}
