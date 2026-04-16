.PHONY: check fmt lint test test-rust test-swift test-ui build-swift build-release build-dmg build-libghostty build-libghostty-universal print-libghostty-path print-libghostty-resources-path deny

# Run all checks (formatting, linting, tests, license audit)
check: fmt lint deny test

# Format all code
fmt:
	cargo fmt
	swift-format format --in-place --recursive apps/macos/Sources/ apps/macos/Tests/ apps/macos/UITests/

# Lint all code
lint:
	cargo fmt --check
	cargo clippy --workspace -- -D warnings
	swift-format lint --recursive apps/macos/Sources/ apps/macos/Tests/ apps/macos/UITests/

# Run all tests
test: test-rust test-swift

# Rust tests
test-rust:
	cargo test --workspace

# Swift tests (builds app + runs test bundle)
test-swift: build-swift
	bash -o pipefail -c '\
		xcodebuild test \
			-project apps/macos/Argon.xcodeproj \
			-scheme Argon \
			-configuration Debug \
			-quiet \
			2>&1 | tail -20'

# macOS UI smoke tests
test-ui: build-swift
	xcodebuild test \
		-project apps/macos/Argon.xcodeproj \
		-scheme ArgonUITests \
		-configuration Debug \
		-only-testing:ArgonUITests/ArgonUITests/testGhosttyCustomReviewerLaunchDoesNotCrash

# Build Swift app
build-swift:
	test -d target/libghostty/native/macos/GhosttyKit.xcframework && test -d target/libghostty/native/share/ghostty || bash scripts/build-libghostty.sh
	cd apps/macos && xcodegen generate 2>&1 | tail -1
	xcodebuild build \
		-project apps/macos/Argon.xcodeproj \
		-scheme Argon \
		-configuration Debug \
		-quiet

# License audit
deny:
	cargo deny check

# Build release app bundle with bundled CLI
build-release:
	bash scripts/build-release.sh

# Build release app bundle + DMG
build-dmg:
	bash scripts/build-release.sh --dmg

# Build vendored Ghostty xcframework for future terminal integration
build-libghostty:
	bash scripts/build-libghostty.sh

# Build a universal Ghostty xcframework
build-libghostty-universal:
	bash scripts/build-libghostty.sh --target universal --release

# Print the deterministic Ghostty xcframework path
print-libghostty-path:
	bash scripts/build-libghostty.sh --print-path

# Print the deterministic Ghostty resources path
print-libghostty-resources-path:
	bash scripts/build-libghostty.sh --print-resources-path

# Install dev skill into Claude Code and Codex
install-dev-skill:
	bash scripts/install-dev-skill.sh
