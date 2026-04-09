#!/bin/bash

# BusinessBar Build Script
# This script helps set up and build the BusinessBar application

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"

echo "🚀 BusinessBar Build Script"
echo "=========================="
echo ""

# Check Swift version
echo "📋 Checking Swift version..."
swift --version

# Clean build directory
if [ "$1" == "clean" ]; then
    echo "🧹 Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    rm -rf .swiftpm
    echo "✅ Clean complete"
    exit 0
fi

# Resolve dependencies
echo "📦 Resolving dependencies..."
swift package resolve

# Build the project
echo "🔨 Building BusinessBar..."
if [ "$1" == "release" ]; then
    swift build -c release
    echo "✅ Release build complete: .build/release/BusinessBar"
else
    swift build
    echo "✅ Debug build complete: .build/debug/BusinessBar"
fi

echo ""
echo "🎉 Build successful!"
echo ""
echo "Next steps:"
echo "1. Open the project in Xcode: xed ."
echo "2. Or run directly: .build/debug/BusinessBar"
