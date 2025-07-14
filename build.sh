if [ $# -eq 0 ]; then
  echo "Error: Please provide a version as an argument"
  echo "Usage: $0 <version>"
  exit 1
fi

dart compile exe --target-os=macos --target-arch=arm64 -o bin/zapstore-cli-$1-macos-arm64 lib/main.dart
dart compile exe --target-os=linux --target-arch=arm64 -o bin/zapstore-cli-$1-linux-aarch64 lib/main.dart
dart compile exe --target-os=linux --target-arch=x64 -o bin/zapstore-cli-$1-linux-amd64 lib/main.dart