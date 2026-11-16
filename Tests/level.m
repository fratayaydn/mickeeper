// Exercise level selection without accessing audio devices or saved preferences.
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
        puts("Passed level lock checks: saved levels, new microphones and zero and full levels.");
    }
    return 0;
}
