.PHONY: check fmt lint test test-rust test-swift build-swift build-release build-dmg deny

# Run all checks (formatting, linting, tests, license audit)
check: fmt lint deny test

# Format all code
fmt:
	cargo fmt
	swift-format format --in-place --recursive apps/macos/Sources/ apps/macos/Tests/

# Lint all code
lint:
	cargo fmt --check
	cargo clippy --workspace -- -D warnings
	swift-format lint --recursive apps/macos/Sources/ apps/macos/Tests/

# Run all tests
test: test-rust test-swift

# Rust tests
test-rust:
	cargo test --workspace

# Swift tests (builds app + runs test bundle)
test-swift: build-swift
	xcodebuild test \
		-project apps/macos/Argon.xcodeproj \
		-scheme Argon \
		-configuration Debug \
		-quiet \
		2>&1 | tail -20

# Build Swift app
build-swift:
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

# Install dev skill into Claude Code and Codex
install-dev-skill:
	bash scripts/install-dev-skill.sh
