#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <stdio.h>
#include <unistd.h>

// Run as the executable of a temporary, uniquely identified accessory app.
// Only Carbon hotkey receipts are reported. No raw keyboard input is read.
static const OSType signature = 'Wtns';

static OSStatus receiveHotkey(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID hotkey;
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                        NULL, sizeof(hotkey), NULL, &hotkey);
    if (status != noErr || hotkey.signature != signature) return eventNotHandledErr;
    printf("pressed %u\n", (unsigned)hotkey.id);
    return noErr;
}

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        alarm(120); // Also releases registrations if the test driver disappears.
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        EventTargetRef target = GetApplicationEventTarget();
        const EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
        OSStatus status = InstallEventHandler(target, receiveHotkey, 1, &type, NULL, NULL);
        if (status != noErr) {
            fprintf(stderr, "InstallEventHandler: %d\n", (int)status);
            return 1;
        }
        const UInt32 keys[] = { kVK_ANSI_1, kVK_ANSI_2 };
        EventHotKeyRef registrations[2];
        for (UInt32 index = 0; index < 2; ++index) {
            EventHotKeyID hotkey = { signature, index + 1 };
            status = RegisterEventHotKey(keys[index], cmdKey, hotkey, target, 0, &registrations[index]);
            if (status != noErr) {
                fprintf(stderr, "RegisterEventHotKey Cmd-%u: %d\n", (unsigned)hotkey.id, (int)status);
                return 1;
            }
        }
        printf("ready %d\n", getpid());
        [app run];
        return 0;
    }
}
