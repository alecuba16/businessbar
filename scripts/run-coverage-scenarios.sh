#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="${TMPDIR:-/tmp}/businessbar-coverage"
build=yes
selection=all
isolation_only=no
usage() {
    cat <<'USAGE'
Usage: scripts/run-coverage-scenarios.sh [--output-dir PATH] [--no-build]
       [--native-only | --scenarios-only] [--isolation-only]

Links existing instrumented app objects, excluding only the app entry object.
Default: swift build --enable-code-coverage, then scenarios and both native fixtures.
--no-build requires an existing instrumented debug build and is diagnostic only.
--isolation-only compiles and runs only the harmless startup isolation check.
BUSINESSBAR_COVERAGE_TIMEOUT_SECONDS sets each process timeout (default 900).
BUSINESSBAR_COVERAGE_SUITE=all|core|app filters scenario suites.
Every invocation creates a new run directory inside --output-dir.
USAGE
}
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
hash_file() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
while (( $# )); do
    case "$1" in
        --output-dir)
            (( $# >= 2 )) || fail '--output-dir requires a path'
            output_root="$2"; shift 2 ;;
        --no-build) build=no; shift ;;
        --native-only)
            [[ "$selection" != scenarios ]] || fail 'choose one fixture selection'
            selection=native; shift ;;
        --scenarios-only)
            [[ "$selection" != native ]] || fail 'choose one fixture selection'
            selection=scenarios; shift ;;
        --isolation-only) isolation_only=yes; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'this runner requires macOS'
timeout_seconds="${BUSINESSBAR_COVERAGE_TIMEOUT_SECONDS:-900}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'timeout must be a positive number of seconds'
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd -P)"
[[ ! -e "$output_root/manifest.json" && ! -L "$output_root/manifest.json" ]] || fail 'output manifest already exists; choose a fresh output directory'
run_dir="$(mktemp -d "$output_root/run.XXXXXX")"
mkdir -p "$run_dir/bin" "$run_dir/profiles" "$run_dir/logs" "$run_dir/runtime" "$run_dir/timeouts"
printf 'RUN_DIRECTORY=%s\n' "$run_dir"

if [[ "$build" == yes ]]; then
    build_flags=()
    helper_flags="$(bash "$repo_root/scripts/swift-clt-plugins.sh" flags)" || fail 'CLT macro plugin discovery failed'
    if [[ -n "$helper_flags" ]]; then
        read -r first second third plugin_path <<< "$helper_flags"
        [[ "$first" == -Xswiftc && "$second" == -plugin-path && "$third" == -Xswiftc && -n "$plugin_path" ]] || fail 'unexpected CLT helper flag format'
        build_flags=(-Xswiftc -plugin-path -Xswiftc "$plugin_path")
    fi
    (cd "$repo_root" && xcrun swift build --enable-code-coverage ${build_flags[@]+"${build_flags[@]}"}) > "$run_dir/logs/build.log" 2>&1 || {
        cat "$run_dir/logs/build.log" >&2
        fail 'instrumented build failed'
    }
fi

