#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

static NSString *const StateNotification = @"com.jaykuroyanagi.meeting-recorder.state";
static NSString *const StopNotification = @"com.jaykuroyanagi.meeting-recorder.stop";

static BOOL SendState(NSString *requestID, NSString *statePath, NSString *status, NSString *message) {
  if (requestID.length == 0) {
    return NO;
  }
  NSMutableDictionary *userInfo = [@{
    @"requestID": requestID,
    @"status": status,
  } mutableCopy];
  if (message.length > 0) {
    userInfo[@"message"] = message;
  }
  BOOL saved = YES;
  if (statePath.length > 0) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:userInfo options:0 error:&error];
    saved = data != nil && [[NSFileManager defaultManager]
      createDirectoryAtPath:[statePath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
      attributes:nil
      error:&error] && [data writeToFile:statePath options:NSDataWritingAtomic error:&error];
    if (!saved) {
      NSString *stateError = [NSString stringWithFormat:
        @"Could not save recording state: %@", error.localizedDescription ?: @"Unknown error"];
      fprintf(stderr, "meeting-recorder: %s\n", stateError.UTF8String);
      userInfo[@"status"] = @"error";
      userInfo[@"message"] = stateError;
    }
  }
  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName:StateNotification
                   object:@"com.jaykuroyanagi.meeting-recorder"
                 userInfo:userInfo
       deliverImmediately:YES];
  return saved;
}

@interface MeetingRecorder : NSObject <SCStreamDelegate, SCStreamOutput>
@property(nonatomic, strong) NSURL *outputURL;
@property(nonatomic, strong) AVAssetWriter *writer;
@property(nonatomic, strong) AVAssetWriterInput *systemInput;
@property(nonatomic, strong) AVAssetWriterInput *microphoneInput;
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, strong) dispatch_source_t interruptSource;
@property(nonatomic, strong) dispatch_source_t parentSource;
@property(nonatomic, strong) dispatch_source_t terminateSource;
@property(nonatomic, strong) dispatch_source_t stopRequestSource;
@property(nonatomic, copy) void (^completion)(int);
@property(nonatomic, copy) NSString *failureMessage;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *statePath;
@property(nonatomic, strong) id stopObserver;
@property(nonatomic) CGDirectDisplayID displayID;
@property(nonatomic) pid_t parentPID;
@property(nonatomic) CMTime sessionStart;
@property(nonatomic) BOOL sessionStarted;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL stopTimedOut;
@property(nonatomic) BOOL writerFinished;
@property(nonatomic) BOOL completed;
@property(nonatomic) NSUInteger writtenSystemSamples;
@property(nonatomic) NSUInteger writtenMicrophoneSamples;
@property(nonatomic) NSUInteger droppedSystemSamples;
@property(nonatomic) NSUInteger droppedMicrophoneSamples;
@end

@implementation MeetingRecorder

