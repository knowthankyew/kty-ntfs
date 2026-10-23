# kty-ntfs Makefile
# Universal build system for macOS 14+ (arm64 & x86_64)

SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)
CC ?= clang
SWIFTC ?= swiftc
LIPO ?= lipo
APPLE_LIBTOOL ?= libtool

TARGET_OS_MIN = 14.0
CFLAGS ?=
EXTRA_CFLAGS ?=
INCLUDES = -Isrc/core/include -Isrc/core/include/ntfs-3g
CFLAGS_COMMON = -isysroot $(SDKROOT) -Wall -Wextra -O2 -fstack-protector-strong -DHAVE_CONFIG_H $(INCLUDES) $(EXTRA_CFLAGS) $(CFLAGS)
CFLAGS_ARM64 = $(CFLAGS_COMMON) -target arm64-apple-macos$(TARGET_OS_MIN)
CFLAGS_X86_64 = $(CFLAGS_COMMON) -target x86_64-apple-macos$(TARGET_OS_MIN)

OBJCFLAGS_COMMON = $(CFLAGS_COMMON) -fobjc-arc -Wno-unguarded-availability-new -Isrc/fskit -Isrc/daemon
OBJCFLAGS_ARM64 = $(OBJCFLAGS_COMMON) -target arm64-apple-macos$(TARGET_OS_MIN)
OBJCFLAGS_X86_64 = $(OBJCFLAGS_COMMON) -target x86_64-apple-macos$(TARGET_OS_MIN)

FSKIT_FRAMEWORKS = -framework Foundation -framework FSKit
DA_FRAMEWORKS = -framework Foundation -framework DiskArbitration
DAEMON_FRAMEWORKS = $(FSKIT_FRAMEWORKS) -framework DiskArbitration

BUILD_DIR = build
BIN_DIR = $(BUILD_DIR)/bin
LIB_DIR = $(BUILD_DIR)/lib
OBJ_DIR = $(BUILD_DIR)/obj

