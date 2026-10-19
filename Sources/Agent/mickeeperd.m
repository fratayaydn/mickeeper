// mickeeperd: keeps the Mac's microphone the way you set it.
//
//   Automatic         When macOS makes Bluetooth headphones (AirPods) the default input, on connect or when they go
//                     back in your ears, or a nearby iPhone's (Continuity) microphone, switch back to the microphone
//                     used before. As soon as an app uses a Bluetooth headset's microphone, playback drops to call
//                     quality; this keeps it from happening.
//   Chosen mic        Or always use one particular microphone, of any kind, while it is connected.
//   Level lock        Optionally, put the input level back when an app (Zoom, Teams, Chrome) changes it.
//
// Event-driven: wakes only when CoreAudio reports a device, default input or level change; no polling.
// Settings live in the "io.github.fratayaydn.mickeeper" preferences domain; MicKeeper.app writes them and posts
// SETTINGS_CHANGED_NOTIFICATION. Only this agent changes the input device and its level, so the two never race.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "Updater.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>

#define PREFS_DOMAIN                  CFSTR("io.github.fratayaydn.mickeeper")
#define SETTINGS_CHANGED_NOTIFICATION CFSTR("io.github.fratayaydn.mickeeper.SettingsChanged")
#define STATUS_CHANGED_NOTIFICATION   CFSTR("io.github.fratayaydn.mickeeper.StatusChanged")
#define KEY_PREFERRED       CFSTR("PreferredInput")      // device UID; absent: automatic
#define KEY_LOCK_LEVEL      CFSTR("LockLevel")           // bool, default off
#define KEY_LOCKED_LEVELS   CFSTR("LockedLevels")        // { device UID: level 0...1 }
#define KEY_LAST_INPUT      CFSTR("LastInput")           // UID of the last real microphone in use
#define KEY_HIFI_COUNT      CFSTR("HiFiCount")
#define KEY_HIFI_LAST       CFSTR("HiFiLast")
#define KEY_IPHONE_COUNT    CFSTR("ContinuityCount")
#define KEY_IPHONE_LAST     CFSTR("ContinuityLast")
#define KEY_LEVEL_COUNT     CFSTR("LevelCount")
#define KEY_LEVEL_LAST      CFSTR("LevelLast")
#define AGENT_PLIST         @"io.github.fratayaydn.mickeeper.agent.plist"
#define UPDATER_PLIST       @"io.github.fratayaydn.mickeeper.updater.plist"

// ServiceManagement is loaded only when the app is removed, so it costs no memory while running.
@interface NSObject (SMAppService)
+ (id)agentServiceWithPlistName:(NSString *)name;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

static BOOL gLockLevel = NO;
static NSString *gPreferredUID;
static NSDictionary *gLockedLevels;
static BOOL gCountFixes = YES;   // NO while applying settings: those are the user's choices, not corrections
static AudioDeviceID gWatched = kAudioObjectUnknown;  // the default input whose level we watch
static NSString *gWatchedUID;                           // and, looked up once, its UID and level elements:
static NSArray<NSNumber *> *gWatchedElements;           // each CoreAudio call is a round trip to coreaudiod
static AudioObjectPropertyListenerBlock gLevelListener;
static dispatch_source_t gBundleWatch;
static char gExecutable[PATH_MAX];

#pragma mark - CoreAudio helpers

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, AudioObjectPropertyElement el) {
    return (AudioObjectPropertyAddress){ sel, scope, el };
}

static AudioDeviceID defaultInput(void) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 sz = sizeof(d);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d);
    return d;
}

static void setDefaultInput(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(d), &d);
}

static NSArray<NSNumber *> *allDevices(void) {
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz) != noErr) return @[];
    AudioDeviceID *ids = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    NSMutableArray *list = [NSMutableArray array];
    for (UInt32 i = 0; i < sz / sizeof(AudioDeviceID); i++) [list addObject:@(ids[i])];
    free(ids);
    return list;
}

static NSString *deviceUID(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    CFStringRef uid = NULL;
    UInt32 sz = sizeof(uid);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString *)uid;
}

static NSString *deviceName(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    CFStringRef name = NULL;
    UInt32 sz = sizeof(name);
    if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &name) != noErr || !name) return @"?";
    return (__bridge_transfer NSString *)name;
}

static UInt32 transport(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    UInt32 t = 0, sz = sizeof(t);
    AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &t);
    return t;
}

static BOOL hasInput(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain);
    UInt32 sz = 0;
    return AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &sz) == noErr && sz > 0;
}

