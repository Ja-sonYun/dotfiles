#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

static NSString *const vendorPath = @"/Applications/_Slack/Slack.app";
static NSString *const launcherID = @"com.user.slack-launcher";
static NSString *const vendorID = @"com.tinyspeck.slackmacgap";

@interface SlackLauncher : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSMutableArray<NSURL *> *pendingURLs;
@property BOOL busy;
@property(nonatomic, strong) NSTask *slack;
@property(nonatomic, strong) NSDate *deadline;
@property(nonatomic, copy) NSString *errorLogPath;
@end

@implementation SlackLauncher
- (void)fail:(NSString *)message {
    if (self.errorLogPath) {
        NSFileHandle *log = [NSFileHandle fileHandleForReadingAtPath:self.errorLogPath];
        if (log) {
            unsigned long long length = [log seekToEndOfFile];
            [log seekToFileOffset:length > 4096 ? length - 4096 : 0];
            NSString *output = [[NSString alloc] initWithData:[log readDataToEndOfFile]
                                                   encoding:NSUTF8StringEncoding];
            [log closeFile];
            if (output.length) {
                message = [message stringByAppendingFormat:@"\n\n%@", output];
            }
        }
        message = [message stringByAppendingFormat:@"\n\nSlack error log: %@", self.errorLogPath];
    }
    fprintf(stderr, "Slack launcher: %s\n", message.UTF8String);
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Slack could not be opened";
    alert.informativeText = message;
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
    exit(EXIT_FAILURE);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if (arguments.count == 2 &&
        ([arguments[1] isEqualToString:@"--register"] ||
         [arguments[1] isEqualToString:@"--unregister"])) {
        BOOL registering = [arguments[1] isEqualToString:@"--register"];
        NSString *current = CFBridgingRelease(LSCopyDefaultHandlerForURLScheme(CFSTR("slack")));
        if ((registering && [current isEqualToString:launcherID]) ||
            (!registering && ![current isEqualToString:launcherID])) {
            [NSApp terminate:nil];
            return;
        }
        NSURL *target = [NSURL fileURLWithPath:registering ? @"/Applications/Slack.app" : vendorPath];
        // Declaring a URL scheme does not make this app its default handler.
        [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:target
                                           toOpenURLsWithScheme:@"slack"
                                              completionHandler:^(NSError *error) {
            if (error) {
                fprintf(stderr, "Slack URL registration incomplete: %s\n", error.localizedDescription.UTF8String);
                exit(EXIT_FAILURE);
            }
            exit(EXIT_SUCCESS);
        }];
        return;
    }
    [self begin];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if ([url.scheme.lowercaseString isEqualToString:@"slack"]) {
            [self.pendingURLs addObject:url];
        }
    }
    [self begin];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    [self begin];
    return NO;
}

- (void)begin {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    NSBundle *vendor = [NSBundle bundleWithPath:vendorPath];
    if (![vendor.bundleIdentifier isEqualToString:vendorID] || !vendor.executableURL) {
        [self fail:@"Slack is missing from /Applications/_Slack/Slack.app. Complete the Homebrew installation before opening this launcher."];
        return;
    }

    NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:vendorID];
    if (running.count == 0) {
        NSString *logDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        NSError *error;
        if (![NSFileManager.defaultManager createDirectoryAtPath:logDirectory
                                    withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self fail:error.localizedDescription];
            return;
        }
        NSString *logPath = [logDirectory stringByAppendingPathComponent:@"slack-launcher.stderr.log"];
        if (![NSFileManager.defaultManager createFileAtPath:logPath contents:nil
                                               attributes:@{NSFilePosixPermissions: @0600}]) {
            [self fail:[NSString stringWithFormat:@"Could not create Slack error log: %@", logPath]];
            return;
        }
        NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!log) {
            [self fail:[NSString stringWithFormat:@"Could not open Slack error log: %@", logPath]];
            return;
        }
        self.errorLogPath = logPath;
        self.slack = [[NSTask alloc] init];
        self.slack.executableURL = vendor.executableURL;
        self.slack.arguments = @[@"--remote-debugging-address=127.0.0.1", @"--remote-debugging-port=9222"];
        self.slack.standardOutput = NSFileHandle.fileHandleWithNullDevice;
        self.slack.standardError = log;
        BOOL launched = [self.slack launchAndReturnError:&error];
        [log closeFile];
        if (!launched) {
            [self fail:error.localizedDescription];
            return;
        }
    }
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    [self waitForDebugging];
}

- (void)waitForDebugging {
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:9222/json/list"]
                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                       timeoutInterval:1];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ready = NO;
        if (data && [(NSHTTPURLResponse *)response statusCode] == 200) {
            id pages = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([pages isKindOfClass:NSArray.class]) {
                for (id page in pages) {
                    if ([page isKindOfClass:NSDictionary.class] &&
                        [page[@"url"] isKindOfClass:NSString.class] &&
                        [page[@"url"] hasPrefix:@"https://app.slack.com/"]) {
                        ready = YES;
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready) {
                [self forward];
            } else if (self.slack && !self.slack.isRunning) {
                NSString *reason = self.slack.terminationReason == NSTaskTerminationReasonUncaughtSignal
                    ? @"signal" : @"exit code";
                [self fail:[NSString stringWithFormat:@"Slack exited before debugging became available (%@ %d).",
                            reason, self.slack.terminationStatus]];
            } else if (self.deadline.timeIntervalSinceNow <= 0) {
                [self fail:@"Slack debugging is not available on 127.0.0.1:9222. Fully quit Slack, then open /Applications/Slack.app again. Slack has not been closed automatically."];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    [self waitForDebugging];
                });
            }
        });
    }] resume];
}

- (void)forward {
    NSURL *vendor = [NSURL fileURLWithPath:vendorPath];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    void (^completion)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self fail:error.localizedDescription];
            } else if (self.pendingURLs.count) {
                [self forward];
            } else {
                [NSApp terminate:nil];
            }
        });
    };
    if (self.pendingURLs.count) {
        NSArray<NSURL *> *urls = [self.pendingURLs copy];
        [self.pendingURLs removeAllObjects];
        // Target the vendor explicitly to avoid routing the URL back to this launcher.
        [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:vendor configuration:configuration completionHandler:completion];
    } else {
        [NSWorkspace.sharedWorkspace openApplicationAtURL:vendor configuration:configuration completionHandler:completion];
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        __attribute__((objc_precise_lifetime)) SlackLauncher *delegate = [[SlackLauncher alloc] init];
        delegate.pendingURLs = [NSMutableArray array];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return EXIT_SUCCESS;
}
