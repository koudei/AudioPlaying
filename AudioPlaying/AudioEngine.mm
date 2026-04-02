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
    
    // インスタンス変数へのダイレクトアクセス（高速化のため。ヘッダーで公開していない内部変数）
    // Objective-C++なので、構造体のようにアクセス可能
    float currentHz = engine->_hz.load();
    double sampleRate = engine->_sampleRate;
    double phase = engine->_currentPhase;
    
    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; ++i) {
        AudioBuffer& buffer = outOutputData->mBuffers[i];
        Float32* data = (Float32*)buffer.mData;
        UInt32 numFrames = buffer.mDataByteSize / (buffer.mNumberChannels * sizeof(Float32));
        
        for (UInt32 frame = 0; frame < numFrames; ++frame) {
            float sample = sin(phase);
            
            // 全チャンネルに同じ値を書き込む（インターリーブ/非インターリーブ両対応）
            for (UInt32 channel = 0; channel < buffer.mNumberChannels; ++channel) {
                data[frame * buffer.mNumberChannels + channel] = sample * 0.5f; // 音量0.5
            }
            
            // 位相の更新
            phase += 2.0 * M_PI * currentHz / sampleRate;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;
        }
    }
    
    // 次回の呼び出しのために位相を保存
    engine->_currentPhase = phase;
    
    return kAudioHardwareNoError;
}

