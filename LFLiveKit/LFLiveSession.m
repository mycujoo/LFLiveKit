//
//  LFLiveSession.m
//  LFLiveKit
//
//  Created by LaiFeng on 16/5/20.
//  Copyright © 2016年 LaiFeng All rights reserved.
//

#import "LFLiveSession.h"
#import "LFVideoCapture.h"
#import "LFAudioCapture.h"
#import "LFHardwareVideoEncoder.h"
#import "LFHardwareAudioEncoder.h"
#import "LFStreamRTMPSocket.h"
#import "LFLiveStreamInfo.h"


@interface LFLiveSession ()<LFAudioCaptureDelegate, LFVideoCaptureDelegate, LFAudioEncoderDelegate, LFVideoEncoderDelegate, LFStreamSocketDelegate>

/// 音频配置
@property (nonatomic, strong) LFLiveAudioConfiguration *audioConfiguration;
/// 视频配置
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfiguration;
/// 声音采集
@property (nonatomic, strong) LFAudioCapture *audioCaptureSource;
/// 视频采集
@property (nonatomic, strong) LFVideoCapture *videoCaptureSource;
/// 音频编码
@property (nonatomic, strong) id<LFAudioEncoder> audioEncoder;
/// 视频编码
@property (nonatomic, strong) id<LFVideoEncoder> videoEncoder;
/// 上传
@property (nonatomic, strong) id<LFStreamSocket> socket;


#pragma mark -- 内部标识
/// 调试信息
@property (nonatomic, strong) LFLiveDebug *debugInfo;
/// 流信息
@property (nonatomic, strong) LFLiveStreamInfo *streamInfo;
/// 是否开始上传
@property (nonatomic, assign) BOOL uploading;
/// 当前状态
@property (nonatomic, assign, readwrite) LFLiveState state;
/// 当前直播type
@property (nonatomic, assign, readwrite) LFLiveCaptureTypeMask captureType;
/// 时间戳锁
@property (nonatomic, strong) dispatch_semaphore_t lock;


@end

/**  时间戳 */
#define NOW (CACurrentMediaTime()*1000)
#define SYSTEM_VERSION_LESS_THAN(v) ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] == NSOrderedAscending)

@interface LFLiveSession ()

/// 上传相对时间戳
@property (nonatomic, assign) uint64_t relativeTimestamps;
/// 音视频是否对齐
@property (nonatomic, assign) BOOL AVAlignment;
/// 当前是否采集到了音频
@property (nonatomic, assign) BOOL hasCaptureAudio;
/// 当前是否采集到了关键帧
@property (nonatomic, assign) BOOL hasKeyFrameVideo;

@end

@implementation LFLiveSession

