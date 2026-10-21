#include <stdio.h>

int main(void) {
#if defined(__arm64__) || defined(__aarch64__)
    printf("[kty-ntfs smoke_test] Architecture: Apple Silicon (arm64)\n");
#elif defined(__x86_64__)
    printf("[kty-ntfs smoke_test] Architecture: Intel (x86_64)\n");
#else
    printf("[kty-ntfs smoke_test] Architecture: Unknown\n");
#endif
    printf("[kty-ntfs smoke_test] Build infrastructure operational.\n");
    return 0;
}