static BOOL isHeadset(AudioDeviceID d) {
    UInt32 t = transport(d);
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE;
}

static BOOL isContinuity(AudioDeviceID d) {
    UInt32 t = transport(d);
    return t == kAudioDeviceTransportTypeContinuityCaptureWired || t == kAudioDeviceTransportTypeContinuityCaptureWireless;
}

// A microphone worth switching to: not a Bluetooth headset (that is the problem), not an iPhone's Continuity
// microphone, AirPlay, or a virtual or aggregate device.
static BOOL isRealMic(AudioDeviceID d) {
    if (d == kAudioObjectUnknown || !hasInput(d)) return NO;
    switch (transport(d)) {
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE:
        case kAudioDeviceTransportTypeVirtual:
        case kAudioDeviceTransportTypeAggregate:
        case kAudioDeviceTransportTypeAutoAggregate:
        case kAudioDeviceTransportTypeAirPlay:
        case kAudioDeviceTransportTypeContinuityCaptureWired:
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
        case kAudioDeviceTransportTypeUnknown:
            return NO;
        default:
            return YES;
    }
}

static AudioDeviceID deviceWithUID(NSString *uid) {
    if (!uid) return kAudioObjectUnknown;
    for (NSNumber *n in allDevices())
        if ([deviceUID(n.unsignedIntValue) isEqualToString:uid]) return n.unsignedIntValue;
    return kAudioObjectUnknown;
}

#pragma mark - Input level

// Devices expose the input level either on the main element or per channel.
static NSArray<NSNumber *> *levelElements(AudioDeviceID d) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain);
    if (AudioObjectHasProperty(d, &a)) return @[ @(kAudioObjectPropertyElementMain) ];
    NSMutableArray *elements = [NSMutableArray array];
    for (UInt32 ch = 1; ch <= 8; ch++) {
        a.mElement = ch;
        if (AudioObjectHasProperty(d, &a)) [elements addObject:@(ch)];
    }
    return elements;
}

static BOOL getLevelOf(AudioDeviceID d, NSArray<NSNumber *> *elements, Float32 *level) {
    for (NSNumber *el in elements) {
        AudioObjectPropertyAddress a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el.unsignedIntValue);
        UInt32 sz = sizeof(*level);
        if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, level) == noErr) return YES;
    }
    return NO;
}

static BOOL getLevel(AudioDeviceID d, Float32 *level) { return getLevelOf(d, levelElements(d), level); }

static void setLevelOf(AudioDeviceID d, NSArray<NSNumber *> *elements, Float32 level) {
    for (NSNumber *el in elements) {
        AudioObjectPropertyAddress a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el.unsignedIntValue);
        AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof(level), &level);
    }
}

#pragma mark - Settings and status

static void loadSettings(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    NSNumber *lock = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_LOCK_LEVEL, PREFS_DOMAIN));
    gLockLevel = [lock isKindOfClass:[NSNumber class]] && lock.boolValue;
    NSString *preferred = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_PREFERRED, PREFS_DOMAIN));
    gPreferredUID = [preferred isKindOfClass:[NSString class]] && preferred.length ? preferred : nil;
    NSDictionary *levels = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_LOCKED_LEVELS, PREFS_DOMAIN));
    gLockedLevels = [levels isKindOfClass:[NSDictionary class]] ? levels : @{};
}

static void setPref(CFStringRef key, id value) {
    CFPreferencesSetAppValue(key, (__bridge CFPropertyListRef)value, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
}

// Written only when MicKeeper actually steps in, so the app can show how often that happens. An app fighting over
// the level can trigger many corrections in a row, so they are counted in memory and saved once, 2 s after the first.
static NSMutableDictionary<NSString *, NSNumber *> *gPendingCounts;
static NSMutableDictionary<NSString *, NSDate *> *gPendingLast;

static void savePendingCounts(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    for (NSString *countKey in gPendingCounts) {
        NSNumber *saved = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)countKey, PREFS_DOMAIN));
        long total = ([saved isKindOfClass:[NSNumber class]] ? saved.longValue : 0) + gPendingCounts[countKey].longValue;
        CFPreferencesSetAppValue((__bridge CFStringRef)countKey, (__bridge CFNumberRef)@(total), PREFS_DOMAIN);
    }
    for (NSString *lastKey in gPendingLast)
        CFPreferencesSetAppValue((__bridge CFStringRef)lastKey, (__bridge CFDateRef)gPendingLast[lastKey], PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    gPendingCounts = nil;
    gPendingLast = nil;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), STATUS_CHANGED_NOTIFICATION, NULL, NULL, true);
}

