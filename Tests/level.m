// Exercise agent decisions without accessing audio devices or saved preferences.
#include <assert.h>
#define main agentMain
#import "../Sources/Agent/mickeeperd.m"
#undef main

int main(void) {
    @autoreleasepool {
        assert([levelToLock(@0.25f, 0.75f) isEqual:@0.25f]);
        assert([levelToLock(@0, 0.75f) isEqual:@0]);
        assert([levelToLock(@1, 0.75f) isEqual:@1]);
        assert([levelToLock(nil, 0.75f) isEqual:@0.75f]);
        assert([levelToLock(nil, 0) isEqual:@0]);
        assert([levelToLock(nil, 1) isEqual:@1]);
        assert([levelToLock(@"invalid", 0.5f) isEqual:@0.5f]);
        assert(!levelsNeedRestore(@[@0.5f, @0.5f], 0.5f));
        assert(!levelsNeedRestore(@[@0.5f, @0.504f], 0.5f));
        assert(levelsNeedRestore(@[@0.5f, @0.75f], 0.5f));
        assert(levelsNeedRestore(@[@0.005f], 0));
        assert(!levelsNeedRestore(@[[NSNull null], @0.5f], 0.5f));
        assert(!levelsNeedRestore(@[[NSNull null]], 0.5f));
        assert(levelsNeedRestore(@[[NSNull null], @0.75f], 0.5f));
        puts("Passed level lock checks: saved levels, new microphones, channel changes and unreadable channels.");

        assert(appMoveAction(YES, nil) == AppMoveRestart);
        assert(appMoveAction(YES, @"/Users/test/.Trash/MicKeeper.app") == AppMoveRestart);
        assert(appMoveAction(YES, @"/Applications/Utilities/MicKeeper.app") == AppMoveRestart);
        assert(appMoveAction(NO, @"/Applications/Utilities/MicKeeper.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/Renamed.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Users/test/.Trash/MicKeeper.app") == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Volumes/External/.Trashes/501/MicKeeper.app") == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Users/test/.Trash/Folder/MicKeeper.app") == AppMoveRemoveAndExit);
        assert(appMoveAction(NO, @"/Applications/.Trashcan/MicKeeper.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/.Trashes-backup/MicKeeper.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, @"/Applications/MicKeeper.Trash.app") == AppMoveKeepRunning);
        assert(appMoveAction(NO, nil) == AppMoveRemoveAndExit);
        puts("Passed app move checks: updates, moves, renames, Trash components and unresolved paths.");

        assert(CFEqual(inputFixCountKey(YES, NO), KEY_HIFI_COUNT));
        assert(CFEqual(inputFixCountKey(NO, YES), KEY_IPHONE_COUNT));
        assert(CFEqual(inputFixCountKey(YES, YES), KEY_HIFI_COUNT));
        assert(inputFixCountKey(NO, NO) == NULL);
        puts("Passed input fix checks: headset and iPhone counters, headset priority and other devices.");
    }
    return 0;
}
