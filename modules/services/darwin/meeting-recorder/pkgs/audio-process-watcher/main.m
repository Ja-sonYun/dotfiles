#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <stdio.h>

static NSString *const StateNotification = @"com.jaykuroyanagi.audio-process-watcher.state";
static NSString *const RefreshNotification = @"com.jaykuroyanagi.audio-process-watcher.refresh";

static AudioObjectPropertyAddress PropertyAddress(AudioObjectPropertySelector selector) {
  return (AudioObjectPropertyAddress) {
    .mSelector = selector,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain,
  };
}

static BOOL IsUnavailableProcessObjectStatus(OSStatus status) {
  return status == kAudioHardwareBadObjectError
    || status == kAudioHardwareUnknownPropertyError;
}

@interface AudioProcessWatcher : NSObject
@property(nonatomic, strong) NSDistributedNotificationCenter *notificationCenter;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *processListeners;
@property(nonatomic, copy) AudioObjectPropertyListenerBlock processListListener;
@property(nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *lastOwners;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) NSUInteger retryCount;
@property(nonatomic) BOOL eventRefreshPending;
@property(nonatomic) BOOL retryRefreshPending;
@property(nonatomic) BOOL forceNextPublish;
@end

@implementation AudioProcessWatcher

- (instancetype)init {
  self = [super init];
  if (self) {
    _notificationCenter = [NSDistributedNotificationCenter defaultCenter];
    _processListeners = [NSMutableDictionary dictionary];
    _queue = dispatch_get_main_queue();
  }
  return self;
}

- (BOOL)start {
  __weak AudioProcessWatcher *weakSelf = self;
  self.processListListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
    (void)count;
    (void)addresses;
    [weakSelf scheduleRefresh];
  };

  AudioObjectPropertyAddress address = PropertyAddress(kAudioHardwarePropertyProcessObjectList);
  OSStatus status = AudioObjectAddPropertyListenerBlock(
    kAudioObjectSystemObject,
    &address,
    self.queue,
    self.processListListener
  );
  if (status != noErr) {
    fprintf(stderr, "audio-process-watcher: failed to observe the process list (%d)\n", status);
    return NO;
  }

  [self.notificationCenter
    addObserver:self
       selector:@selector(refreshRequested:)
           name:RefreshNotification
         object:nil
 suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [self refreshAndPublish:YES];
  return YES;
}

- (NSArray<NSNumber *> *)processObjectIDsWithStatus:(OSStatus *)resultStatus {
  AudioObjectPropertyAddress address = PropertyAddress(kAudioHardwarePropertyProcessObjectList);
  UInt32 size = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(
    kAudioObjectSystemObject,
    &address,
    0,
    NULL,
    &size
  );
  if (status != noErr) {
    *resultStatus = status;
    return nil;
  }
  if (size == 0) {
    *resultStatus = noErr;
    return @[];
  }

  NSMutableData *data = [NSMutableData dataWithLength:size];
  status = AudioObjectGetPropertyData(
    kAudioObjectSystemObject,
    &address,
    0,
    NULL,
    &size,
    data.mutableBytes
  );
  if (status != noErr) {
    *resultStatus = status;
    return nil;
  }

  NSUInteger count = size / sizeof(AudioObjectID);
  AudioObjectID *objectIDs = data.mutableBytes;
  NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger index = 0; index < count; index++) {
    [result addObject:@(objectIDs[index])];
  }
  [result sortUsingSelector:@selector(compare:)];
  *resultStatus = noErr;
  return result;
}