static void recordFix(CFStringRef countKey, CFStringRef lastKey, NSString *what) {
    if (!gCountFixes) return;
    fprintf(stderr, "mickeeperd: %s\n", what.UTF8String);
    if (!gPendingCounts) {
        gPendingCounts = [NSMutableDictionary dictionary];
        gPendingLast = [NSMutableDictionary dictionary];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ savePendingCounts(); });
    }
    NSString *key = (__bridge NSString *)countKey;
    gPendingCounts[key] = @(gPendingCounts[key].longValue + 1);
    gPendingLast[(__bridge NSString *)lastKey] = [NSDate date];
}

#pragma mark - Keeping the microphone

// The microphone the user chose, of any kind (choosing AirPods here is how to use them on purpose), if connected.
static AudioDeviceID chosenMic(void) {
    AudioDeviceID d = deviceWithUID(gPreferredUID);
    return d != kAudioObjectUnknown && hasInput(d) ? d : kAudioObjectUnknown;
}

// Where to go when Bluetooth headphones or an iPhone took over: the microphone used before, else the built-in one,
// else any other real microphone. Nothing suitable: leave it alone rather than leave the Mac without a microphone.
static AudioDeviceID replacementMic(void) {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    NSString *last = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_LAST_INPUT, PREFS_DOMAIN));
    AudioDeviceID d = deviceWithUID([last isKindOfClass:[NSString class]] ? last : nil);
    if (isRealMic(d)) return d;
    AudioDeviceID other = kAudioObjectUnknown;
    for (NSNumber *n in allDevices()) {
        AudioDeviceID c = n.unsignedIntValue;
        if (!isRealMic(c)) continue;
        if (transport(c) == kAudioDeviceTransportTypeBuiltIn) return c;
        if (!other) other = c;
    }
    return other;
}

static void lockedLevelChanged(UInt32 n, const AudioObjectPropertyAddress *a);

// Follow the default input's level, and bring it to its locked value if there is one.
static void watchLevel(AudioDeviceID d) {
    if (gWatched != kAudioObjectUnknown && gWatched != d) {
        for (NSNumber *el in gWatchedElements) {
            AudioObjectPropertyAddress a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el.unsignedIntValue);
            AudioObjectRemovePropertyListenerBlock(gWatched, &a, dispatch_get_main_queue(), gLevelListener);
        }
    }
    if (gWatched != d) {
        gWatchedUID = d != kAudioObjectUnknown ? deviceUID(d) : nil;
        gWatchedElements = d != kAudioObjectUnknown ? levelElements(d) : @[];
        for (NSNumber *el in gWatchedElements) {
            AudioObjectPropertyAddress a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el.unsignedIntValue);
            AudioObjectAddPropertyListenerBlock(d, &a, dispatch_get_main_queue(), gLevelListener);
        }
    }
    gWatched = d;
    lockedLevelChanged(0, NULL);
}

// The level changed (or the settings did): put it back if it is locked.
static void lockedLevelChanged(UInt32 n, const AudioObjectPropertyAddress *a) {
    if (!gLockLevel || gWatched == kAudioObjectUnknown) return;
    NSNumber *locked = gLockedLevels[gWatchedUID ?: @""];
    Float32 current;
    if (![locked isKindOfClass:[NSNumber class]] || !getLevelOf(gWatched, gWatchedElements, &current)) return;
    if (fabsf(current - locked.floatValue) < 0.005f) return;
    setLevelOf(gWatched, gWatchedElements, locked.floatValue);
    recordFix(KEY_LEVEL_COUNT, KEY_LEVEL_LAST,
              [NSString stringWithFormat:@"%@: level %.2f -> %.2f", deviceName(gWatched), current, locked.floatValue]);
}

static void defaultInputChanged(void) {
    AudioDeviceID d = defaultInput();
    AudioDeviceID chosen = chosenMic();
    if (chosen) {
        if (d != chosen) {
            setDefaultInput(chosen);  // reported back as another default input change
            return;
        }
        watchLevel(d);
        return;
    }
    BOOL headset = isHeadset(d), iPhone = isContinuity(d);
    if (headset || iPhone) {
        AudioDeviceID mic = replacementMic();
        if (mic) {
            setDefaultInput(mic);  // reported back as another default input change
            NSString *what = [NSString stringWithFormat:@"input %@ -> %@ (%@)", deviceName(d), deviceName(mic),
                              headset ? @"headphones stay hi-fi" : @"iPhone kept off the microphone"];
            if (headset) recordFix(KEY_HIFI_COUNT, KEY_HIFI_LAST, what);
            else recordFix(KEY_IPHONE_COUNT, KEY_IPHONE_LAST, what);
            return;
        }
    }
    if (isRealMic(d)) {
        NSString *uid = deviceUID(d);
        if (uid) setPref(KEY_LAST_INPUT, uid);
    }
    watchLevel(d);
}

