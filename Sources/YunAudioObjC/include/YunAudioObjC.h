#ifndef YUNAUDIO_OBJC_H
#define YUNAUDIO_OBJC_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block, returning the reason of any Objective-C exception it raised
/// rather than letting it terminate the process.
///
/// Swift has no `@catch`. An `NSException` raised inside a framework unwinds
/// straight past Swift frames to `std::terminate`, so a single raising call in
/// an otherwise correct program is an abort with no recourse — and several of
/// the AVFoundation calls this application has to make are documented to raise
/// rather than to return an error.
///
/// `AVAudioEngine`'s connection methods are the ones that matter here. They
/// raise when the graph cannot be reconfigured for a format, which depends on
/// the output device — something this application changes while running, and
/// something a person can unplug. A karaoke machine that dies when somebody
/// opens an unusual file is not a karaoke machine.
///
/// - Returns: nil when the block completed, or the exception's reason when it
///   did not. The reason is what the caller can put in front of somebody;
///   `name` alone is `NSInternalInconsistencyException` for nearly everything.
NSString *_Nullable YunCatchingObjCException(void (^block)(void))
    NS_SWIFT_NAME(catchingObjCException(_:));

NS_ASSUME_NONNULL_END

#endif
