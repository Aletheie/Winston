#!/bin/zsh

set -eu

repository_root=${0:A:h:h}
project_manifest="$repository_root/Project.swift"
string_catalog="$repository_root/Winston/Resources/Localizable.xcstrings"
failures=0

fail() {
    print -u2 -- "error: $1"
    failures=1
}

if /usr/bin/grep -q 'updates\.example\.com' "$project_manifest"; then
    fail "SUFeedURL still points at updates.example.com"
fi

if /usr/bin/grep -q '"MARKETING_VERSION": "0\.1"' "$project_manifest"; then
    fail "MARKETING_VERSION is still the pre-release placeholder 0.1"
fi

if /usr/bin/grep -q '"NSHumanReadableCopyright": ""' "$project_manifest"; then
    fail "NSHumanReadableCopyright is empty"
fi

if ! /usr/bin/grep -q '"SUPublicEDKey": "[^"].*"' "$project_manifest"; then
    fail "SUPublicEDKey is missing"
fi

if ! /usr/bin/ruby -rjson -e '
catalog = JSON.parse(File.read(ARGV.fetch(0)))
strings = catalog.fetch("strings")
missing = strings.each_with_object([]) do |(key, value), keys|
  czech = value.dig("localizations", "cs")
  keys << key unless czech && (czech["stringUnit"] || czech["variations"])
end
stale = strings.each_with_object([]) do |(key, value), keys|
  keys << key if value["extractionState"] == "stale"
end
unless missing.empty? && stale.empty?
  warn "error: localization catalog has #{missing.count} Czech gaps and #{stale.count} stale entries"
  exit 1
end
' "$string_catalog"; then
    failures=1
fi

if (( failures != 0 )); then
    print -u2 -- "Release readiness checks failed. See docs/ReleaseChecklist.md."
    exit 1
fi

print -- "Release readiness checks passed."