- (BOOL)updateListenersForObjectIDs:(NSArray<NSNumber *> *)objectIDs {
  BOOL complete = YES;
  NSSet<NSNumber *> *currentObjectIDs = [NSSet setWithArray:objectIDs];
  for (NSNumber *key in [self.processListeners.allKeys copy]) {
    if ([currentObjectIDs containsObject:key]) {
      continue;
    }

    AudioObjectID objectID = key.unsignedIntValue;
    AudioObjectPropertyListenerBlock listener = self.processListeners[key];
    AudioObjectPropertyAddress runningAddress = PropertyAddress(kAudioProcessPropertyIsRunning);
    AudioObjectPropertyAddress inputAddress = PropertyAddress(kAudioProcessPropertyIsRunningInput);
    AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, self.queue, listener);
    AudioObjectRemovePropertyListenerBlock(objectID, &inputAddress, self.queue, listener);
    [self.processListeners removeObjectForKey:key];
  }

  for (NSNumber *key in objectIDs) {
    if (self.processListeners[key]) {
      continue;
    }

    __weak AudioProcessWatcher *weakSelf = self;
    AudioObjectPropertyListenerBlock listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
      (void)count;
      (void)addresses;
      [weakSelf scheduleRefresh];
    };
    AudioObjectID objectID = key.unsignedIntValue;
    AudioObjectPropertyAddress runningAddress = PropertyAddress(kAudioProcessPropertyIsRunning);
    AudioObjectPropertyAddress inputAddress = PropertyAddress(kAudioProcessPropertyIsRunningInput);
    OSStatus runningStatus = AudioObjectAddPropertyListenerBlock(
      objectID,
      &runningAddress,
      self.queue,
      listener
    );
    OSStatus inputStatus = AudioObjectAddPropertyListenerBlock(
      objectID,
      &inputAddress,
      self.queue,
      listener
    );
    if (runningStatus != noErr || inputStatus != noErr) {
      if (runningStatus == noErr) {
        AudioObjectRemovePropertyListenerBlock(objectID, &runningAddress, self.queue, listener);
      }
      if (inputStatus == noErr) {
        AudioObjectRemovePropertyListenerBlock(objectID, &inputAddress, self.queue, listener);
      }
      fprintf(
        stderr,
        "audio-process-watcher: failed to observe process %u (%d, %d)\n",
        objectID,
        runningStatus,
        inputStatus
      );
      complete = NO;
      continue;
    }
    self.processListeners[key] = [listener copy];
  }
  return complete;
}

- (OSStatus)readUInt32:(UInt32 *)value
             selector:(AudioObjectPropertySelector)selector
             objectID:(AudioObjectID)objectID {
  AudioObjectPropertyAddress address = PropertyAddress(selector);
  UInt32 size = sizeof(*value);
  return AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, value);
}

- (NSString *)bundleIDForObjectID:(AudioObjectID)objectID status:(OSStatus *)resultStatus {
  AudioObjectPropertyAddress address = PropertyAddress(kAudioProcessPropertyBundleID);
  CFStringRef value = NULL;
  UInt32 size = sizeof(value);
  OSStatus status = AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, &value);
  *resultStatus = status;
  if (status != noErr) {
    return nil;
  }
  if (value == NULL) {
    return @"";
  }
  return CFBridgingRelease(value);
}

- (NSArray<NSDictionary<NSString *, id> *> *)activeOwnersForObjectIDs:(NSArray<NSNumber *> *)objectIDs
                                                              complete:(BOOL *)resultComplete {
  NSMutableArray<NSDictionary<NSString *, id> *> *owners = [NSMutableArray array];
  NSMutableDictionary<NSNumber *, NSDictionary<NSString *, id> *> *previousOwners =
    [NSMutableDictionary dictionary];
  for (NSDictionary<NSString *, id> *owner in self.lastOwners) {
    NSNumber *objectID = owner[@"objectID"];
    if ([objectID isKindOfClass:[NSNumber class]]) {
      previousOwners[objectID] = owner;
    }
  }
  BOOL complete = YES;
  NSUInteger readableProcessCount = 0;
  for (NSNumber *key in objectIDs) {
    AudioObjectID objectID = key.unsignedIntValue;
    UInt32 runningInput = 0;
    OSStatus status = [self readUInt32:&runningInput
                              selector:kAudioProcessPropertyIsRunningInput
                              objectID:objectID];
    if (status != noErr) {
      fprintf(
        stderr,
        "audio-process-watcher: failed to read process %u input state (%d)\n",
        objectID,
        status
      );
      complete = NO;
      if (!IsUnavailableProcessObjectStatus(status) && previousOwners[key]) {
        [owners addObject:previousOwners[key]];
      }
      continue;
    }
    readableProcessCount += 1;
    if (runningInput == 0) {
      continue;
    }

    NSString *bundleID = [self bundleIDForObjectID:objectID status:&status];
    if (status != noErr) {
      fprintf(
        stderr,
        "audio-process-watcher: failed to read process %u bundle ID (%d)\n",
        objectID,
        status
      );
      complete = NO;
      if (!IsUnavailableProcessObjectStatus(status) && previousOwners[key]) {
        [owners addObject:previousOwners[key]];
      }
      continue;
    }

    [owners addObject:@{
      @"objectID": key,
      @"bundleID": bundleID,
    }];
  }
  *resultComplete = complete;
  if (objectIDs.count > 0 && readableProcessCount == 0) {
    return nil;
  }
  return owners;
}

