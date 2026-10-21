# kty-ntfs Makefile
# Universal build system for macOS 14+ (arm64 & x86_64)

SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)
CC ?= clang
SWIFTC ?= swiftc
LIPO ?= lipo

TARGET_OS_MIN = 14.0
CFLAGS ?=
EXTRA_CFLAGS ?=
CFLAGS_COMMON = -isysroot $(SDKROOT) -Wall -Wextra -O2 -fstack-protector-strong $(EXTRA_CFLAGS) $(CFLAGS)
CFLAGS_ARM64 = $(CFLAGS_COMMON) -target arm64-apple-macos$(TARGET_OS_MIN)
CFLAGS_X86_64 = $(CFLAGS_COMMON) -target x86_64-apple-macos$(TARGET_OS_MIN)

BUILD_DIR = build
BIN_DIR = $(BUILD_DIR)/bin
OBJ_DIR = $(BUILD_DIR)/obj

.PHONY: all clean smoke_test test verify-invariants asan

all: smoke_test

$(BIN_DIR) $(OBJ_DIR)/arm64 $(OBJ_DIR)/x86_64:
	@mkdir -p $@

$(OBJ_DIR)/arm64/smoke_test.o: tests/smoke_test.c | $(OBJ_DIR)/arm64
	@echo "==> Compiling arm64: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/smoke_test.o: tests/smoke_test.c | $(OBJ_DIR)/x86_64
	@echo "==> Compiling x86_64: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/smoke_test_arm64: $(OBJ_DIR)/arm64/smoke_test.o | $(BIN_DIR)
	@echo "==> Linking arm64 slice: $@"
	$(CC) $(CFLAGS_ARM64) $< -o $@

$(BIN_DIR)/smoke_test_x86_64: $(OBJ_DIR)/x86_64/smoke_test.o | $(BIN_DIR)
	@echo "==> Linking x86_64 slice: $@"
	$(CC) $(CFLAGS_X86_64) $< -o $@

$(BIN_DIR)/smoke_test: $(BIN_DIR)/smoke_test_arm64 $(BIN_DIR)/smoke_test_x86_64 | $(BIN_DIR)
	@echo "==> Linking universal binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

verify-invariants: $(BIN_DIR)/smoke_test
	@echo "==> Auditing Mach-O binary for zero network symbols (KTY Invariant 1)..."
	@if nm -u $(BIN_DIR)/smoke_test | grep -E -q "socket|connect|getaddrinfo|CFNetwork|URLSession"; then \
		echo "ERROR: Forbidden network symbols detected in $(BIN_DIR)/smoke_test" >&2; \
		exit 1; \
	fi
	@echo "==> Invariant verified: 0 network symbols found."

smoke_test: $(BIN_DIR)/smoke_test verify-invariants
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/smoke_test
	@echo "==> Executing smoke test:"
	./$(BIN_DIR)/smoke_test

asan:
	$(MAKE) clean
	$(MAKE) EXTRA_CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" smoke_test

test: smoke_test

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
