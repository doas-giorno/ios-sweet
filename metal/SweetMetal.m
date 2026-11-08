/*
 * SweetMetal: a stand-in Metal driver bundle for the Pixel 3a port (no Apple GPU there).
 *
 * Metal.framework reads MetalPluginName / MetalPluginClassName from an IOAccelerator
 * registry entry (published by the kernel with boot-arg sweetaccel=1), loads
 * /System/Library/Extensions/<name>.bundle and calls -initWithAcceleratorPort: on the class.
 *
 * Milestone 2 (this file): PosterBoard survives. Its wallpaper-preview code
 * (-[PBFHomeScreenPreviewImageBuilder _imageForView:]) needs a Metal device + command queue and
 * renders with CARenderer into a Metal texture; with no device it put nil into an NSDictionary
 * and aborted, which poisoned its on-disk state so it also crash-looped afterwards.
 * Fix: only PosterBoard gets a (fake) device, whose queue/texture are inert objects; the
 * preview is drawn on the CPU instead (CALayer renderInContext:), and CARenderer's Metal
 * constructor returns nil so nothing touches the fake GPU. All other processes get no device,
 * as before. Everything asked of the stub is logged to stderr and to /private/var/tmp/sweetmetal.log.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <fcntl.h>
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
		int fd = open("/private/var/tmp/sweetmetal.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
		if (fd >= 0) {
			write(fd, line, (size_t)n);
			close(fd);
		}
	}
}

/* shortcut: PosterBoard only; widen when another process needs a device and copes with this stub */
static BOOL
sm_process_allowed(void)
{
	return strcmp(getprogname(), "PosterBoard") == 0;
}

/* inert stand-in for command queues / textures: every message is logged and answered with 0/nil */
@interface SweetMetalObject : NSObject
@end

@implementation SweetMetalObject
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
	NSMethodSignature *s = [super methodSignatureForSelector:sel];
	return s ? s : [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv
{
	static int logged;
	if (logged++ < 100) {
		sm_log("unimplemented -[SweetMetalObject %s]", sel_getName(inv.selector));
	}
	void *zero[4] = { 0, 0, 0, 0 };
	if (inv.methodSignature.methodReturnLength <= sizeof(zero)) {
		[inv setReturnValue:zero];
	}
}
@end

/* PosterBoard's home-screen preview: draw the view's layer tree on the CPU into a pixel-sized image */
static void
sm_install_postboard_fixes(void)
{
	Class pbf = objc_getClass("PBFHomeScreenPreviewImageBuilder");
	if (pbf) {
		IMP imp = imp_implementationWithBlock(^id(id self_, id view) {
			CALayer *layer = ((UIView *)view).layer;
			CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1;
			CGSize px = CGSizeMake(layer.bounds.size.width * scale, layer.bounds.size.height * scale);
			if (px.width < 1 || px.height < 1) {
				sm_log("_imageForView: empty layer, nil");
				return nil;
			}
			UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
			f.scale = 1;
			f.opaque = NO;
			UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:px format:f];
			UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
				CGContextScaleCTM(c.CGContext, scale, scale);
				[layer renderInContext:c.CGContext];
			}];
			sm_log("_imageForView: cpu render %gx%g -> %p", px.width, px.height, img);
			return img;
		});
		class_replaceMethod(pbf, sel_registerName("_imageForView:"), imp, "@@:@");
		sm_log("swizzled -[PBFHomeScreenPreviewImageBuilder _imageForView:]");
	} else {
		sm_log("PBFHomeScreenPreviewImageBuilder not found");
	}
	Class car = objc_getClass("CARenderer");
	if (car) {
		IMP imp = imp_implementationWithBlock(^id(id cls, id tex, id opts) {
			sm_log("+[CARenderer rendererWithMTLTexture:options:] -> nil");
			return nil;
		});
		class_replaceMethod(object_getClass(car), sel_registerName("rendererWithMTLTexture:options:"), imp, "@@:@@");
	}
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
	if (sm_process_allowed()) {
		sm_install_postboard_fixes();
	}
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

- (id)newCommandQueue
{
	sm_log("newCommandQueue -> inert queue");
	return [SweetMetalObject new];
}

- (id)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n
{
	return [SweetMetalObject new];
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	return [SweetMetalObject new];
}

- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)s plane:(NSUInteger)plane
{
	sm_log("newTextureWithDescriptor:iosurface: -> inert texture");
	return [SweetMetalObject new];
}

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