// Apply what the settings say without counting it: switching the input or setting a level here is the user's choice.
static void applyQuietly(void) {
    gCountFixes = NO;
    defaultInputChanged();
    lockedLevelChanged(0, NULL);
    gCountFixes = YES;
}

static void settingsChanged(CFNotificationCenterRef c, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    loadSettings();
    applyQuietly();
}

#pragma mark - App bundle

static BOOL selfPath(char *path, uint32_t size) {
    return _NSGetExecutablePath(path, &size) == 0;
}

// Remove our login item, as turning off "Enable MicKeeper" does, so nothing is left in Login Items and launchd
// does not start another copy of MicKeeper at the next login.
static void unregisterLoginItem(void) {
    if (!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_NOW)) return;
    // Remove the updater first: unregistering the main job can stop this process immediately.
    for (NSString *plist in @[UPDATER_PLIST, AGENT_PLIST]) {
        NSError *error = nil;
        if (![[NSClassFromString(@"SMAppService") agentServiceWithPlistName:plist] unregisterAndReturnError:&error])
            fprintf(stderr, "mickeeperd: could not remove %s: %s\n", plist.UTF8String, error.localizedDescription.UTF8String);
    }
}

// MicKeeper.app was moved to the Trash or replaced by an update. An update puts a new copy at the same path within
// moments: exit with an error so launchd starts the new agent. Otherwise the app is gone: remove the login item and
// exit for good (a successful exit is not restarted).
static void appMoved(void) {
    dispatch_source_cancel(gBundleWatch);
    for (int i = 0; i < 10; i++) {
        sleep(1);
        struct stat st;
        if (stat(gExecutable, &st) == 0) {
            fprintf(stderr, "mickeeperd: MicKeeper.app was updated, restarting\n");
            exit(1);
        }
    }
    fprintf(stderr, "mickeeperd: MicKeeper.app was removed, exiting\n");
    unregisterLoginItem();  // launchd may stop us right here
    exit(0);
}

// Watch the app bundle through the kernel's event queue: no polling, no wakeups until it moves.
static void watchAppBundle(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!selfPath(path, sizeof(path)) || !realpath(path, resolved)) return;
    strlcpy(gExecutable, resolved, sizeof(gExecutable));
    char *contents = strstr(resolved, "/Contents/MacOS/");
    if (!contents) return;  // not running from an app bundle
    *contents = 0;
    int fd = open(resolved, O_EVTONLY);
    if (fd < 0) return;
    gBundleWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                          DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
                                          dispatch_get_main_queue());
    dispatch_source_set_event_handler(gBundleWatch, ^{ appMoved(); });
    dispatch_source_set_cancel_handler(gBundleWatch, ^{ close(fd); });
    dispatch_resume(gBundleWatch);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--update-check")) {
            BOOL force = NO, install = NO;
            for (int i = 2; i < argc; i++) {
                if (!strcmp(argv[i], "--force")) force = YES;
                else if (!strcmp(argv[i], "--install")) install = YES;
                else return 1;
            }
            return updaterRun(force, install);
        }
        if (argc > 1 && !strcmp(argv[1], "--status")) {  // for scripts and debugging
            AudioDeviceID d = defaultInput();
            Float32 level;
            if (getLevel(d, &level)) printf("input: %s, level: %.2f\n", deviceName(d).UTF8String, level);
            else printf("input: %s, no level control\n", deviceName(d).UTF8String);
            return 0;
        }

        loadSettings();
        watchAppBundle();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, settingsChanged,
                                        SETTINGS_CHANGED_NOTIFICATION, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        gLevelListener = ^(UInt32 n, const AudioObjectPropertyAddress *a) { lockedLevelChanged(n, a); };
        AudioObjectPropertyAddress def = addr(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, dispatch_get_main_queue(),
            ^(UInt32 n, const AudioObjectPropertyAddress *a) { defaultInputChanged(); });
        // A microphone was plugged in or removed: the preferred one may be back, or a replacement may now exist.
        AudioObjectPropertyAddress devices = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devices, dispatch_get_main_queue(),
            ^(UInt32 n, const AudioObjectPropertyAddress *a) { defaultInputChanged(); });

        defaultInputChanged();
        CFRunLoopRun();  // also serves the main queue (CoreAudio listeners) and distributed notifications
    }
    return 0;
}
