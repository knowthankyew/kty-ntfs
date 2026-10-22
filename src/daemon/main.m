#import <Foundation/Foundation.h>
#import <signal.h>
#import "KTYDaemon.h"

static KTYDaemon *g_daemon = nil;

static void KTYSignalHandler(int sig) {
    (void)sig;
    if (g_daemon) {
        [g_daemon stop];
    }
    CFRunLoopStop(CFRunLoopGetMain());
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        signal(SIGINT, KTYSignalHandler);
        signal(SIGTERM, KTYSignalHandler);
        signal(SIGHUP, KTYSignalHandler);

        NSString *serviceName = KTY_NTFSD_MACH_SERVICE;
        BOOL autoMount = YES;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--no-auto-mount"]) {
                autoMount = NO;
            } else if ([arg isEqualToString:@"--service-name"] && i + 1 < argc) {
                serviceName = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printf("kty-ntfsd - Autonomous NTFS Daemon (knowthankyew)\n\n");
                printf("Usage:\n");
                printf("  kty-ntfsd [options]\n\n");
                printf("Options:\n");
                printf("  --no-auto-mount        Disable automated DiskArbitration claiming\n");
                printf("  --service-name <name>  Custom Mach service name for local XPC\n");
                printf("  --help, -h             Show this help information\n");
                return 0;
            }
        }

        printf("[kty-ntfsd] Starting autonomous NTFS daemon (PID: %d)...\n", getpid());
        printf("[kty-ntfsd] Mach service: %s\n", [serviceName UTF8String]);
        printf("[kty-ntfsd] Forensic hygiene default: ON (host metadata suppressed)\n");

        g_daemon = [[KTYDaemon alloc] initWithMachServiceName:serviceName];
        g_daemon.autoMountEnabled = autoMount;

        NSError *error = nil;
        if (![g_daemon startWithEndpoint:nil error:&error]) {
            fprintf(stderr, "[kty-ntfsd] Fatal error starting daemon: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        printf("[kty-ntfsd] Daemon operational. Entering run loop.\n");
        CFRunLoopRun();

        printf("[kty-ntfsd] Shutdown complete. Goodbye.\n");
    }
    return 0;
}
