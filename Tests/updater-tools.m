// Exercise the subprocess timeout without a release check, saved preferences or an installed application.
#include <assert.h>
#import "../Sources/Agent/Updater.m"

static void notifications(void) {
    NSString *directory = [NSFileManager.defaultManager.currentDirectoryPath
        stringByAppendingPathComponent:[@".build/notifier-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *notifier = [directory stringByAppendingPathComponent:@"MicKeeper"];
    NSString *output = [notifier stringByAppendingString:@".arguments"];
    NSString *script = @"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\n";
    assert([script writeToFile:notifier atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    assert(chmod(notifier.fileSystemRepresentation, 0700) == 0);
    for (NSNumber *force in @[@NO, @YES]) {
        for (NSNumber *install in @[@NO, @YES]) {
            for (NSNumber *automatic in @[@NO, @YES]) {
                for (NSNumber *success in @[@NO, @YES]) {
                    BOOL shouldInstall = install.boolValue || automatic.boolValue;
                    BOOL notify = !force.boolValue && !install.boolValue;
                    __block int installs = 0;
                    int result = updateAndNotify(notifier, @"1.2.3", shouldInstall, force.boolValue, install.boolValue, ^{
                        installs++;
                        return success.boolValue;
                    });
                    BOOL failed = shouldInstall && !success.boolValue;
                    assert(result == (failed ? 1 : 0));
                    assert(installs == (shouldInstall ? 1 : 0));
                    NSString *arguments = [NSString stringWithContentsOfFile:output encoding:NSUTF8StringEncoding error:NULL];
                    if (notify) {
                        NSString *expected = shouldInstall && success.boolValue ? @"--installed" : @"--available";
                        assert(([arguments isEqual:[NSString stringWithFormat:@"--notify-update\n1.2.3\n%@\n", expected]]));
                        assert([NSFileManager.defaultManager removeItemAtPath:output error:NULL]);
                    } else {
                        assert(![NSFileManager.defaultManager fileExistsAtPath:output]);
                    }
                }
            }
        }
    }
    assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
    puts("Passed updater notification checks: silent manual runs, scheduled availability, success and failure.");
}

int main(void) {
    @autoreleasepool {
        notifications();
        assert(runTool(@"/usr/bin/true", @[], 2));
        assert(!runTool(@"/usr/bin/false", @[], 2));
        assert(runTool(@"/bin/test", @[@"two words", @"=", @"two words"], 2));
        NSString *missing = [NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:[@".build/missing-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert(!runTool(missing, @[], 2));
        NSString *pidFile = [missing stringByAppendingString:@".pid"];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        assert(!runTool(@"/bin/sh", @[@"-c", @"printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                                     @"notification-test", pidFile], 1));
        assert(NSProcessInfo.processInfo.systemUptime - start < 5);
        pid_t pid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:NULL] intValue];
        assert(pid > 0);
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        while (kill(pid, 0) == 0 && NSProcessInfo.processInfo.systemUptime < deadline) usleep(10000);
        assert(kill(pid, 0) == -1 && errno == ESRCH);
        assert([NSFileManager.defaultManager removeItemAtPath:pidFile error:NULL]);
        puts("Passed updater subprocess checks: success, failure, arguments, launch error and bounded timeout.");
    }
    return 0;
}
