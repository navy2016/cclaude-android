#!/bin/bash
# Build script for CClaude Agent

set -e

echo "=== Building CClaude Agent ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Build Zig core for multiple architectures
echo -e "${YELLOW}Building Zig core...${NC}"
cd zig-core

# Android ARM64
if command -v zig &> /dev/null; then
    echo "Building for aarch64-linux-android..."
    zig build -Dtarget=aarch64-linux-android || echo "Warning: aarch64 build failed"
    
    echo "Building for arm-linux-android..."
    zig build -Dtarget=arm-linux-android || echo "Warning: arm build failed"
    
    echo "Building for x86_64-linux-android..."
    zig build -Dtarget=x86_64-linux-android || echo "Warning: x86_64 build failed"
    
    # Copy libraries
    echo "Copying libraries to Android project..."
    mkdir -p ../android-app/zig-bridge/src/main/jniLibs/arm64-v8a
    mkdir -p ../android-app/zig-bridge/src/main/jniLibs/armeabi-v7a
    mkdir -p ../android-app/zig-bridge/src/main/jniLibs/x86_64
    
    cp zig-out/lib/libcclaude.so ../android-app/zig-bridge/src/main/jniLibs/arm64-v8a/ 2>/dev/null || true
    cp zig-out/lib/libcclaude.so ../android-app/zig-bridge/src/main/jniLibs/armeabi-v7a/ 2>/dev/null || true
    cp zig-out/lib/libcclaude.so ../android-app/zig-bridge/src/main/jniLibs/x86_64/ 2>/dev/null || true
else
    echo -e "${RED}Zig not found! Please install Zig.${NC}"
    exit 1
fi

cd ..

# 2. Build Android app
echo -e "${YELLOW}Building Android app...${NC}"
cd android-app

if command -v ./gradlew &> /dev/null; then
    ./gradlew assembleDebug
    echo -e "${GREEN}Android app built successfully!${NC}"
    echo "APK location: app/build/outputs/apk/debug/app-debug.apk"
else
    echo -e "${RED}Gradle wrapper not found!${NC}"
    exit 1
fi

cd ..

echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Install the APK to your Android device:"
echo "  adb install android-app/app/build/outputs/apk/debug/app-debug.apk"