- (instancetype)initWithOutputURL:(NSURL *)outputURL
                        displayID:(CGDirectDisplayID)displayID
                 bundleIdentifier:(NSString *)bundleIdentifier
                        requestID:(NSString *)requestID
                        statePath:(NSString *)statePath
                         parentPID:(pid_t)parentPID
                       completion:(void (^)(int))completion
                            error:(NSError **)resultError {
  self = [super init];
  if (!self) {
    return nil;
  }

  _outputURL = outputURL;
  _displayID = displayID;
  _bundleIdentifier = [bundleIdentifier copy];
  _requestID = [requestID copy];
  _statePath = [statePath copy];
  _parentPID = parentPID;
  _completion = [completion copy];
  _sampleQueue = dispatch_queue_create(
    "com.jaykuroyanagi.meeting-recorder.samples",
    DISPATCH_QUEUE_SERIAL
  );

  NSURL *directory = [outputURL URLByDeletingLastPathComponent];
  if (![[NSFileManager defaultManager]
        createDirectoryAtURL:directory
        withIntermediateDirectories:YES
        attributes:nil
        error:resultError]) {
    return nil;
  }

  _writer = [[AVAssetWriter alloc]
    initWithURL:outputURL
    fileType:AVFileTypeQuickTimeMovie
    error:resultError];
  if (!_writer) {
    return nil;
  }
  _writer.movieFragmentInterval = CMTimeMake(10, 1);

  NSDictionary *systemSettings = @{
    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
    AVSampleRateKey: @48000,
    AVNumberOfChannelsKey: @2,
    AVEncoderBitRateKey: @160000,
  };
  NSDictionary *microphoneSettings = @{
    AVFormatIDKey: @(kAudioFormatMPEG4AAC),
    AVSampleRateKey: @48000,
    AVNumberOfChannelsKey: @1,
    AVEncoderBitRateKey: @64000,
  };

  _systemInput = [AVAssetWriterInput
    assetWriterInputWithMediaType:AVMediaTypeAudio
    outputSettings:systemSettings];
  _microphoneInput = [AVAssetWriterInput
    assetWriterInputWithMediaType:AVMediaTypeAudio
    outputSettings:microphoneSettings];
  _systemInput.expectsMediaDataInRealTime = YES;
  _microphoneInput.expectsMediaDataInRealTime = YES;

  if (![_writer canAddInput:_systemInput] || ![_writer canAddInput:_microphoneInput]) {
    if (resultError) {
      *resultError = [NSError
        errorWithDomain:@"MeetingRecorder"
        code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Could not create audio tracks"}];
    }
    return nil;
  }
  [_writer addInput:_systemInput];
  [_writer addInput:_microphoneInput];
  return self;
}

- (void)start {
  if ([[NSFileManager defaultManager]
        fileExistsAtPath:[self.statePath stringByAppendingString:@".stop"]]) {
    [self stop];
    return;
  }

  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
  if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
    [self failWithMessage:@"Microphone permission is required"];
    return;
  }

  if (status == AVAuthorizationStatusNotDetermined) {
    __weak MeetingRecorder *weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        MeetingRecorder *recorder = weakSelf;
        if (!recorder) {
          return;
        }
        if (!granted) {
          [recorder failWithMessage:@"Microphone permission was denied"];
          return;
        }
        [recorder startCapture];
      });
    }];
    return;
  }

  [self startCapture];
}

