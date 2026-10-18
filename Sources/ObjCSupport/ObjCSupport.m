#import "ObjCSupport.h"
#import <AVFoundation/AVFoundation.h>

static NSError *MMErrorFromException(NSException *exception) {
    return [NSError errorWithDomain:exception.name
                               code:0
                           userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
}

BOOL MMTryObjC(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MMErrorFromException(exception);
        return NO;
    }
}

NSArray *MMFilterWithPredicate(NSArray *objects, NSPredicate *predicate, NSError **error) {
    @try {
        return [objects filteredArrayUsingPredicate:predicate];
    } @catch (NSException *exception) {
        if (error) *error = MMErrorFromException(exception);
        return nil;
    }
}

BOOL MMConnectNodes(AVAudioEngine *engine, AVAudioNode *from, AVAudioNode *to, AVAudioFormat *format, NSError **error) {
    @try {
        [engine connect:from to:to format:format];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = MMErrorFromException(exception);
        return NO;
    }
}
