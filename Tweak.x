#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <notify.h>

// Substrate-free implementation of PleaseDontStopTheMusic.
// Hooks AVAudioSession with the Objective-C runtime so this jailed dylib
// does not need Logos, CydiaSubstrate, or MobileSubstrate.

static BOOL gIsVideoApp = NO;
static BOOL gSessionActive = NO;

static NSString *const kBegin = @"com.pdstm.pip.begin";

typedef BOOL (*PDSTMSetCategoryErrorIMP)(id, SEL, NSString *, NSError **);
typedef BOOL (*PDSTMSetCategoryModeOptionsErrorIMP)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*PDSTMSetCategoryModePolicyOptionsErrorIMP)(id, SEL, NSString *, NSString *, AVAudioSessionRouteSharingPolicy, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*PDSTMSetCategoryWithOptionsErrorIMP)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
typedef BOOL (*PDSTMSetActiveErrorIMP)(id, SEL, BOOL, NSError **);
typedef BOOL (*PDSTMSetActiveOptionsErrorIMP)(id, SEL, BOOL, AVAudioSessionSetActiveOptions, NSError **);

static PDSTMSetCategoryErrorIMP gOrigSetCategoryError = NULL;
static PDSTMSetCategoryModeOptionsErrorIMP gOrigSetCategoryModeOptionsError = NULL;
static PDSTMSetCategoryModePolicyOptionsErrorIMP gOrigSetCategoryModePolicyOptionsError = NULL;
static PDSTMSetCategoryWithOptionsErrorIMP gOrigSetCategoryWithOptionsError = NULL;
static PDSTMSetActiveErrorIMP gOrigSetActiveError = NULL;
static PDSTMSetActiveOptionsErrorIMP gOrigSetActiveOptionsError = NULL;

static IMP PDSTMHookInstanceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    // If the implementation is inherited, add a class-local override instead
    // of changing the superclass implementation for every other class.
    if (class_addMethod(cls, selector, replacement, types)) return original;

    Method ownMethod = class_getInstanceMethod(cls, selector);
    return method_setImplementation(ownMethod, replacement);
}

static BOOL PDSTMShouldMix(AVAudioSession *session) {
    if (gIsVideoApp) return NO;
    return session.isOtherAudioPlaying;
}

static void PDSTMPost(NSString *name) {
    notify_post(name.UTF8String);
}

static void PDSTMApplyMix(AVAudioSession *session) {
    if (!session) return;

    NSString *category = session.category;
    if ([category isEqualToString:AVAudioSessionCategorySoloAmbient])
        category = AVAudioSessionCategoryAmbient;

    AVAudioSessionCategoryOptions options =
        session.categoryOptions | AVAudioSessionCategoryOptionMixWithOthers;

    if (gOrigSetCategoryModeOptionsError) {
        gOrigSetCategoryModeOptionsError(session,
            @selector(setCategory:mode:options:error:),
            category, session.mode ?: AVAudioSessionModeDefault, options, nil);
    } else if (gOrigSetCategoryError) {
        gOrigSetCategoryError(session, @selector(setCategory:error:), category, nil);
    }
}

static void PDSTMGoSecondary(void) {
    if (gIsVideoApp) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *category = session.category;
    BOOL playbackish =
        [category isEqualToString:AVAudioSessionCategoryPlayback] ||
        [category isEqualToString:AVAudioSessionCategoryPlayAndRecord];

    if (!gSessionActive || !playbackish) return;
    if (session.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) return;

    PDSTMApplyMix(session);

    if (gOrigSetActiveError)
        gOrigSetActiveError(session, @selector(setActive:error:), YES, nil);
}

static void PDSTMDarwinCallback(CFNotificationCenterRef center,
                                void *observer,
                                CFStringRef name,
                                const void *object,
                                CFDictionaryRef userInfo) {
    if ([(NSString *)CFBridgingRelease(CFRetain(name)) isEqualToString:kBegin])
        PDSTMGoSecondary();
}

static BOOL PDSTMSetCategoryError(id self, SEL cmd, NSString *category, NSError **error) {
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient])
            category = AVAudioSessionCategoryAmbient;

        if ([category isEqualToString:AVAudioSessionCategoryPlayback] &&
            gOrigSetCategoryModeOptionsError) {
            return gOrigSetCategoryModeOptionsError(self,
                @selector(setCategory:mode:options:error:),
                category, AVAudioSessionModeDefault,
                AVAudioSessionCategoryOptionMixWithOthers, error);
        }
    }
    return gOrigSetCategoryError ? gOrigSetCategoryError(self, cmd, category, error) : NO;
}

static BOOL PDSTMSetCategoryModeOptionsError(id self, SEL cmd,
                                              NSString *category, NSString *mode,
                                              AVAudioSessionCategoryOptions options,
                                              NSError **error) {
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient])
            category = AVAudioSessionCategoryAmbient;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return gOrigSetCategoryModeOptionsError ?
        gOrigSetCategoryModeOptionsError(self, cmd, category, mode, options, error) : NO;
}