#pragma mark -- LifeCycle
- (instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration {
    return [self initWithAudioConfiguration:audioConfiguration videoConfiguration:videoConfiguration captureType:LFLiveCaptureDefaultMask];
}

- (nullable instancetype)initWithAudioConfiguration:(nullable LFLiveAudioConfiguration *)audioConfiguration videoConfiguration:(nullable LFLiveVideoConfiguration *)videoConfiguration captureType:(LFLiveCaptureTypeMask)captureType{
    if((captureType & LFLiveCaptureMaskAudio || captureType & LFLiveInputMaskAudio) && !audioConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"audioConfiguration is nil " userInfo:nil];
    if((captureType & LFLiveCaptureMaskVideo || captureType & LFLiveInputMaskVideo) && !videoConfiguration) @throw [NSException exceptionWithName:@"LFLiveSession init error" reason:@"videoConfiguration is nil " userInfo:nil];
    if (self = [super init]) {
        _audioConfiguration = audioConfiguration;
        _videoConfiguration = videoConfiguration;
        _adaptiveBitrate = NO;
        _captureType = captureType;
    }
    return self;
}

- (void)dealloc {
    _videoCaptureSource.running = NO;
    _audioCaptureSource.running = NO;
}

#pragma mark -- CustomMethod
- (void)startLive:(LFLiveStreamInfo *)streamInfo {
    if (!streamInfo) return;
    _streamInfo = streamInfo;
    _streamInfo.videoConfiguration = _videoConfiguration;
    _streamInfo.audioConfiguration = _audioConfiguration;
    [self.socket start];
}

- (void)stopLive {
    self.uploading = NO;
    [self.socket stop];
    self.socket = nil;
}

- (void)pushVideo:(nullable CVPixelBufferRef)pixelBuffer{
    if(self.captureType & LFLiveInputMaskVideo){
        if (self.uploading) [self.videoEncoder encodeVideoData:pixelBuffer timeStamp:NOW];
    }
}

- (void)pushAudio:(nullable NSData*)audioData
{
  if (self.captureType & LFLiveInputMaskAudio) {
    if (self.uploading) [self.audioEncoder encodeAudioData:audioData timeStamp:NOW];
  }
}

#pragma mark -- PrivateMethod
- (void)pushSendBuffer:(LFFrame*)frame{
    if(self.relativeTimestamps == 0){
        self.relativeTimestamps = frame.timestamp;
    }
    frame.timestamp = [self uploadTimestamp:frame.timestamp];
    [self.socket sendFrame:frame];
}

#pragma mark - LFAudioCaptureDelegate
- (void)captureOutput:(nullable LFAudioCapture *)capture audioData:(nullable NSData*)audioData {
    if (self.uploading) [self.audioEncoder encodeAudioData:audioData timeStamp:NOW];
}

- (void)captureOutput:(nullable LFVideoCapture *)capture pixelBuffer:(nullable CVPixelBufferRef)pixelBuffer {
    if (self.uploading) [self.videoEncoder encodeVideoData:pixelBuffer timeStamp:NOW];
}

#pragma mark - LFAudioEncoderDelegate
- (void)audioEncoder:(nullable id<LFAudioEncoder>)encoder audioFrame:(nullable LFAudioFrame *)frame
{
  if (self.uploading) {
    self.hasCaptureAudio = YES;
    if (self.AVAlignment) [self pushSendBuffer:frame]; /////???
  }
}

- (void)videoEncoder:(nullable id<LFVideoEncoder>)encoder videoFrame:(nullable LFVideoFrame *)frame {
    //<上传 时间戳对齐
    if (self.uploading){
        if(frame.isKeyFrame && self.hasCaptureAudio) self.hasKeyFrameVideo = YES;
        if(self.AVAlignment) [self pushSendBuffer:frame];
    }
}

#pragma mark -- LFStreamTcpSocketDelegate
- (void)socketStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveState)status {
    if (status == LFLiveStart) {
        if (!self.uploading) {
            self.AVAlignment = NO;
            self.hasCaptureAudio = NO;
            self.hasKeyFrameVideo = NO;
            self.relativeTimestamps = 0;
            self.uploading = YES;
        }
    } else if(status == LFLiveStop || status == LFLiveError){
        self.uploading = NO;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.state = status;
        if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:liveStateDidChange:)]) {
            [self.delegate liveSession:self liveStateDidChange:status];
        }
    });
}

- (void)socketDidError:(nullable id<LFStreamSocket>)socket errorCode:(LFLiveSocketErrorCode)errorCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:errorCode:)]) {
            [self.delegate liveSession:self errorCode:errorCode];
        }
    });
}

- (void)socketDebug:(nullable id<LFStreamSocket>)socket debugInfo:(nullable LFLiveDebug *)debugInfo {
    self.debugInfo = debugInfo;
    if (self.showDebugInfo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:debugInfo:)]) {
                [self.delegate liveSession:self debugInfo:debugInfo];
            }
        });
    }
}

- (void)socketBufferStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveBuffferState)status {
    if((self.captureType & LFLiveCaptureMaskVideo || self.captureType & LFLiveInputMaskVideo) && self.adaptiveBitrate){
        NSUInteger videoBitRate = [self.videoEncoder videoBitRate];
        if (status == LFLiveBuffferDecline) {
            if (videoBitRate < _videoConfiguration.videoMaxBitRate) {
                videoBitRate = videoBitRate + 50 * 1000;
                [self.videoEncoder setVideoBitRate:videoBitRate];
                NSLog(@"Increase bitrate %@", @(videoBitRate));
            }
        } else {
            if (videoBitRate > self.videoConfiguration.videoMinBitRate) {
                videoBitRate = videoBitRate - 100 * 1000;
                [self.videoEncoder setVideoBitRate:videoBitRate];
                NSLog(@"Decline bitrate %@", @(videoBitRate));
            }
        }
    }
}

- (void)setRunning:(BOOL)running {
    if (_running == running) return;
    [self willChangeValueForKey:@"running"];
    _running = running;
    [self didChangeValueForKey:@"running"];
    self.videoCaptureSource.running = _running;
    self.audioCaptureSource.running = _running;
}

- (void)setRecording:(BOOL)recording {
  if (!self.saveLocalVideo) return;
  if (_recording == recording) return;
  _recording = recording;
  self.videoCaptureSource.recording = _recording;
  /// audio?
}

- (void)setPreviewView:(UIView *)previewView
{
  [self.videoCaptureSource setPreviewView:previewView];
}

- (UIView *)previewView
{
  return self.videoCaptureSource.previewView;
}

- (void)setCaptureDevicePosition:(AVCaptureDevicePosition)captureDevicePosition {
    [self willChangeValueForKey:@"captureDevicePosition"];
    [self.videoCaptureSource setCaptureDevicePosition:captureDevicePosition];
    [self didChangeValueForKey:@"captureDevicePosition"];
}

