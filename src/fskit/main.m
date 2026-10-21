#import <Foundation/Foundation.h>
#import <FSKit/FSKit.h>
#import "KTYUnaryFileSystem.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        /* Ensure KTYUnaryFileSystem is loaded for ExtensionKit discovery */
        [KTYUnaryFileSystem class];
        dispatch_main();
    }
    return 0;
}