- (void)startCapture {
  if (self.stopping) {
    return;
  }

  __weak MeetingRecorder *weakSelf = self;
  [SCShareableContent
    getShareableContentExcludingDesktopWindows:NO
    onScreenWindowsOnly:NO
    completionHandler:^(SCShareableContent *content, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        MeetingRecorder *recorder = weakSelf;
        if (!recorder || recorder.stopping) {
          return;
        }
        if (error) {
          [recorder failWithMessage:error.localizedDescription];
          return;
        }

        SCDisplay *display = nil;
        if (recorder.displayID != 0) {
          for (SCDisplay *candidate in content.displays) {
            if (candidate.displayID == recorder.displayID) {
              display = candidate;
              break;
            }
          }
        } else {
          display = content.displays.firstObject;
        }
        if (!display) {
          [recorder failWithMessage:@"The requested display is not available"];
          return;
        }

        SCContentFilter *filter = nil;
        if (recorder.bundleIdentifier) {
          SCRunningApplication *application = nil;
          for (SCRunningApplication *candidate in content.applications) {
            if ([candidate.bundleIdentifier isEqualToString:recorder.bundleIdentifier]) {
              application = candidate;
              break;
            }
          }
          if (!application) {
            [recorder failWithMessage:@"The meeting browser is not available for capture"];
            return;
          }
          filter = [[SCContentFilter alloc]
            initWithDisplay:display
            includingApplications:@[application]
            exceptingWindows:@[]];
        } else {
          filter = [[SCContentFilter alloc]
            initWithDisplay:display
            excludingWindows:@[]];
        }
        SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
        configuration.width = 2;
        configuration.height = 2;
        configuration.minimumFrameInterval = CMTimeMake(1, 1);
        configuration.queueDepth = 1;
        configuration.showsCursor = NO;
        configuration.capturesAudio = YES;
        configuration.sampleRate = 48000;
        configuration.channelCount = 2;
        configuration.excludesCurrentProcessAudio = YES;
        configuration.captureMicrophone = YES;

        recorder.stream = [[SCStream alloc]
          initWithFilter:filter
          configuration:configuration
          delegate:recorder];

        NSError *outputError = nil;
        if (![recorder.stream
              addStreamOutput:recorder
              type:SCStreamOutputTypeAudio
              sampleHandlerQueue:recorder.sampleQueue
              error:&outputError] ||
            ![recorder.stream
              addStreamOutput:recorder
              type:SCStreamOutputTypeMicrophone
              sampleHandlerQueue:recorder.sampleQueue
              error:&outputError]) {
          [recorder failWithMessage:outputError.localizedDescription];
          return;
        }

        [recorder.stream startCaptureWithCompletionHandler:^(NSError *startError) {
          if (startError) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [recorder failWithMessage:startError.localizedDescription];
            });
          }
        }];
      });
    }];
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (self.stopping || !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }

  AVAssetWriterInput *input = nil;
  if (type == SCStreamOutputTypeAudio) {
    input = self.systemInput;
  } else if (type == SCStreamOutputTypeMicrophone) {
    input = self.microphoneInput;
  } else {
    return;
  }

  CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (!CMTIME_IS_VALID(presentationTime)) {
    return;
  }

  if (!self.sessionStarted) {
    if (![self.writer startWriting]) {
      [self failFromSampleQueue:self.writer.error.localizedDescription];
      return;
    }
    self.sessionStart = presentationTime;
    [self.writer startSessionAtSourceTime:presentationTime];
    self.sessionStarted = YES;
  }

  if (CMTimeCompare(presentationTime, self.sessionStart) < 0) {
    return;
  }

  if (!input.readyForMoreMediaData) {
    if (type == SCStreamOutputTypeAudio) {
      self.droppedSystemSamples += 1;
    } else {
      self.droppedMicrophoneSamples += 1;
    }
    return;
  }

  if (![input appendSampleBuffer:sampleBuffer]) {
    [self failFromSampleQueue:self.writer.error.localizedDescription];
    return;
  }

  if (self.writtenSystemSamples == 0 && self.writtenMicrophoneSamples == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self.stopping && !SendState(self.requestID, self.statePath, @"started", nil)) {
        [self failWithMessage:@"Could not save recording state"];
      }
    });
  }

  if (type == SCStreamOutputTypeAudio) {
    self.writtenSystemSamples += 1;
  } else {
    self.writtenMicrophoneSamples += 1;
  }

}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.stopping) {
      [self failWithMessage:error.localizedDescription];
    }
  });
}

- (void)failFromSampleQueue:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self failWithMessage:message ?: @"Failed to write audio"];
  });
}

- (void)failWithMessage:(NSString *)message {
  if (!self.failureMessage) {
    self.failureMessage = message ?: @"Recording failed";
    fprintf(stderr, "meeting-recorder: %s\n", self.failureMessage.UTF8String);
  }
  [self stop];
}

- (void)stop {
  if (self.stopping) {
    return;
  }
  self.stopping = YES;
  if (self.stopRequestSource) {
    dispatch_source_cancel(self.stopRequestSource);
    self.stopRequestSource = nil;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self.completed) {
      return;
    }
    self.stopTimedOut = YES;
    [self completeWithCode:1];
  });

  if (!self.stream) {
    [self finishWriter];
    return;
  }

  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (error && !self.failureMessage) {
        self.failureMessage = error.localizedDescription;
        fprintf(stderr, "meeting-recorder: %s\n", error.localizedDescription.UTF8String);
      }
      [self finishWriter];
    });
  }];
}