- (void)publishOwners:(NSArray<NSDictionary<NSString *, id> *> *)owners force:(BOOL)force {
  if (!force && [owners isEqualToArray:self.lastOwners]) {
    return;
  }

  self.lastOwners = owners;
  [self.notificationCenter
    postNotificationName:StateNotification
                   object:@"com.jaykuroyanagi.audio-process-watcher"
                 userInfo:@{ @"owners": owners }
       deliverImmediately:YES];
}

- (void)refreshAndPublish:(BOOL)force {
  self.forceNextPublish = self.forceNextPublish || force;

  OSStatus status = noErr;
  NSArray<NSNumber *> *objectIDs = [self processObjectIDsWithStatus:&status];
  if (objectIDs == nil) {
    fprintf(stderr, "audio-process-watcher: failed to read the process list (%d)\n", status);
    [self scheduleRetry];
    return;
  }

  BOOL listenersComplete = [self updateListenersForObjectIDs:objectIDs];
  BOOL ownersComplete = YES;
  NSArray<NSDictionary<NSString *, id> *> *owners = [self activeOwnersForObjectIDs:objectIDs
                                                                          complete:&ownersComplete];
  if (owners == nil) {
    [self scheduleRetry];
    return;
  }

  [self publishOwners:owners force:self.forceNextPublish];
  self.forceNextPublish = NO;

  if (!listenersComplete || !ownersComplete) {
    [self scheduleRetry];
    return;
  }

  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(retryRefreshScheduled)
                                             object:nil];
  self.retryRefreshPending = NO;
  self.retryCount = 0;
}

- (void)scheduleRefresh {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(retryRefreshScheduled)
                                             object:nil];
  self.retryRefreshPending = NO;
  self.retryCount = 0;
  if (self.eventRefreshPending) {
    return;
  }

  self.eventRefreshPending = YES;
  [self performSelector:@selector(eventRefreshScheduled) withObject:nil afterDelay:0.1];
}

- (void)scheduleRetry {
  static const NSTimeInterval delays[] = { 0.25, 1, 5 };
  if (self.retryRefreshPending || self.retryCount >= sizeof(delays) / sizeof(delays[0])) {
    return;
  }

  NSTimeInterval delay = delays[self.retryCount];
  self.retryCount += 1;
  self.retryRefreshPending = YES;
  [self performSelector:@selector(retryRefreshScheduled) withObject:nil afterDelay:delay];
}

- (void)eventRefreshScheduled {
  self.eventRefreshPending = NO;
  [self refreshAndPublish:NO];
}

- (void)retryRefreshScheduled {
  self.retryRefreshPending = NO;
  [self refreshAndPublish:NO];
}

- (void)refreshRequested:(NSNotification *)notification {
  self.retryCount = 0;
  [self refreshAndPublish:YES];
}

@end

int main(void) {
  if (@available(macOS 14.2, *)) {
    AudioProcessWatcher *watcher = nil;
    NSRunLoop *runLoop = nil;
    @autoreleasepool {
      watcher = [[AudioProcessWatcher alloc] init];
      if (![watcher start]) {
        return 1;
      }
      runLoop = [NSRunLoop mainRunLoop];
    }

    while (watcher != nil) {
      @autoreleasepool {
        if (![runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {
          return 1;
        }
      }
    }
    return 0;
  }

  @autoreleasepool {
    fprintf(stderr, "audio-process-watcher: macOS 14.2 or newer is required\n");
    return 0;
  }
}
