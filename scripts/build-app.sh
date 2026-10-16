#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$project_root/dist"
output_app="$output_dir/Bocchi Smart Pet.app"

cd "$project_root"
xcrun swift build --configuration release --product BocchiSmartPet
binary_dir=$(xcrun swift build --configuration release --show-bin-path)

mkdir -p "$output_dir"
staging_dir=$(mktemp -d "$output_dir/.bocchi-smart-pet.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
staging_app="$staging_dir/Bocchi Smart Pet.app"

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
cp "$project_root/Assets/Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_root/Assets/bocchi-spritesheet.png" "$staging_app/Contents/Resources/bocchi-spritesheet.png"
cp "$project_root/Assets/bocchi-seat-front.png" "$staging_app/Contents/Resources/bocchi-seat-front.png"
cp "$project_root/Assets/bocchi-run-left.png" "$staging_app/Contents/Resources/bocchi-run-left.png"
cp "$project_root/Assets/bocchi-run-right.png" "$staging_app/Contents/Resources/bocchi-run-right.png"
install -m 755 "$binary_dir/BocchiSmartPet" "$staging_app/Contents/MacOS/BocchiSmartPet"

plutil -lint "$staging_app/Contents/Info.plist"
/usr/bin/python3 "$project_root/scripts/sign-app.py" "$staging_app"
xcrun codesign --verify --strict "$staging_app"

rm -rf "$output_app"
mv "$staging_app" "$output_app"
printf 'Built %s\n' "$output_app"