- (void)finishWriter {
  dispatch_async(self.sampleQueue, ^{
    if (self.writerFinished) {
      return;
    }
    self.writerFinished = YES;

    if (!self.failureMessage) {
      if (self.writtenSystemSamples == 0 && self.writtenMicrophoneSamples == 0) {
        self.failureMessage = @"No audio samples were recorded";
      } else if (self.writtenSystemSamples == 0) {
        self.failureMessage = @"No system audio samples were recorded";
      } else if (self.writtenMicrophoneSamples == 0) {
        self.failureMessage = @"No microphone audio samples were recorded";
      }
      if (self.failureMessage) {
        fprintf(stderr, "meeting-recorder: %s\n", self.failureMessage.UTF8String);
      }
    }

    if (self.writer.status == AVAssetWriterStatusUnknown) {
      [self.writer cancelWriting];
      [self completeWithCode:self.failureMessage ? 1 : 0];
      return;
    }

    if (self.writer.status != AVAssetWriterStatusWriting) {
      NSString *message = self.writer.error.localizedDescription ?: @"Audio writer failed";
      if (!self.failureMessage) {
        self.failureMessage = message;
        fprintf(stderr, "meeting-recorder: %s\n", message.UTF8String);
      }
      [self completeWithCode:1];
      return;
    }

    [self.systemInput markAsFinished];
    [self.microphoneInput markAsFinished];
    [self.writer finishWritingWithCompletionHandler:^{
      if (self.droppedSystemSamples > 0 || self.droppedMicrophoneSamples > 0) {
        fprintf(
          stderr,
          "meeting-recorder: dropped samples (system=%lu, microphone=%lu)\n",
          (unsigned long)self.droppedSystemSamples,
          (unsigned long)self.droppedMicrophoneSamples
        );
      }

      BOOL succeeded = self.writer.status == AVAssetWriterStatusCompleted && !self.failureMessage;
      if (!succeeded && !self.failureMessage) {
        NSString *message = self.writer.error.localizedDescription ?: @"Could not finalize recording";
        self.failureMessage = message;
        fprintf(stderr, "meeting-recorder: %s\n", message.UTF8String);
      }
      [self completeWithCode:succeeded ? 0 : 1];
    }];
  });
}

