# Shared build settings, sourced by the other scripts.
# The Command Line Tools' newest macOS SDK lacks the SwiftUI and Testing macro plugins (they ship with
# Xcode), so without Xcode we build against the newest older SDK and point at the Testing plugin.
if ! xcodebuild -version >/dev/null 2>&1; then
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk(On); do
    export SDKROOT="$sdk"; break
  done
  TESTING_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  [[ -d $TESTING_PLUGINS ]] && TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
: ${TEST_FLAGS:=}
VERSION=$(tr -d '[:space:]' < VERSION)
