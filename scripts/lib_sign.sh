# Shared by bundle.sh and release.sh. Source it; don't run it.

# Copies Sparkle.framework from a SwiftPM build folder into the app and lets the
# executable find it (Contents/Frameworks).
#   embed_sparkle <app> <swiftpm bin dir>
embed_sparkle() {
  local app=$1 bin_dir=$2
  local framework="$bin_dir/Sparkle.framework"
  if [[ ! -d $framework ]]; then
    return 0   # built without Sparkle (automatic updates off)
  fi
  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework"
  # ditto keeps the framework's symlinks intact (cp -R can break code signatures).
  ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/NotchIsland" 2>/dev/null || true
}

# Signs an app inside-out: Sparkle's helpers, then Sparkle, then the app (never --deep;
# Sparkle's documentation warns it breaks its helpers' signatures).
#   sign_app <app> <identity> <release|dev> [entitlements]
sign_app() {
  local app=$1 identity=$2 mode=$3 entitlements=${4:-}
  local opts=(--force --sign "$identity")
  [[ $mode == release ]] && opts+=(--options runtime --timestamp)

  local framework="$app/Contents/Frameworks/Sparkle.framework"
  if [[ -d $framework ]]; then
    local version="$framework/Versions/B"
    [[ -d $version ]] || version="$framework/Versions/Current"
    local xpc
    for xpc in "$version"/XPCServices/*.xpc; do
      [[ -e $xpc ]] || continue
      if [[ $(basename "$xpc") == Downloader.xpc ]]; then
        codesign "${opts[@]}" --preserve-metadata=entitlements "$xpc"
      else
        codesign "${opts[@]}" "$xpc"
      fi
    done
    [[ -e $version/Autoupdate ]] && codesign "${opts[@]}" "$version/Autoupdate"
    [[ -e $version/Updater.app ]] && codesign "${opts[@]}" "$version/Updater.app"
    codesign "${opts[@]}" "$framework"
  fi

  if [[ -n $entitlements ]]; then
    codesign "${opts[@]}" --entitlements "$entitlements" "$app"
  else
    codesign "${opts[@]}" "$app"
  fi
}

# Sparkle's command-line tools (sign_update, generate_keys) from the SwiftPM download.
sparkle_tool() {
  local tool
  tool=$(find .build/artifacts -type f -path "*/bin/$1" 2>/dev/null | head -1)
  [[ -n $tool ]] && echo "$tool"
}