- (void)completeWithCode:(int)code {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.completed) {
      return;
    }
    self.completed = YES;
    NSString *message = self.stopTimedOut
      ? @"Recording did not stop within 30 seconds; the output may be incomplete"
      : self.failureMessage;
    if (self.stopTimedOut) {
      fprintf(stderr, "meeting-recorder: %s\n", message.UTF8String);
    }
    int exitCode = message ? 1 : code;
    if (self.stopObserver) {
      [[NSDistributedNotificationCenter defaultCenter] removeObserver:self.stopObserver];
      self.stopObserver = nil;
    }
    BOOL saved = SendState(
      self.requestID,
      self.statePath,
      exitCode == 0 ? @"finished" : @"error",
      exitCode == 0 ? nil : message
    );
    self.completion(saved ? exitCode : 1);
  });
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    CGDirectDisplayID displayID = 0;
    NSString *bundleIdentifier = nil;
    NSString *outputPath = nil;
    NSString *requestID = nil;
    NSString *statePath = nil;
    pid_t parentPID = 0;
    for (int index = 1; index < argc; index++) {
      if (strcmp(argv[index], "--request-id") == 0 && index + 1 < argc) {
        requestID = [NSString stringWithUTF8String:argv[++index]];
      } else if (strcmp(argv[index], "--state-path") == 0 && index + 1 < argc) {
        statePath = [[[NSString stringWithUTF8String:argv[++index]]
          stringByExpandingTildeInPath] stringByStandardizingPath];
      } else if (strcmp(argv[index], "--parent-pid") == 0 && index + 1 < argc) {
        char *end = NULL;
        unsigned long value = strtoul(argv[++index], &end, 10);
        if (!end || *end != '\0' || value <= 1 || value > INT_MAX) {
          SendState(requestID, statePath, @"error", @"Invalid parent process ID");
          fprintf(stderr, "meeting-recorder: invalid parent process ID\n");
          return 2;
        }
        parentPID = (pid_t)value;
      } else if (strcmp(argv[index], "--display-id") == 0 && index + 1 < argc) {
        char *end = NULL;
        unsigned long value = strtoul(argv[++index], &end, 10);
        if (!end || *end != '\0' || value > UINT32_MAX) {
          SendState(requestID, statePath, @"error", @"Invalid display ID");
          fprintf(stderr, "meeting-recorder: invalid display ID\n");
          return 2;
        }
        displayID = (CGDirectDisplayID)value;
      } else if (strcmp(argv[index], "--bundle-id") == 0 && index + 1 < argc) {
        bundleIdentifier = [NSString stringWithUTF8String:argv[++index]];
      } else if (argv[index][0] != '-' && !outputPath) {
        outputPath = [NSString stringWithUTF8String:argv[index]];
      } else {
        SendState(requestID, statePath, @"error", @"Invalid arguments");
        fprintf(stderr, "meeting-recorder: invalid arguments\n");
        return 2;
      }
    }

    if (requestID.length == 0 || statePath.length == 0 || !outputPath) {
      SendState(requestID, statePath, @"error", @"A request ID, state path and output path are required");
      fprintf(
        stderr,
        "usage: meeting-recorder --request-id ID --state-path PATH [--parent-pid PID] [--display-id ID] [--bundle-id ID] OUTPUT.mov\n"
      );
      return 2;
    }

    if (@available(macOS 15.0, *)) {
      NSString *path = [[outputPath stringByExpandingTildeInPath] stringByStandardizingPath];
      NSURL *outputURL = [NSURL fileURLWithPath:path];
      __block int exitCode = 1;
      NSError *error = nil;
      MeetingRecorder *recorder = [[MeetingRecorder alloc]
        initWithOutputURL:outputURL
        displayID:displayID
        bundleIdentifier:bundleIdentifier
        requestID:requestID
        statePath:statePath
        parentPID:parentPID
        completion:^(int code) {
          exitCode = code;
          CFRunLoopStop(CFRunLoopGetMain());
        }
        error:&error];
      if (!recorder) {
        NSString *message = error.localizedDescription ?: @"Could not initialize Meeting Recorder";
        SendState(requestID, statePath, @"error", message);
        fprintf(stderr, "meeting-recorder: %s\n", message.UTF8String);
        return 1;
      }

      signal(SIGTERM, SIG_IGN);
      signal(SIGINT, SIG_IGN);
      signal(SIGPIPE, SIG_IGN);
      recorder.terminateSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        SIGTERM,
        0,
        dispatch_get_main_queue()
      );
      recorder.interruptSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        SIGINT,
        0,
        dispatch_get_main_queue()
      );
      dispatch_source_set_event_handler(recorder.terminateSource, ^{ [recorder stop]; });
      dispatch_source_set_event_handler(recorder.interruptSource, ^{ [recorder stop]; });
      dispatch_resume(recorder.terminateSource);
      dispatch_resume(recorder.interruptSource);

      if (parentPID > 1) {
        recorder.parentSource = dispatch_source_create(
          DISPATCH_SOURCE_TYPE_PROC,
          (uintptr_t)parentPID,
          DISPATCH_PROC_EXIT,
          dispatch_get_main_queue()
        );
        dispatch_source_set_event_handler(recorder.parentSource, ^{ [recorder stop]; });
        dispatch_resume(recorder.parentSource);
      }

      __weak MeetingRecorder *weakRecorder = recorder;
      recorder.stopObserver = [[NSDistributedNotificationCenter defaultCenter]
        addObserverForName:StopNotification
                     object:nil
                      queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *notification) {
        MeetingRecorder *activeRecorder = weakRecorder;
        if (!activeRecorder) {
          return;
        }
        NSDictionary *userInfo = notification.userInfo;
        NSString *stopRequestID = [userInfo[@"requestID"] isKindOfClass:[NSString class]]
          ? userInfo[@"requestID"]
          : nil;
        NSNumber *stopParentPID = [userInfo[@"parentPID"] isKindOfClass:[NSNumber class]]
          ? userInfo[@"parentPID"]
          : nil;
        if ([stopRequestID isEqualToString:activeRecorder.requestID]
            || (stopParentPID && stopParentPID.intValue == activeRecorder.parentPID)) {
          [activeRecorder stop];
        }
      }];

      recorder.stopRequestSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue()
      );
      dispatch_source_set_timer(
        recorder.stopRequestSource,
        DISPATCH_TIME_NOW,
        NSEC_PER_SEC,
        NSEC_PER_SEC / 10
      );
      NSString *stopRequestPath = [statePath stringByAppendingString:@".stop"];
      dispatch_source_set_event_handler(recorder.stopRequestSource, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:stopRequestPath]) {
          [weakRecorder stop];
        }
      });
      dispatch_resume(recorder.stopRequestSource);

      [recorder start];
      CFRunLoopRun();
      return exitCode;
    }

    SendState(requestID, statePath, @"error", @"macOS 15 or newer is required");
    fprintf(stderr, "meeting-recorder: macOS 15 or newer is required\n");
    return 1;
  }
}
