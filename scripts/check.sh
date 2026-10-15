#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xctest_usr_lib=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
xctest_frameworks=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
xctest_runner=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest
cd "$project_root"

for runtime_dir in "$xctest_usr_lib" "$xctest_frameworks"; do
    if [ ! -d "$runtime_dir" ]; then
        printf 'Missing Xcode test runtime: %s\n' "$runtime_dir" >&2
        exit 1
    fi
done
if [ ! -x "$xctest_runner" ]; then
    printf 'Missing Xcode test runner: %s\n' "$xctest_runner" >&2
    exit 1
fi

xcrun swift build --build-tests --enable-xctest --disable-swift-testing \
    -Xswiftc -I -Xswiftc "$xctest_usr_lib" \
    -Xswiftc -F -Xswiftc "$xctest_frameworks" \
    -Xlinker -L -Xlinker "$xctest_usr_lib" \
    -Xlinker -F -Xlinker "$xctest_frameworks" \
    -Xlinker -rpath -Xlinker "$xctest_usr_lib" \
    -Xlinker -rpath -Xlinker "$xctest_frameworks"
binary_dir=$(xcrun swift build --show-bin-path)
test_bundle="$binary_dir/BocchiSmartPetPackageTests.xctest"
if [ ! -d "$test_bundle" ]; then
    printf 'Missing built test bundle: %s\n' "$test_bundle" >&2
    exit 1
fi
DYLD_FRAMEWORK_PATH="$xctest_frameworks" DYLD_LIBRARY_PATH="$xctest_usr_lib" \
    "$xctest_runner" "$test_bundle"
xcrun swift run BocchiSmartPet --self-test
"$project_root/scripts/build-app.sh"
launch_log="$project_root/artifacts/launch-check.log"
launch_errors="$project_root/artifacts/launch-check-stderr.log"
: > "$launch_log"
: > "$launch_errors"
/usr/bin/open -n -W --stdout "$launch_log" --stderr "$launch_errors" \
    "$project_root/dist/Bocchi Smart Pet.app" --args --launch-check
cat "$launch_log"
if ! grep -qx 'LAUNCH-CHECK RESULT: PASS (0 failed)' "$launch_log"; then
    cat "$launch_errors" >&2
    exit 1
fi
