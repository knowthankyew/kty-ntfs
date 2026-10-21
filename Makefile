# kty-ntfs Makefile
# Universal build system for macOS 14+ (arm64 & x86_64)

SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)
CC ?= clang
SWIFTC ?= swiftc
LIPO ?= lipo

TARGET_OS_MIN = 14.0
CFLAGS_COMMON = -isysroot $(SDKROOT) -Wall -Wextra -O2 -fstack-protector-strong
CFLAGS_ARM64 = $(CFLAGS_COMMON) -target arm64-apple-macos$(TARGET_OS_MIN)
CFLAGS_X86_64 = $(CFLAGS_COMMON) -target x86_64-apple-macos$(TARGET_OS_MIN)

BUILD_DIR = build
BIN_DIR = $(BUILD_DIR)/bin
OBJ_DIR = $(BUILD_DIR)/obj

.PHONY: all clean dirs smoke_test test

all: dirs smoke_test

dirs:
	@mkdir -p $(BIN_DIR) $(OBJ_DIR)/arm64 $(OBJ_DIR)/x86_64

# Universal smoke test target
smoke_test: dirs $(BIN_DIR)/smoke_test
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/smoke_test
	@echo "==> Executing smoke test:"
	./$(BIN_DIR)/smoke_test

$(BIN_DIR)/smoke_test: $(OBJ_DIR)/arm64/smoke_test.o $(OBJ_DIR)/x86_64/smoke_test.o
	@echo "==> Linking universal binary: $@"
	$(CC) $(CFLAGS_ARM64) $(OBJ_DIR)/arm64/smoke_test.o -o $(BIN_DIR)/smoke_test_arm64
	$(CC) $(CFLAGS_X86_64) $(OBJ_DIR)/x86_64/smoke_test.o -o $(BIN_DIR)/smoke_test_x86_64
	$(LIPO) -create -output $@ $(BIN_DIR)/smoke_test_arm64 $(BIN_DIR)/smoke_test_x86_64
	@./scripts/codesign-adhoc.sh $@

$(OBJ_DIR)/arm64/smoke_test.o: tests/smoke_test.c
	@echo "==> Compiling arm64: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/smoke_test.o: tests/smoke_test.c
	@echo "==> Compiling x86_64: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

test: smoke_test

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
