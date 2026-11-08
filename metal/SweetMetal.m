/*
 * SweetMetal: a stand-in Metal driver bundle for the Pixel 3a port (no Apple GPU there).
 *
 * Metal.framework reads MetalPluginName / MetalPluginClassName from an IOAccelerator
 * registry entry (published by the kernel with boot-arg sweetaccel=1), loads
 * /System/Library/Extensions/<name>.bundle and calls -initWithAcceleratorPort: on the class.
 *
 * Milestone 1 (this file): a DISCOVERY stub. It logs everything asked of it to stderr
 * ("SWEETMETAL[process]: ..."; the kernel tee shows /dev/null writes of the processes in
 * boot-arg sweetnull), so the contract Metal.framework and its clients expect can be learned.
 * It declines to create a device in the compositor processes, which keep their software renderer.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

extern const char *getprogname(void);

static void
sm_log(const char *fmt, ...)
{
	char buf[480], line[560];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	int n = snprintf(line, sizeof line, "SWEETMETAL[%s]: %s\n", getprogname(), buf);
	if (n > 0) {
		write(2, line, (size_t)n);
	}
}

static BOOL
sm_process_allowed(void)
{
	static const char *deny[] = { "backboardd", "SpringBoard", "launchd", "xpcproxy", NULL };
	const char *p = getprogname();
	for (int i = 0; deny[i]; i++) {
		if (strcmp(p, deny[i]) == 0) {
			return NO;
		}
	}
	return YES;
}

#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@interface SweetMetalDevice : NSObject <MTLDevice>
- (instancetype)initWithAcceleratorPort:(uint32_t)port;
@end

@implementation SweetMetalDevice

+ (void)load
{
	sm_log("bundle loaded");
}

- (instancetype)initWithAcceleratorPort:(uint32_t)port
{
	sm_log("initWithAcceleratorPort:%u", port);
	if (!sm_process_allowed()) {
		sm_log("declining: compositor process keeps its software renderer");
		return nil;
	}
	self = [super init];
	return self;
}

- (NSString *)name { return @"SweetMetal Software Device"; }
- (uint64_t)registryID { return 0x5357454554ULL; }
- (BOOL)isLowPower { return NO; }
- (BOOL)isHeadless { return YES; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(1024, 1024, 64); }
- (BOOL)supportsTextureSampleCount:(NSUInteger)c { return c == 1 || c == 4; }

- (BOOL)supportsFamily:(MTLGPUFamily)family
{
	sm_log("supportsFamily:%ld -> NO", (long)family);
	return NO;
}

- (BOOL)supportsFeatureSet:(MTLFeatureSet)set
{
	sm_log("supportsFeatureSet:%ld -> NO", (long)set);
	return NO;
}

/* everything else: log the selector and return nil / 0 so the caller's next step shows up too */
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *s = [super methodSignatureForSelector:sel];
	return s ? s : [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	static int logged;
	if (logged++ < 400) {
		sm_log("unimplemented -[MTLDevice %s]", sel_getName(inv.selector));
	}
	void *zero[4] = { 0, 0, 0, 0 };
	if (inv.methodSignature.methodReturnLength <= sizeof(zero)) {
		[inv setReturnValue:zero];
	}
}

+ (BOOL)resolveClassMethod:(SEL)sel
{
	sm_log("class method asked: +%s", sel_getName(sel));
	return [super resolveClassMethod:sel];
}

@end
