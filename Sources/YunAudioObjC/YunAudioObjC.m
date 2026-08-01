#import "include/YunAudioObjC.h"

NSString *_Nullable YunCatchingObjCException(void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        // The reason, or the name when there is no reason — an exception with
        // neither is not something to report as an empty string.
        return exception.reason ?: exception.name ?: @"unknown Objective-C exception";
    }
    return nil;
}
