#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
output_root=${1:-}

if (( $# > 1 )); then
    print -u2 "usage: Scripts/profile-library-ui.sh [output-directory]"
    exit 64
fi

if [[ -z "$output_root" ]]; then
    output_root=$(mktemp -d /private/tmp/WinstonLibraryPerformance.XXXXXX)
else
    mkdir -p "$output_root"
    output_root=${output_root:A}
    if [[ -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        print -u2 "output directory must be empty: $output_root"
        exit 64
    fi
fi

if [[ "$output_root" == "/" || "$output_root" == "$HOME" ]]; then
    print -u2 "refusing unsafe output directory: $output_root"
    exit 64
fi

typeset -a counts
if [[ -n "${WINSTON_PERF_COUNTS:-}" ]]; then
    counts=(${=WINSTON_PERF_COUNTS})
else
    counts=(1000 10000 50000)
fi

for count in "${counts[@]}"; do
    if [[ "$count" != <-> || "$count" -lt 1 || "$count" -gt 50000 ]]; then
        print -u2 "invalid book count: $count"
        exit 64
    fi
done

time_limit=${WINSTON_PERF_TIME_LIMIT:-120s}
local_fetch_budget=${WINSTON_PERF_LOCAL_FETCH_BUDGET:-12}
if [[ "$local_fetch_budget" != <-> || "$local_fetch_budget" -lt 1 ]]; then
    print -u2 "WINSTON_PERF_LOCAL_FETCH_BUDGET must be a positive integer"
    exit 64
fi

derived_data="$output_root/DerivedData"
datasets_directory="$output_root/datasets"
traces_directory="$output_root/traces"
logs_directory="$output_root/logs"
runs_directory="$output_root/runs"

mkdir -p "$datasets_directory" "$traces_directory" "$logs_directory" "$runs_directory"

{
    print "recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sw_vers
    xcodebuild -version
    system_profiler SPHardwareDataType
} > "$output_root/machine.txt"

print "Generating the Xcode project"
(cd "$repository_root" && tuist generate --no-open)

print "Building Winston in Release configuration"
xcodebuild \
    -project "$repository_root/Winston.xcodeproj" \
    -scheme Winston \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build \
    > "$logs_directory/release-build.log"

built_app="$derived_data/Build/Products/Release/Winston.app"
built_binary="$built_app/Contents/MacOS/Winston"
if [[ ! -x "$built_binary" ]]; then
    print -u2 "Release executable is missing: $built_binary"
    exit 1
fi

# Instruments that inject runtime support (notably SwiftUI and Allocations) must launch
# the app rather than attach after startup. Give only this disposable Release bundle a
# unique identity and executable name so Instruments cannot resolve it to another
# registered Winston installation.
app_bundle="$derived_data/Build/Products/Release/WinstonPerformance.app"
mv "$built_app" "$app_bundle"
binary="$app_bundle/Contents/MacOS/WinstonPerformance"
mv "$app_bundle/Contents/MacOS/Winston" "$binary"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier cz.annajung.Winston.Performance" \
    "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleExecutable WinstonPerformance" \
    "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleName WinstonPerformance" \
    "$app_bundle/Contents/Info.plist"
quick_look_plist="$app_bundle/Contents/PlugIns/WinstonQuickLook.appex/Contents/Info.plist"
if [[ -f "$quick_look_plist" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier cz.annajung.Winston.Performance.QuickLook" \
        "$quick_look_plist"
fi
codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "$repository_root/Scripts/LibraryPerformance.entitlements" \
    "$app_bundle"

print "dataset,template,trace,stdout,result,toc" > "$output_root/trace-manifest.csv"
print "dataset,scope,main_thread_wall_ms,main_thread_cpu_ms,data_persistence_fetches,data_persistence_faults,peak_live_swiftdata_models,allocated_bytes,persistent_bytes,peak_live_bytes,content_view_bodies,library_view_bodies,sidebar_view_bodies,read_model_sync_bodies,notes" \
    > "$output_root/results.csv"
print "dataset,scope,occurrence,sql_select_statements,budget,status" \
    > "$output_root/swiftdata-query-counts.csv"
print "dataset,metric,event_count,export" \
    > "$output_root/data-persistence-counts.csv"

typeset -a template_names template_slugs
template_names=("Time Profiler" "SwiftUI" "Data Persistence" "Allocations")
template_slugs=("time-profiler" "swiftui" "data-persistence" "allocations")

for count in "${counts[@]}"; do
    pristine_root="$datasets_directory/books-$count"
    mkdir -p "$pristine_root"
    print "Preparing deterministic $count-book store"
    "$binary" \
        --winston-library-performance-prepare \
        "$count" \
        "$pristine_root" \
        > "$logs_directory/prepare-$count.log"

    for scope in library_initial_load library_snapshot sidebar_facets status collection title cover asset edition_scan calibre_import calibre_catalog_index catalog_identity_index_rebuild; do
        print "$count,$scope,,,,,,,,,,,,," >> "$output_root/results.csv"
    done

    for index in {1..4}; do
        template=${template_names[$index]}
        slug=${template_slugs[$index]}
        run_root="$runs_directory/books-$count-$slug"
        trace="$traces_directory/books-$count-$slug.trace"
        target_log="$logs_directory/books-$count-$slug.stdout.log"
        result_file="$logs_directory/books-$count-$slug.result"
        toc="$traces_directory/books-$count-$slug.toc.xml"
        typeset -a instrument_options
        instrument_options=()
        if [[ "$slug" == "data-persistence" ]]; then
            instrument_options=(--instrument "Points of Interest")
        fi

        ditto "$pristine_root" "$run_root"
        print "Recording $template with $count books"
        xcrun xctrace record \
            --template "$template" \
            --output "$trace" \
            --time-limit "$time_limit" \
            --no-prompt \
            "${instrument_options[@]}" \
            --env WINSTON_LIBRARY_PERFORMANCE_ROOT="$run_root" \
            --env WINSTON_LIBRARY_PERFORMANCE_SCENARIO=1 \
            --env WINSTON_LIBRARY_PERFORMANCE_COUNT="$count" \
            --env WINSTON_LIBRARY_PERFORMANCE_RESULT_FILE="$result_file" \
            --target-stdout "$target_log" \
            --launch -- "$binary" -ApplePersistenceIgnoreState YES

        if [[ ! -f "$result_file" ]] || ! rg -q "^complete books=$count$" "$result_file"; then
            print -u2 "scenario did not complete; inspect $result_file and $target_log"
            exit 1
        fi

        xcrun xctrace export \
            "$trace" \
            --toc \
            --output "$toc"
        if [[ "$slug" == "data-persistence" ]]; then
            for schema in core-data-fetch core-data-fault core-data-relationship-fault; do
                metric=${schema#core-data-}
                export_xml="$traces_directory/books-$count-$schema.xml"
                xcrun xctrace export \
                    "$trace" \
                    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
                    --output "$export_xml"
                event_count=$(awk '{
                    count += gsub(/<row>/, "&")
                } END {
                    print count + 0
                }' "$export_xml")
                print "$count,$metric,$event_count,$export_xml" \
                    >> "$output_root/data-persistence-counts.csv"
            done
        fi
        print "$count,\"$template\",\"$trace\",\"$target_log\",\"$result_file\",\"$toc\"" \
            >> "$output_root/trace-manifest.csv"
    done

    sql_run_root="$runs_directory/books-$count-sql"
    sql_log="$logs_directory/books-$count-swiftdata-sql.log"
    sql_result_file="$logs_directory/books-$count-swiftdata-sql.result"
    ditto "$pristine_root" "$sql_run_root"
    print "Counting SwiftData SQL statements with $count books"
    (
        export WINSTON_LIBRARY_PERFORMANCE_ROOT="$sql_run_root"
        export WINSTON_LIBRARY_PERFORMANCE_SCENARIO=1
        export WINSTON_LIBRARY_PERFORMANCE_COUNT="$count"
        export WINSTON_LIBRARY_PERFORMANCE_RESULT_FILE="$sql_result_file"
        "$binary" \
            -ApplePersistenceIgnoreState YES \
            -com.apple.CoreData.SQLDebug 1 \
            -com.apple.CoreData.Logging.stderr 1
    ) > "$sql_log" 2>&1

    if [[ ! -f "$sql_result_file" ]] \
        || ! rg -q "^complete books=$count$" "$sql_result_file"; then
        print -u2 "SQL counting scenario did not complete; inspect $sql_result_file and $sql_log"
        exit 1
    fi

    awk \
        -v dataset="$count" \
        -v local_budget="$local_fetch_budget" \
        '
        function markerName(line, prefix, value) {
            if (match(line, /name=[A-Za-z0-9_]+/)) {
                value = substr(line, RSTART + 5, RLENGTH - 5)
                return value
            }
            return ""
        }
        function isLocalMutation(name) {
            return name == "status" \
                || name == "collection" \
                || name == "title" \
                || name == "cover" \
                || name == "asset"
        }
        /WINSTON_SWIFTDATA_SCOPE_BEGIN name=/ {
            name = markerName($0)
            occurrence[name]++
            active[name] = occurrence[name]
            key = name SUBSEP occurrence[name]
            selects[key] = 0
            next
        }
        /WINSTON_SWIFTDATA_SCOPE_END name=/ {
            name = markerName($0)
            if (!(name in active)) {
                print "scope ended without a begin marker: " name > "/dev/stderr"
                parse_failed = 1
                next
            }
            key = name SUBSEP active[name]
            budget = isLocalMutation(name) ? local_budget : ""
            status = budget != "" && selects[key] > budget ? "over_budget" : "ok"
            printf "%s,%s,%d,%d,%s,%s\n", \
                dataset, name, active[name], selects[key], budget, status
            delete active[name]
            next
        }
        {
            lower = tolower($0)
            if (lower ~ /coredata: sql: select/) {
                for (name in active) {
                    key = name SUBSEP active[name]
                    selects[key]++
                }
            }
        }
        END {
            for (name in active) {
                print "scope never ended: " name > "/dev/stderr"
                parse_failed = 1
            }
            if (parse_failed) {
                exit 2
            }
        }
        ' "$sql_log" >> "$output_root/swiftdata-query-counts.csv"
done

print "Release performance traces are ready in $output_root"
if rg -q ",over_budget$" "$output_root/swiftdata-query-counts.csv"; then
    print -u2 "one or more local mutations exceeded the $local_fetch_budget SELECT budget"
    exit 2
fi