link_lists=()
while IFS= read -r -d '' candidate; do link_lists+=("$candidate"); done < <(
    find "$repo_root/.build" -type f \( -name BusinessBar.LinkFileList -o -path '*/BusinessBar.product/Objects.LinkFileList' \) -print0
)
(( ${#link_lists[@]} )) || fail 'no BusinessBar object link file list found; run an instrumented build'
selected_lists=()
for candidate in "${link_lists[@]}"; do
    case "$candidate" in */Debug/*|*/debug/*) selected_lists+=("$candidate") ;; esac
done
(( ${#selected_lists[@]} == 1 )) || fail "expected one debug app link file list, found ${#selected_lists[@]}; remove ambiguity outside this runner"
app_link_list="${selected_lists[0]}"

# Normalize quoted and escaped paths before removing the app entry object.
awk '
function emit() { if (length(token)) { print token; token = "" } }
{
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (escaped) { token = token c; escaped = 0 }
        else if (c == "\\" && quote != "\047") { escaped = 1 }
        else if (quote != "") { if (c == quote) quote = ""; else token = token c }
        else if (c == "\047" || c == "\042") { quote = c }
        else if (c ~ /[[:space:]]/) { emit() }
        else { token = token c }
    }
    if (!quote && !escaped) emit()
}
END { if (quote || escaped) exit 1; emit() }
' "$app_link_list" > "$run_dir/all-objects.list" || fail 'could not parse app object link file list'
entry_count=0
object_count=0
: > "$run_dir/harness-objects.list"
while IFS= read -r object; do
    [[ -f "$object" ]] || fail "missing object: $object"
    case "$(basename "$object")" in
        BusinessBarApp.o|BusinessBarApp.swift.o)
            entry_count=$((entry_count + 1)) ;;
        *) printf '%s\n' "$object" >> "$run_dir/harness-objects.list"; object_count=$((object_count + 1)) ;;
    esac
done < "$run_dir/all-objects.list"
(( entry_count == 1 )) || fail "expected exactly one BusinessBarApp entry object, found $entry_count"
(( object_count > 0 )) || fail 'app object list is empty'

backend_root=
case "$app_link_list" in
    */Intermediates.noindex/*)
        backend_root="${app_link_list%%/Intermediates.noindex/*}"
        products="$backend_root/Products/Debug"
        app_module_dir="$(dirname "$app_link_list")"
        module_dir="$products"
        ;;
    *)
        products="$(dirname "$(dirname "$app_link_list")")"
        app_module_dir="$products/Modules"
        module_dir="$products/Modules"
        ;;
esac
original_app="$products/BusinessBar"
[[ -f "$original_app" ]] || fail "original app executable is missing: $original_app"
app_binary_sha256="$(hash_file "$original_app")"
app_link_file_list_sha256="$(hash_file "$app_link_list")"
object_list_sha256="$(hash_file "$run_dir/harness-objects.list")"
[[ -e "$app_module_dir/BusinessBar.swiftmodule" ]] || fail 'BusinessBar.swiftmodule is missing'
[[ -e "$module_dir/BusinessBarCore.swiftmodule" ]] || fail 'BusinessBarCore.swiftmodule is missing'
xcrun otool -l "$original_app" | grep '__llvm_covmap' > "$run_dir/logs/instrumentation.txt" || fail 'existing app is not coverage-instrumented'

compile_flags=(
    -I "$app_module_dir" -I "$module_dir" -I "$products"
    -F "$products" -F "$products/PackageFrameworks"
    -module-cache-path "$output_root/module-cache"
    -profile-generate -profile-coverage-mapping
    -Xlinker -filelist -Xlinker "$run_dir/harness-objects.list"
    -framework Sparkle -Xlinker -rpath -Xlinker "$products"
    -Xlinker -rpath -Xlinker "$products/PackageFrameworks"
)
for name in AppAuth AppAuthCore; do
    maps=()
    while IFS= read -r -d '' candidate; do maps+=("$candidate"); done < <(
        find "${backend_root:-$products}/Intermediates.noindex/GeneratedModuleMaps" -name "$name.modulemap" -print0 2>/dev/null || true
    )
    if (( ${#maps[@]} == 0 )); then
        while IFS= read -r -d '' candidate; do maps+=("$candidate"); done < <(
            find "$products/$name.build" -name module.modulemap -print0 2>/dev/null || true
        )
    fi
    (( ${#maps[@]} == 1 )) || fail "expected one $name module map, found ${#maps[@]}"
    compile_flags+=(-Xcc "-fmodule-map-file=${maps[0]}")
done
appauth_source="$repo_root/.build/checkouts/AppAuth-iOS/Sources"
[[ -d "$appauth_source/AppAuthCore" ]] || fail 'AppAuth source headers are unavailable'
compile_flags+=(-Xcc "-I$appauth_source/AppAuthCore" -Xcc "-I$appauth_source/AppAuth/macOS")
for bundle in "$products/"*.bundle; do
    [[ -d "$bundle" ]] && ln -s "$bundle" "$run_dir/bin/$(basename "$bundle")"
done

active_pid=
watchdog_pid=
cleanup_processes() {
    if [[ -n "$active_pid" ]]; then
        kill -TERM "$active_pid" 2>/dev/null || true
        kill -KILL "$active_pid" 2>/dev/null || true
    fi
    if [[ -n "$watchdog_pid" ]]; then kill -TERM "$watchdog_pid" 2>/dev/null || true; fi
}
trap cleanup_processes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compile_binary() {
    local name="$1"
    shift
    local identifier="com.businessbar.coverage.$(uuidgen | tr '[:upper:]' '[:lower:]').$name"
    cat > "$run_dir/$name.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>BusinessBarCoverage-$name</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    printf '%s\n' "$identifier" > "$run_dir/$name.identifier"
    printf 'Compiling %s against %s actual object inputs\n' "$name" "$object_count"
    xcrun swiftc "$@" "${compile_flags[@]}" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$run_dir/$name.plist" \
        -o "$run_dir/bin/$name" > "$run_dir/logs/$name-build.log" 2>&1 || {
        cat "$run_dir/logs/$name-build.log" >&2
        fail "$name compilation failed"
    }
}

run_binary() {
    local name="$1"
    shift
    local runtime="$run_dir/runtime/$name"
    local identifier
    identifier="$(cat "$run_dir/$name.identifier")"
    mkdir -p "$runtime/home/Library/Application Support" "$runtime/home/Library/Preferences" "$runtime/tmp" "$runtime/fixtures"
    env HOME="$runtime/home" CFFIXED_USER_HOME="$runtime/home" TMPDIR="$runtime/tmp/" \
        BUSINESSBAR_COVERAGE_HOME="$runtime/home" BUSINESSBAR_COVERAGE_TMP="$runtime/tmp" \
        BUSINESSBAR_COVERAGE_BUNDLE_ID="$identifier" BUSINESSBAR_COVERAGE_FIXTURES="$runtime/fixtures" \
        BUSINESSBAR_COVERAGE_REPO_ROOT="$repo_root" BUSINESSBAR_COVERAGE_SOURCE_SNAPSHOT="$run_dir/source-sha256.json" \
        BUSINESSBAR_COVERAGE_ALL_OBJECTS="$run_dir/all-objects.list" BUSINESSBAR_COVERAGE_BUILT="$build" \
        PACKAGE_RESOURCE_BUNDLE_PATH="$products" \
        LLVM_PROFILE_FILE="$run_dir/profiles/$name-%p.profraw" \
        "$run_dir/bin/$name" "$@" > "$run_dir/logs/$name-run.log" 2>&1 &
    active_pid=$!
    (
        deadline=$((SECONDS + timeout_seconds))
        while kill -0 "$active_pid" 2>/dev/null; do
            if (( SECONDS >= deadline )); then
                printf 'timeout\n' > "$run_dir/timeouts/$name"
                kill -TERM "$active_pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$active_pid" 2>/dev/null || true
                exit 0
            fi
            sleep 1
        done
    ) &
    watchdog_pid=$!
    local result=0
    wait "$active_pid" || result=$?
    active_pid=
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=
    cat "$run_dir/logs/$name-run.log"
    [[ ! -f "$run_dir/timeouts/$name" ]] || { printf 'FAIL: %s exceeded %s seconds\n' "$name" "$timeout_seconds" >&2; exit 124; }
    (( result == 0 )) || fail "$name exited with status $result"
}

runner="$repo_root/Tests/CoverageRunner/Runner.swift"
compile_binary isolation -parse-as-library -D BUSINESSBAR_COVERAGE_ISOLATION "$runner"
run_binary isolation --isolation-only --write-source-snapshot
if [[ "$isolation_only" != yes ]]; then
    if [[ "$selection" != native ]]; then
        scenarios=()
        while IFS= read -r -d '' source; do scenarios+=("$source"); done < <(
            find "$repo_root/Tests/CoverageTests" -type f -name '*.swift' ! -name '*Tests.swift' -print0
        )
        (( ${#scenarios[@]} > 0 )) || fail 'no coverage scenario sources found'
        compile_binary scenarios -parse-as-library "$runner" "${scenarios[@]}"
        run_binary scenarios
        # Suite-loss guard. Measured failure mode (run12, run13, reproduced
        # standalone): the scenarios process can exit 0 mid-suite with no
        # FAIL line (the async main job stops resuming and the Swift
        # async-main drain queue calls exit(0)). Without this guard every
        # remaining suite's coverage silently disappears while the run
        # still reports success. The three markers below are printed only
        # after the corresponding suite completed; any mid-suite death
        # removes at least one of them.
        scenarios_log="$run_dir/logs/scenarios-run.log"
        grep -q '^PASS: core behavior scenarios$' "$scenarios_log" \
            || fail 'scenarios process lost the core suite (silent mid-suite exit; see scenarios-run.log)'
        if [[ "${BUSINESSBAR_COVERAGE_SUITE:-all}" == all ]]; then
            grep -q '^PASS: app behavior scenarios$' "$scenarios_log" \
                || fail 'scenarios process lost the app suite (silent mid-suite exit; see scenarios-run.log)'
        fi
        grep -qE '^PASS: [0-9]+ coverage scenario checks$' "$scenarios_log" \
            || fail 'scenarios process exited before the final runner marker (silent mid-suite exit; see scenarios-run.log)'
    fi
    if [[ "$selection" != scenarios ]]; then
        compile_binary markdown -D BUSINESSBAR_COVERAGE_NATIVE "$runner" "$repo_root/Tests/MarkdownRendering/main.swift"
        run_binary markdown
        compile_binary composer -D BUSINESSBAR_COVERAGE_NATIVE "$runner" "$repo_root/Tests/ComposerMarkers/main.swift"
        run_binary composer
    fi
fi
run_binary isolation --isolation-only --verify-source-snapshot
[[ "$(hash_file "$original_app")" == "$app_binary_sha256" ]] || fail 'original app binary changed during coverage execution'
[[ "$(hash_file "$app_link_list")" == "$app_link_file_list_sha256" ]] || fail 'app object link list changed during coverage execution'
profiles=()
while IFS= read -r -d '' profile; do profiles+=("$profile"); done < <(find "$run_dir/profiles" -name '*.profraw' -type f -print0)
(( ${#profiles[@]} > 0 )) || fail 'no raw coverage profiles were produced'
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$run_dir/coverage.profdata"
{
    printf 'RUN_DIRECTORY=%q\n' "$run_dir"
    printf 'COVERAGE_BINARY=%q\n' "$original_app"
    printf 'COVERAGE_PROFILE=%q\n' "$run_dir/coverage.profdata"
    printf 'COVERAGE_OBJECT_LIST=%q\n' "$run_dir/harness-objects.list"
    printf 'COVERAGE_RESOURCE_DIRECTORY=%q\n' "$products"
} > "$run_dir/artifacts.env"
manifest="$run_dir/artifacts.plist"
diagnostic_only=true
if [[ "$build" == yes && "$selection" == all && "$isolation_only" == no && "${BUSINESSBAR_COVERAGE_SUITE:-all}" == all ]]; then
    diagnostic_only=false
fi
/usr/bin/plutil -create xml1 "$manifest"
/usr/bin/plutil -insert source_sha256 -json "$(cat "$run_dir/source-sha256.json")" "$manifest"
/usr/bin/plutil -insert diagnostic_only -bool "$diagnostic_only" "$manifest"
/usr/bin/plutil -insert selection -string "$selection" "$manifest"
/usr/bin/plutil -insert isolation_only -bool "$([[ "$isolation_only" == yes ]] && printf true || printf false)" "$manifest"
/usr/bin/plutil -insert built -bool "$([[ "$build" == yes ]] && printf true || printf false)" "$manifest"
/usr/bin/plutil -insert suite -string "${BUSINESSBAR_COVERAGE_SUITE:-all}" "$manifest"
/usr/bin/plutil -insert run_directory -string "$run_dir" "$manifest"
/usr/bin/plutil -insert binary -string "$original_app" "$manifest"
/usr/bin/plutil -insert app_binary -string "$original_app" "$manifest"
/usr/bin/plutil -insert app_binary_sha256 -string "$app_binary_sha256" "$manifest"
/usr/bin/plutil -insert object_list_sha256 -string "$object_list_sha256" "$manifest"
/usr/bin/plutil -insert app_link_file_list -string "$app_link_list" "$manifest"
/usr/bin/plutil -insert app_link_file_list_sha256 -string "$app_link_file_list_sha256" "$manifest"
/usr/bin/plutil -insert profile -string "$run_dir/coverage.profdata" "$manifest"
/usr/bin/plutil -insert object_list -string "$run_dir/harness-objects.list" "$manifest"
/usr/bin/plutil -insert resource_directory -string "$products" "$manifest"
/usr/bin/plutil -insert profiles -array "$manifest"
for index in "${!profiles[@]}"; do
    /usr/bin/plutil -insert "profiles.$index" -string "${profiles[$index]}" "$manifest"
done
/usr/bin/plutil -insert native_binaries -dictionary "$manifest"
for name in markdown composer; do
    if [[ -f "$run_dir/bin/$name" ]]; then
        /usr/bin/plutil -insert "native_binaries.$name" -string "$run_dir/bin/$name" "$manifest"
    fi
done
if [[ -f "$run_dir/bin/scenarios" ]]; then
    /usr/bin/plutil -insert scenario_binary -string "$run_dir/bin/scenarios" "$manifest"
fi
/usr/bin/plutil -convert json -o "$run_dir/artifacts.json" "$manifest"
(set -o noclobber; cat "$run_dir/artifacts.json" > "$output_root/manifest.json") || fail 'could not publish a fresh top-level manifest'
printf 'PASS: coverage profiles merged. Manifest: %s\n' "$output_root/manifest.json"
