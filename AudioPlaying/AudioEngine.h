//
//  AudioEngine.h
//  AudioPlaying
//
//  Created by 西室凱 on 2026/04/02.
//


#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioEngine : NSObject

@property (nonatomic, assign) AudioObjectID deviceID;
@property (atomic, assign, readwrite) float hz;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;

- (instancetype)init;
- (BOOL)adaptToDevice:(AudioObjectID)deviceID;

@end

NS_ASSUME_NONNULL_END