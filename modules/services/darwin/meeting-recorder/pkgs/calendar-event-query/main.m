#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>

#import <dispatch/dispatch.h>
#import <math.h>
#import <stdio.h>

static NSString *const ResponseNotification = @"com.jaykuroyanagi.calendar-event-query.response";

static void SendResponse(NSString *requestID, NSDictionary *payload) {
    if (requestID.length == 0) {
        return;
    }
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:ResponseNotification
                       object:@"com.jaykuroyanagi.calendar-event-query"
                     userInfo:@{ @"requestID": requestID, @"payload": payload }
           deliverImmediately:YES];
}

static BOOL ParseTimestamp(NSString *value, NSTimeInterval *timestamp) {
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double parsed = 0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed)) {
        return NO;
    }

    *timestamp = parsed;
    return YES;
}

static void AddURL(NSMutableOrderedSet<NSString *> *urls, NSURL *url) {
    NSString *value = url.absoluteString;
    if (value.length > 0) {
        [urls addObject:value];
    }
}

static void AddURLsFromText(
    NSMutableOrderedSet<NSString *> *urls,
    NSDataDetector *detector,
    NSString *text
) {
    if (text.length == 0 || detector == nil) {
        return;
    }

    NSRange range = NSMakeRange(0, text.length);
    [detector enumerateMatchesInString:text
                               options:0
                                 range:range
                            usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
        (void)flags;
        (void)stop;
        if (result.resultType == NSTextCheckingTypeLink) {
            AddURL(urls, result.URL);
        }
    }];
}

static NSArray<NSDictionary *> *QueryEvents(
    EKEventStore *store,
    NSDate *fromDate,
    NSDate *toDate
) {
    NSPredicate *predicate = [store predicateForEventsWithStartDate:fromDate
                                                            endDate:toDate
                                                          calendars:nil];
    NSArray<EKEvent *> *events = [[store eventsMatchingPredicate:predicate]
        sortedArrayUsingComparator:^NSComparisonResult(EKEvent *left, EKEvent *right) {
            NSComparisonResult startOrder = [left.startDate compare:right.startDate];
            if (startOrder != NSOrderedSame) {
                return startOrder;
            }
            NSString *leftTitle = left.title ?: @"";
            NSString *rightTitle = right.title ?: @"";
            return [leftTitle compare:rightTitle options:NSCaseInsensitiveSearch];
        }];

    NSError *detectorError = nil;
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink
                                                               error:&detectorError];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (EKEvent *event in events) {
        if (event.status == EKEventStatusCanceled || event.isAllDay) {
            continue;
        }
        if ([event.startDate compare:toDate] == NSOrderedDescending
            || [event.endDate compare:fromDate] != NSOrderedDescending) {
            continue;
        }

        NSString *title = [event.title stringByTrimmingCharactersInSet:whitespace];
        if (title.length == 0) {
            continue;
        }

        NSMutableOrderedSet<NSString *> *urls = [NSMutableOrderedSet orderedSet];
        AddURL(urls, event.URL);
        AddURLsFromText(urls, detector, event.location);
        AddURLsFromText(urls, detector, event.notes);

        NSString *identifier = event.eventIdentifier ?: event.calendarItemIdentifier ?: @"";
        [results addObject:@{
            @"id": identifier,
            @"title": title,
            @"startTimestamp": @(event.startDate.timeIntervalSince1970),
            @"endTimestamp": @(event.endDate.timeIntervalSince1970),
            @"urls": urls.array,
        }];
    }

    if (detectorError != nil) {
        fprintf(stderr, "calendar-event-query: %s\n", detectorError.localizedDescription.UTF8String);
    }
    return results;
}

static BOOL RequestCalendarAccess(
    EKEventStore *store,
    NSTimeInterval timeoutSeconds,
    BOOL *timedOut,
    NSError **requestError
) {
    *timedOut = NO;
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (status == EKAuthorizationStatusFullAccess) {
        return YES;
    }
    if (status == EKAuthorizationStatusDenied || status == EKAuthorizationStatusRestricted) {
        return NO;
    }

    __block BOOL completed = NO;
    __block BOOL granted = NO;
    __block NSError *accessError = nil;
    [store requestFullAccessToEventsWithCompletion:^(BOOL allowed, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            granted = allowed;
            accessError = error;
            completed = YES;
        });
    }];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!completed) {
        *timedOut = YES;
        return NO;
    }
    if (requestError != NULL) {
        *requestError = accessError;
    }
    return granted;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *requestID = nil;
        NSTimeInterval fromTimestamp = NAN;
        NSTimeInterval toTimestamp = NAN;
        NSTimeInterval authorizationTimeout = NAN;

        for (int index = 1; index < argc; index++) {
            NSString *argument = [NSString stringWithUTF8String:argv[index]];
            if ([argument isEqualToString:@"--request-id"] && index + 1 < argc) {
                requestID = [NSString stringWithUTF8String:argv[++index]];
                continue;
            }
            if (([argument isEqualToString:@"--from"]
                 || [argument isEqualToString:@"--to"]
                 || [argument isEqualToString:@"--authorization-timeout"])
                && index + 1 < argc) {
                NSString *value = [NSString stringWithUTF8String:argv[++index]];
                NSTimeInterval parsed = 0;
                if (!ParseTimestamp(value, &parsed)) {
                    SendResponse(requestID, @{ @"status": @"error", @"message": @"Invalid numeric argument" });
                    return 2;
                }
                if ([argument isEqualToString:@"--from"]) {
                    fromTimestamp = parsed;
                } else if ([argument isEqualToString:@"--to"]) {
                    toTimestamp = parsed;
                } else {
                    authorizationTimeout = parsed;
                }
                continue;
            }

            SendResponse(requestID, @{ @"status": @"error", @"message": @"Invalid arguments" });
            return 2;
        }

        if (requestID.length == 0) {
            fprintf(
                stderr,
                "usage: calendar-event-query --request-id ID --from TIMESTAMP --to TIMESTAMP --authorization-timeout SECONDS\n"
            );
            return 2;
        }
        if (!isfinite(fromTimestamp)
            || !isfinite(toTimestamp)
            || fromTimestamp >= toTimestamp
            || !isfinite(authorizationTimeout)
            || authorizationTimeout <= 0) {
            SendResponse(requestID, @{ @"status": @"error", @"message": @"Invalid query arguments" });
            return 2;
        }

        EKEventStore *store = [[EKEventStore alloc] init];
        BOOL timedOut = NO;
        NSError *accessError = nil;
        if (!RequestCalendarAccess(store, authorizationTimeout, &timedOut, &accessError)) {
            if (timedOut) {
                SendResponse(requestID, @{ @"status": @"error", @"message": @"Calendar authorization timed out" });
                return 1;
            }
            if (accessError != nil) {
                SendResponse(requestID, @{ @"status": @"error", @"message": accessError.localizedDescription });
                return 1;
            }
            SendResponse(requestID, @{ @"status": @"denied", @"events": @[] });
            return 1;
        }

        NSDate *fromDate = [NSDate dateWithTimeIntervalSince1970:fromTimestamp];
        NSDate *toDate = [NSDate dateWithTimeIntervalSince1970:toTimestamp];
        NSArray<NSDictionary *> *events = QueryEvents(store, fromDate, toDate);
        SendResponse(requestID, @{ @"status": @"ok", @"events": events });
        return 0;
    }
}