CORE_VENDOR_SRCS = $(wildcard src/core/vendor/libntfs-3g/*.c)
CORE_SRCS = $(CORE_VENDOR_SRCS) src/core/kty_io.c src/core/kty_crypto.c

CORE_OBJS_ARM64 = $(patsubst src/core/vendor/libntfs-3g/%.c,$(OBJ_DIR)/arm64/vendor/%.o,$(CORE_VENDOR_SRCS)) $(OBJ_DIR)/arm64/kty_io.o $(OBJ_DIR)/arm64/kty_crypto.o
CORE_OBJS_X86_64 = $(patsubst src/core/vendor/libntfs-3g/%.c,$(OBJ_DIR)/x86_64/vendor/%.o,$(CORE_VENDOR_SRCS)) $(OBJ_DIR)/x86_64/kty_io.o $(OBJ_DIR)/x86_64/kty_crypto.o

FSKIT_SRCS = src/fskit/KTYItem.m src/fskit/KTYVolume.m src/fskit/KTYUnaryFileSystem.m
FSKIT_OBJS_ARM64 = $(patsubst src/fskit/%.m,$(OBJ_DIR)/arm64/fskit/%.o,$(FSKIT_SRCS))
FSKIT_OBJS_X86_64 = $(patsubst src/fskit/%.m,$(OBJ_DIR)/x86_64/fskit/%.o,$(FSKIT_SRCS))

DAEMON_SRCS = src/daemon/KTYDaemon.m
DAEMON_OBJS_ARM64 = $(OBJ_DIR)/arm64/daemon/KTYDaemon.o
DAEMON_OBJS_X86_64 = $(OBJ_DIR)/x86_64/daemon/KTYDaemon.o

CLI_SRCS = src/cli/main.m
CLI_OBJS_ARM64 = $(OBJ_DIR)/arm64/cli/main.o
CLI_OBJS_X86_64 = $(OBJ_DIR)/x86_64/cli/main.o

.PHONY: all clean core smoke_test test_ntfs_core fskit test_fskit_bridge daemon cli test_daemon_cli test_torture torture generate-bundle test verify-invariants audit-claims asan install uninstall

all: core smoke_test test_ntfs_core fskit test_fskit_bridge daemon cli test_daemon_cli test_torture

$(BIN_DIR) $(LIB_DIR) $(LIB_DIR)/arm64 $(LIB_DIR)/x86_64 $(OBJ_DIR)/arm64/vendor $(OBJ_DIR)/x86_64/vendor $(OBJ_DIR)/arm64/fskit $(OBJ_DIR)/x86_64/fskit $(OBJ_DIR)/arm64/daemon $(OBJ_DIR)/x86_64/daemon $(OBJ_DIR)/arm64/cli $(OBJ_DIR)/x86_64/cli:
	@mkdir -p $@

# --- Core Static Library Compilation ---

$(OBJ_DIR)/arm64/vendor/%.o: src/core/vendor/libntfs-3g/%.c | $(OBJ_DIR)/arm64/vendor
	@echo "==> Compiling arm64 (vendor): $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/vendor/%.o: src/core/vendor/libntfs-3g/%.c | $(OBJ_DIR)/x86_64/vendor
	@echo "==> Compiling x86_64 (vendor): $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(OBJ_DIR)/arm64/kty_io.o: src/core/kty_io.c | $(OBJ_DIR)/arm64/vendor
	@echo "==> Compiling arm64: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/arm64/kty_crypto.o: src/core/kty_crypto.c | $(OBJ_DIR)/arm64/vendor
	@echo "==> Compiling arm64: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/kty_io.o: src/core/kty_io.c | $(OBJ_DIR)/x86_64/vendor
	@echo "==> Compiling x86_64: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(OBJ_DIR)/x86_64/kty_crypto.o: src/core/kty_crypto.c | $(OBJ_DIR)/x86_64/vendor
	@echo "==> Compiling x86_64: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(LIB_DIR)/arm64/libkty_ntfs_core.a: $(CORE_OBJS_ARM64) | $(LIB_DIR)/arm64
	@echo "==> Creating arm64 static library: $@"
	$(APPLE_LIBTOOL) -static -o $@ $^

$(LIB_DIR)/x86_64/libkty_ntfs_core.a: $(CORE_OBJS_X86_64) | $(LIB_DIR)/x86_64
	@echo "==> Creating x86_64 static library: $@"
	$(APPLE_LIBTOOL) -static -o $@ $^

$(LIB_DIR)/libkty_ntfs_core.a: $(LIB_DIR)/arm64/libkty_ntfs_core.a $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(LIB_DIR)
	@echo "==> Creating universal fat archive: $@"
	$(LIPO) -create -output $@ $^

core: $(LIB_DIR)/libkty_ntfs_core.a
	@echo "==> Universal libkty_ntfs_core.a built successfully."
	$(LIPO) -info $(LIB_DIR)/libkty_ntfs_core.a

# --- Phase 0 Smoke Test ---

$(OBJ_DIR)/arm64/smoke_test.o: tests/smoke_test.c | $(OBJ_DIR)/arm64/vendor
	@echo "==> Compiling arm64: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/smoke_test.o: tests/smoke_test.c | $(OBJ_DIR)/x86_64/vendor
	@echo "==> Compiling x86_64: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/smoke_test_arm64: $(OBJ_DIR)/arm64/smoke_test.o | $(BIN_DIR)
	$(CC) $(CFLAGS_ARM64) $< -o $@

$(BIN_DIR)/smoke_test_x86_64: $(OBJ_DIR)/x86_64/smoke_test.o | $(BIN_DIR)
	$(CC) $(CFLAGS_X86_64) $< -o $@

$(BIN_DIR)/smoke_test: $(BIN_DIR)/smoke_test_arm64 $(BIN_DIR)/smoke_test_x86_64 | $(BIN_DIR)
	@echo "==> Linking universal binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

smoke_test: $(BIN_DIR)/smoke_test
	@echo "==> Executing smoke test:"
	./$(BIN_DIR)/smoke_test

# --- Phase 1 NTFS Core Test Harness ---

$(OBJ_DIR)/arm64/test_ntfs_core.o: tests/test_ntfs_core.c | $(OBJ_DIR)/arm64/vendor
	@echo "==> Compiling arm64 test: $<"
	$(CC) $(CFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/test_ntfs_core.o: tests/test_ntfs_core.c | $(OBJ_DIR)/x86_64/vendor
	@echo "==> Compiling x86_64 test: $<"
	$(CC) $(CFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/test_ntfs_core_arm64: $(OBJ_DIR)/arm64/test_ntfs_core.o $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 test binary: $@"
	$(CC) $(CFLAGS_ARM64) $^ -o $@

$(BIN_DIR)/test_ntfs_core_x86_64: $(OBJ_DIR)/x86_64/test_ntfs_core.o $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 test binary: $@"
	$(CC) $(CFLAGS_X86_64) $^ -o $@

$(BIN_DIR)/test_ntfs_core: $(BIN_DIR)/test_ntfs_core_arm64 $(BIN_DIR)/test_ntfs_core_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal test binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

test_ntfs_core: $(BIN_DIR)/test_ntfs_core
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/test_ntfs_core
	@echo "==> Executing NTFS Core test suite:"
	./$(BIN_DIR)/test_ntfs_core

# --- Phase 2 FSKit App Extension & Bridge Tests ---

$(OBJ_DIR)/arm64/fskit/%.o: src/fskit/%.m | $(OBJ_DIR)/arm64/fskit
	@echo "==> Compiling arm64 (fskit): $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/fskit/%.o: src/fskit/%.m | $(OBJ_DIR)/x86_64/fskit
	@echo "==> Compiling x86_64 (fskit): $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/kty-ntfs-fs_arm64: $(OBJ_DIR)/arm64/fskit/main.o $(FSKIT_OBJS_ARM64) $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 FSKit executable: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfs-fs_x86_64: $(OBJ_DIR)/x86_64/fskit/main.o $(FSKIT_OBJS_X86_64) $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 FSKit executable: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfs-fs: $(BIN_DIR)/kty-ntfs-fs_arm64 $(BIN_DIR)/kty-ntfs-fs_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal FSKit executable: $@"
	$(LIPO) -create -output $@ $^

$(BIN_DIR)/kty-ntfs-fs.appex: $(BIN_DIR)/kty-ntfs-fs src/fskit/Info.plist src/fskit/entitlements.plist | $(BIN_DIR)
	@echo "==> Packaging FSKit App Extension bundle: $@"
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS
	@cp src/fskit/Info.plist $@/Contents/Info.plist
	@cp $(BIN_DIR)/kty-ntfs-fs $@/Contents/MacOS/kty-ntfs-fs
	@./scripts/codesign-adhoc.sh $@ src/fskit/entitlements.plist

fskit: $(BIN_DIR)/kty-ntfs-fs.appex
	@echo "==> Universal FSKit App Extension built and signed successfully."

$(OBJ_DIR)/arm64/test_fskit_bridge.o: tests/test_fskit_bridge.m | $(OBJ_DIR)/arm64/fskit
	@echo "==> Compiling arm64 fskit test: $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/test_fskit_bridge.o: tests/test_fskit_bridge.m | $(OBJ_DIR)/x86_64/fskit
	@echo "==> Compiling x86_64 fskit test: $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/test_fskit_bridge_arm64: $(OBJ_DIR)/arm64/test_fskit_bridge.o $(FSKIT_OBJS_ARM64) $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 fskit test binary: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/test_fskit_bridge_x86_64: $(OBJ_DIR)/x86_64/test_fskit_bridge.o $(FSKIT_OBJS_X86_64) $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 fskit test binary: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/test_fskit_bridge: $(BIN_DIR)/test_fskit_bridge_arm64 $(BIN_DIR)/test_fskit_bridge_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal fskit test binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

test_fskit_bridge: $(BIN_DIR)/test_fskit_bridge
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/test_fskit_bridge
	@echo "==> Executing FSKit Bridge test suite:"
	./$(BIN_DIR)/test_fskit_bridge

# --- Phase 5 Autonomous Daemon (kty-ntfsd) ---

$(OBJ_DIR)/arm64/daemon/%.o: src/daemon/%.m | $(OBJ_DIR)/arm64/daemon
	@echo "==> Compiling arm64 (daemon): $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/daemon/%.o: src/daemon/%.m | $(OBJ_DIR)/x86_64/daemon
	@echo "==> Compiling x86_64 (daemon): $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/kty-ntfsd_arm64: $(OBJ_DIR)/arm64/daemon/main.o $(DAEMON_OBJS_ARM64) $(FSKIT_OBJS_ARM64) $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 daemon binary: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(DAEMON_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfsd_x86_64: $(OBJ_DIR)/x86_64/daemon/main.o $(DAEMON_OBJS_X86_64) $(FSKIT_OBJS_X86_64) $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 daemon binary: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(DAEMON_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfsd: $(BIN_DIR)/kty-ntfsd_arm64 $(BIN_DIR)/kty-ntfsd_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal daemon binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

daemon: $(BIN_DIR)/kty-ntfsd
	@echo "==> Universal kty-ntfsd built successfully."

# --- Phase 5 Companion CLI (kty-ntfs) ---

$(OBJ_DIR)/arm64/cli/%.o: src/cli/%.m | $(OBJ_DIR)/arm64/cli
	@echo "==> Compiling arm64 (cli): $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/cli/%.o: src/cli/%.m | $(OBJ_DIR)/x86_64/cli
	@echo "==> Compiling x86_64 (cli): $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/kty-ntfs_arm64: $(CLI_OBJS_ARM64) | $(BIN_DIR)
	@echo "==> Linking arm64 CLI binary: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(DA_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfs_x86_64: $(CLI_OBJS_X86_64) | $(BIN_DIR)
	@echo "==> Linking x86_64 CLI binary: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(DA_FRAMEWORKS) -o $@

$(BIN_DIR)/kty-ntfs: $(BIN_DIR)/kty-ntfs_arm64 $(BIN_DIR)/kty-ntfs_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal CLI binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

cli: $(BIN_DIR)/kty-ntfs
	@echo "==> Universal kty-ntfs CLI built successfully."

# --- Phase 5 Daemon & CLI Test Harness ---

$(OBJ_DIR)/arm64/test_daemon_cli.o: tests/test_daemon_cli.m | $(OBJ_DIR)/arm64/daemon
	@echo "==> Compiling arm64 daemon/cli test: $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/test_daemon_cli.o: tests/test_daemon_cli.m | $(OBJ_DIR)/x86_64/daemon
	@echo "==> Compiling x86_64 daemon/cli test: $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/test_daemon_cli_arm64: $(OBJ_DIR)/arm64/test_daemon_cli.o $(DAEMON_OBJS_ARM64) $(FSKIT_OBJS_ARM64) $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 daemon/cli test binary: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(DAEMON_FRAMEWORKS) -o $@

$(BIN_DIR)/test_daemon_cli_x86_64: $(OBJ_DIR)/x86_64/test_daemon_cli.o $(DAEMON_OBJS_X86_64) $(FSKIT_OBJS_X86_64) $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 daemon/cli test binary: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(DAEMON_FRAMEWORKS) -o $@

$(BIN_DIR)/test_daemon_cli: $(BIN_DIR)/test_daemon_cli_arm64 $(BIN_DIR)/test_daemon_cli_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal daemon/cli test binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

test_daemon_cli: $(BIN_DIR)/test_daemon_cli $(BIN_DIR)/kty-ntfs
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/test_daemon_cli
	@echo "==> Executing Daemon & CLI test suite:"
	./$(BIN_DIR)/test_daemon_cli $(BIN_DIR)/kty-ntfs

# --- Phase 6 Forensic Torture Testing & Validation ---

$(OBJ_DIR)/arm64/test_torture.o: tests/test_torture.m | $(OBJ_DIR)/arm64/fskit
	@echo "==> Compiling arm64 torture test: $<"
	$(CC) $(OBJCFLAGS_ARM64) -c $< -o $@

$(OBJ_DIR)/x86_64/test_torture.o: tests/test_torture.m | $(OBJ_DIR)/x86_64/fskit
	@echo "==> Compiling x86_64 torture test: $<"
	$(CC) $(OBJCFLAGS_X86_64) -c $< -o $@

$(BIN_DIR)/test_torture_arm64: $(OBJ_DIR)/arm64/test_torture.o $(FSKIT_OBJS_ARM64) $(LIB_DIR)/arm64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking arm64 torture test binary: $@"
	$(CC) $(OBJCFLAGS_ARM64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/test_torture_x86_64: $(OBJ_DIR)/x86_64/test_torture.o $(FSKIT_OBJS_X86_64) $(LIB_DIR)/x86_64/libkty_ntfs_core.a | $(BIN_DIR)
	@echo "==> Linking x86_64 torture test binary: $@"
	$(CC) $(OBJCFLAGS_X86_64) $^ $(FSKIT_FRAMEWORKS) -o $@

$(BIN_DIR)/test_torture: $(BIN_DIR)/test_torture_arm64 $(BIN_DIR)/test_torture_x86_64 | $(BIN_DIR)
	@echo "==> Creating universal torture test binary: $@"
	$(LIPO) -create -output $@ $^
	@./scripts/codesign-adhoc.sh $@

test_torture: $(BIN_DIR)/test_torture
	@echo "==> Verifying binary architectures:"
	$(LIPO) -info $(BIN_DIR)/test_torture
	@echo "==> Executing Forensic Torture test suite:"
	./$(BIN_DIR)/test_torture

torture: test_torture

generate-bundle: $(BIN_DIR)/test_torture
	@echo "==> Generating standalone Windows 11 cross-platform forensic test bundle..."
	./$(BIN_DIR)/test_torture --generate-bundle build/kty_test_evidence.img

# --- Audits & Quality Gates ---

audit-claims:
	@echo "==> Auditing portfolio claims, licensing parity, and zero-egress invariants..."
	@./scripts/audit-claims.py

verify-invariants: $(BIN_DIR)/smoke_test $(BIN_DIR)/test_ntfs_core $(BIN_DIR)/kty-ntfs-fs $(BIN_DIR)/test_fskit_bridge $(BIN_DIR)/kty-ntfsd $(BIN_DIR)/kty-ntfs $(BIN_DIR)/test_daemon_cli $(BIN_DIR)/test_torture
	@echo "==> Auditing Mach-O binaries for zero network symbols (KTY Invariant 1)..."
	@for bin in $^; do \
		echo "    Checking $$bin..."; \
		if nm -u $$bin | grep -E -q "socket|connect|getaddrinfo|CFNetwork|URLSession"; then \
			echo "ERROR: Forbidden network symbols detected in $$bin" >&2; \
			exit 1; \
		fi; \
	done
	@echo "==> Invariant verified: 0 network symbols found across all binaries."

test: core smoke_test test_ntfs_core fskit test_fskit_bridge daemon cli test_daemon_cli test_torture verify-invariants audit-claims

asan:
	$(MAKE) clean
	$(MAKE) EXTRA_CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer" test

# --- Installation & Deployment ---

PREFIX ?= /usr/local

install: all
	@PREFIX=$(PREFIX) ./scripts/install.sh

uninstall:
	@PREFIX=$(PREFIX) ./scripts/uninstall.sh

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf $(BUILD_DIR)
