// Simulator-only screenshot utility. Never linked into Tracy.
// Event format documented by Appium's XCUIDevice+FBHinge implementation:
// https://github.com/appium/appium-ios/blob/main/packages/webdriveragent/WebDriverAgentLib/Categories/XCUIDevice+FBHinge.m
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>

int main(int argc, const char *argv[]) {
#if !TARGET_OS_SIMULATOR
    return 2;
#else
    @autoreleasepool {
        if (argc != 2) return 2;
        char *end = NULL;
        double angle = strtod(argv[1], &end);
        if (!end || *end || !isfinite(angle) || angle < 0 || angle > 180) return 2;
        void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!library) return 3;
        CFDataRef (*serialize)(CFTypeRef, CFOptionFlags) = dlsym(library, "IOCFSerialize");
        CFTypeRef (*createEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint8_t *, CFIndex, uint32_t) = dlsym(library, "IOHIDEventCreateVendorDefinedEvent");
        CFTypeRef (*createClient)(CFAllocatorRef) = dlsym(library, "IOHIDEventSystemClientCreate");
        void (*dispatch)(CFTypeRef, CFTypeRef) = dlsym(library, "IOHIDEventSystemClientDispatchEvent");
        if (!serialize || !createEvent || !createClient || !dispatch) return 3;
        NSDictionary *payload = @{ @"provider": @"com.apple.Virtualization.VirtualMachines",
                                  @"source": @"hinge-slider-control", @"type": @"range", @"value": @(angle) };
        CFDataRef data = serialize((__bridge CFTypeRef)payload, 1);
        if (!data) return 4;
        CFTypeRef event = createEvent(kCFAllocatorDefault, mach_absolute_time(), 0xff61, 0x5b, 0,
                                     (uint8_t *)CFDataGetBytePtr(data), CFDataGetLength(data), 0);
        CFTypeRef client = createClient(kCFAllocatorDefault);
        if (event && client) dispatch(client, event);
        BOOL sent = event && client;
        if (client) CFRelease(client);
        if (event) CFRelease(event);
        CFRelease(data);
        return sent ? 0 : 4;
    }
#endif
}