static BOOL PDSTMSetCategoryModePolicyOptionsError(id self, SEL cmd,
                                                    NSString *category, NSString *mode,
                                                    AVAudioSessionRouteSharingPolicy policy,
                                                    AVAudioSessionCategoryOptions options,
                                                    NSError **error) {
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient])
            category = AVAudioSessionCategoryAmbient;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return gOrigSetCategoryModePolicyOptionsError ?
        gOrigSetCategoryModePolicyOptionsError(self, cmd, category, mode, policy, options, error) : NO;
}

static BOOL PDSTMSetCategoryWithOptionsError(id self, SEL cmd,
                                              NSString *category,
                                              AVAudioSessionCategoryOptions options,
                                              NSError **error) {
    if (PDSTMShouldMix(self)) {
        if ([category isEqualToString:AVAudioSessionCategorySoloAmbient])
            category = AVAudioSessionCategoryAmbient;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    return gOrigSetCategoryWithOptionsError ?
        gOrigSetCategoryWithOptionsError(self, cmd, category, options, error) : NO;
}

static BOOL PDSTMSetActiveError(id self, SEL cmd, BOOL active, NSError **error) {
    gSessionActive = active;
    if (gIsVideoApp && active && [(AVAudioSession *)self isOtherAudioPlaying])
        PDSTMPost(kBegin);

    if (active && PDSTMShouldMix(self) &&
        !(((AVAudioSession *)self).categoryOptions & AVAudioSessionCategoryOptionMixWithOthers))
        PDSTMApplyMix(self);

    return gOrigSetActiveError ? gOrigSetActiveError(self, cmd, active, error) : NO;
}

static BOOL PDSTMSetActiveOptionsError(id self, SEL cmd, BOOL active,
                                        AVAudioSessionSetActiveOptions options,
                                        NSError **error) {
    gSessionActive = active;
    if (gIsVideoApp && active && [(AVAudioSession *)self isOtherAudioPlaying])
        PDSTMPost(kBegin);

    if (active && PDSTMShouldMix(self) &&
        !(((AVAudioSession *)self).categoryOptions & AVAudioSessionCategoryOptionMixWithOthers))
        PDSTMApplyMix(self);

    return gOrigSetActiveOptionsError ?
        gOrigSetActiveOptionsError(self, cmd, active, options, error) : NO;
}

static void PDSTMInstallHooks(void) {
    Class cls = objc_getClass("AVAudioSession");
    if (!cls) return;

    gOrigSetCategoryError = (PDSTMSetCategoryErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setCategory:error:), (IMP)PDSTMSetCategoryError);
    gOrigSetCategoryModeOptionsError = (PDSTMSetCategoryModeOptionsErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setCategory:mode:options:error:), (IMP)PDSTMSetCategoryModeOptionsError);
    gOrigSetCategoryModePolicyOptionsError = (PDSTMSetCategoryModePolicyOptionsErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setCategory:mode:routeSharingPolicy:options:error:),
        (IMP)PDSTMSetCategoryModePolicyOptionsError);
    gOrigSetCategoryWithOptionsError = (PDSTMSetCategoryWithOptionsErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setCategory:withOptions:error:), (IMP)PDSTMSetCategoryWithOptionsError);
    gOrigSetActiveError = (PDSTMSetActiveErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setActive:error:), (IMP)PDSTMSetActiveError);
    gOrigSetActiveOptionsError = (PDSTMSetActiveOptionsErrorIMP)PDSTMHookInstanceMethod(
        cls, @selector(setActive:withOptions:error:), (IMP)PDSTMSetActiveOptionsError);
}

__attribute__((constructor))
static void PDSTMInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSArray *videoApps = @[
            @"com.zhiliaoapp.musically",
            @"com.zhiliaoapp.musically.go",
            @"com.ss.iphone.ugc.Ame"
        ];
        gIsVideoApp = [videoApps containsObject:bundleID];

        PDSTMInstallHooks();

        if (gIsVideoApp) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                object:nil queue:nil
                usingBlock:^(NSNotification *notification) { PDSTMPost(kBegin); }];
            [[NSNotificationCenter defaultCenter]
                addObserverForName:@"UIApplicationWillEnterForegroundNotification"
                object:nil queue:nil
                usingBlock:^(NSNotification *notification) { PDSTMPost(kBegin); }];
            PDSTMPost(kBegin);
        } else {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                PDSTMDarwinCallback,
                (__bridge CFStringRef)kBegin,
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }

        NSLog(@"[PleaseDontStopTheMusic] loaded (bundle=%@ video=%d)",
              bundleID, gIsVideoApp);
    }
}