- (AVCaptureDevicePosition)captureDevicePosition {
    return self.videoCaptureSource.captureDevicePosition;
}

- (BOOL)saveLocalVideo{
    return self.videoCaptureSource.saveLocalVideo;
}

- (void)setSaveLocalVideo:(BOOL)saveLocalVideo{
    [self.videoCaptureSource setSaveLocalVideo:saveLocalVideo];
}


- (NSString*)saveLocalVideoPath{
    return self.videoCaptureSource.saveLocalVideoPath;
}

- (void)setSaveLocalVideoPath:(NSString*)saveLocalVideoPath{
    [self.videoCaptureSource setSaveLocalVideoPath:saveLocalVideoPath];
}

- (void)setBrightLevel:(CGFloat)brightLevel {
    [self willChangeValueForKey:@"brightLevel"];
    [self.videoCaptureSource setBrightLevel:brightLevel];
    [self didChangeValueForKey:@"brightLevel"];
}

- (CGFloat)brightLevel {
    return self.videoCaptureSource.brightLevel;
}

- (void)setZoomScale:(CGFloat)zoomScale {
    [self setZoomScale:zoomScale ramping:NO];
}

- (void)setZoomScale:(CGFloat)zoomScale ramping:(BOOL)ramping {
    [self willChangeValueForKey:@"zoomScale"];
    [self.videoCaptureSource setZoomScale:zoomScale ramping:ramping];
    [self didChangeValueForKey:@"zoomScale"];
}

- (CGFloat)zoomScale
{
  return self.videoCaptureSource.zoomScale;
}

- (void)setMuted:(BOOL)muted
{
  [self.audioCaptureSource setMuted:muted];
}

- (BOOL)muted
{
  return self.audioCaptureSource.muted;
}

- (void)setStabilization:(BOOL)stabilization
{
    self.videoCaptureSource.stabilization = stabilization;
}

- (BOOL)stabilization
{
    return self.videoCaptureSource.stabilization;
}

- (nullable UIImage *)currentImage{
    return self.videoCaptureSource.currentImage;
}

- (LFAudioCapture *)audioCaptureSource {
  if (!_audioCaptureSource) {
    if (self.captureType & LFLiveCaptureMaskAudio) {
      _audioCaptureSource = [[LFAudioCapture alloc] initWithAudioConfiguration:_audioConfiguration];
      _audioCaptureSource.delegate = self;
    }
  }
  return _audioCaptureSource;
}

- (LFVideoCapture *)videoCaptureSource {
    if (!_videoCaptureSource) {
        if(self.captureType & LFLiveCaptureMaskVideo){
            _videoCaptureSource = [[LFVideoCapture alloc] initWithVideoConfiguration:_videoConfiguration];
            _videoCaptureSource.delegate = self;
        }
    }
    return _videoCaptureSource;
}

- (id<LFAudioEncoder>)audioEncoder
{
    if (!_audioEncoder) {
        _audioEncoder = [[LFHardwareAudioEncoder alloc] initWithAudioStreamConfiguration:_audioConfiguration];
        [_audioEncoder setDelegate:self];
    }
    return _audioEncoder;
}

- (id<LFVideoEncoder>)videoEncoder
{
  if (!_videoEncoder) {
    _videoEncoder = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration:_videoConfiguration];
    [_videoEncoder setDelegate:self];
  }
  return _videoEncoder;
}

- (id<LFStreamSocket>)socket {
    if (!_socket) {
        _socket = [[LFStreamRTMPSocket alloc] initWithStream:self.streamInfo
                                           reconnectInterval:self.reconnectInterval
                                              reconnectCount:self.reconnectCount];
        [_socket setDelegate:self];
    }
    return _socket;
}

- (LFLiveStreamInfo *)streamInfo {
    if (!_streamInfo) {
        _streamInfo = [[LFLiveStreamInfo alloc] init];
    }
    return _streamInfo;
}

- (dispatch_semaphore_t)lock{
    if(!_lock){
        _lock = dispatch_semaphore_create(1);
    }
    return _lock;
}

- (uint64_t)uploadTimestamp:(uint64_t)captureTimestamp{
    dispatch_semaphore_wait(self.lock, DISPATCH_TIME_FOREVER);
    uint64_t currentts = 0;
    currentts = captureTimestamp - self.relativeTimestamps;
    dispatch_semaphore_signal(self.lock);
    return currentts;
}

- (BOOL)AVAlignment{
    if((self.captureType & LFLiveCaptureMaskAudio || self.captureType & LFLiveInputMaskAudio) &&
       (self.captureType & LFLiveCaptureMaskVideo || self.captureType & LFLiveInputMaskVideo)
       ){
        if(self.hasCaptureAudio && self.hasKeyFrameVideo) return YES;
        else  return NO;
    }else{
        return YES;
    }
}

@end
