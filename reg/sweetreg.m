/*
 * sweetreg: register the system app extensions (wallpaper providers, widgets, ...) with
 * LaunchServices. On this restore the LS database holds the apps but none of their PlugIns, so
 * PosterBoard finds no wallpaper provider and chronod no widget. Runs once per boot from a
 * LaunchDaemon, as root and then as mobile, and logs to /private/var/tmp/sweetreg.log.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

static void
lg(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	NSString *line = [NSString stringWithFormat:@"uid=%d %@\n", getuid(), s];
	int fd = open("/private/var/tmp/sweetreg.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
	if (fd >= 0) {
		write(fd, line.UTF8String, strlen(line.UTF8String));
		close(fd);
	}
}

static long
count_ext(NSString *point)
{
	Class c = NSClassFromString(@"NSExtension");
	SEL sel = NSSelectorFromString(@"extensionsWithMatchingAttributes:error:");
	if (!c || ![c respondsToSelector:sel]) {
		return -1;
	}
	@try {
		NSError *e = nil;
		NSArray *a = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(c, sel, @{ @"NSExtensionPointIdentifier": point }, &e);
		return (long)a.count;
	} @catch (NSException *x) {
		lg(@"count_ext exception %@", x);
		return -2;
	}
}

static void
counts(NSString *tag)
{
	lg(@"%@: posterkit.provider=%ld widgetkit-extension=%ld share=%ld", tag,
	    count_ext(@"com.apple.posterkit.provider"), count_ext(@"com.apple.widgetkit-extension"),
	    count_ext(@"com.apple.share-services"));
}

static NSArray *
find_appex(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray *out = [NSMutableArray array];
	NSArray *roots = @[ @"/Applications", @"/System/Library/AppPlaceholders",
		            @"/System/Library/PrivateFrameworks", @"/System/Library/Frameworks" ];
	for (NSString *r in roots) {
		for (NSString *host in [fm contentsOfDirectoryAtPath:r error:nil]) {
			NSString *pi = [[r stringByAppendingPathComponent:host] stringByAppendingPathComponent:@"PlugIns"];
			for (NSString *x in [fm contentsOfDirectoryAtPath:pi error:nil]) {
				if ([x hasSuffix:@".appex"]) {
					[out addObject:[pi stringByAppendingPathComponent:x]];
				}
			}
		}
	}
	return out;
}

static void
pass(void)
{
	Class wc = NSClassFromString(@"LSApplicationWorkspace");
	id ws = wc ? ((id (*)(id, SEL))objc_msgSend)(wc, NSSelectorFromString(@"defaultWorkspace")) : nil;
	if (!ws) {
		lg(@"no LSApplicationWorkspace");
		return;
	}
	SEL reg = NSSelectorFromString(@"registerPlugin:");
	Method m = class_getInstanceMethod(wc, reg);
	lg(@"registerPlugin: %s", m ? method_getTypeEncoding(m) : "MISSING");
	counts(@"before");
	NSArray *all = find_appex();
	lg(@"found %lu appex", (unsigned long)all.count);
	int ok = 0, bad = 0;
	for (NSString *p in all) {
		@try {
			BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, reg, [NSURL fileURLWithPath:p]);
			r ? ok++ : bad++;
			if (!r && bad <= 10) {
				lg(@"registerPlugin failed: %@", p);
			}
		} @catch (NSException *x) {
			bad++;
			lg(@"registerPlugin exception %@ for %@", x, p);
		}
	}
	lg(@"registerPlugin: %d ok, %d failed", ok, bad);
	counts(@"after");
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		const char *d = getenv("SWEETREG_DELAY");
		sleep(d ? (unsigned)atoi(d) : 45);
		lg(@"sweetreg start");
		pass();
		if (getuid() == 0 && setgid(501) == 0 && setuid(501) == 0) {
			pass();
		}
		lg(@"sweetreg done");
	}
	return 0;
}
