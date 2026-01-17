#!/usr/bin/env bash
# Determines which test targets are affected by changed files

set -euo pipefail

COMMIT_RANGE=${COMMIT_RANGE:-"HEAD^..HEAD"}
echo "Commit range: ${COMMIT_RANGE}"

cd "$(git rev-parse --show-toplevel)"

affected_files=$(git diff --name-only "${COMMIT_RANGE}")
file_count=$(echo "${affected_files}" | wc -l | tr -d ' ')
echo "Changed files: ${file_count}"
if [[ -z "${affected_files}" ]]; then
  echo "bazel-targets=''" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Convert file paths to bazel labels
echo "Finding bazel labels for changed files..."
labels=()
for file in $affected_files; do
  [[ -f "$file" ]] || continue

  dir=$(dirname "$file")
  filename=$(basename "$file")

  while [[ "$dir" != "." && ! -f "$dir/BUILD.bazel" && ! -f "$dir/BUILD" ]]; do
    filename="$(basename "$dir")/$filename"
    dir=$(dirname "$dir")
  done

  if [[ -f "$dir/BUILD.bazel" || -f "$dir/BUILD" ]]; then
    labels+=("//${dir}:${filename}")
  fi
done

echo "Bazel labels: ${#labels[@]}"
if (( ${#labels[@]} == 0 )); then
  echo "bazel-targets=''" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Query all labels at once
source_targets=$(bazel query --keep_going --noshow_progress "set(${labels[*]})" 2>/dev/null || true)
target_count=$(echo "${source_targets}" | wc -l | tr -d ' ')
echo "Source targets: ${target_count}"
if [[ -z "${source_targets}" ]]; then
  echo "bazel-targets=''" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Query each binding in parallel
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

bindings=("//java/..." "//py/..." "//rb/..." "//dotnet/..." "//javascript/selenium-webdriver/...")

for binding in "${bindings[@]}"; do
  (
    echo "Starting query for ${binding}..."
    if bazel query --keep_going --noshow_progress \
      "kind(test, rdeps(set(${binding}), set(${source_targets}))) \
       except attr('tags','manual', set(${binding})) \
       except attr('tags','lint', set(${binding}))" \
      > "${tmpdir}/${binding//\//_}.txt" 2>&1; then
      count=$(wc -l < "${tmpdir}/${binding//\//_}.txt" | tr -d ' ')
      echo "Finished ${binding}: ${count} targets"
    else
      echo "Failed ${binding}"
      cat "${tmpdir}/${binding//\//_}.txt"
      rm -f "${tmpdir}/${binding//\//_}.txt"
    fi
  ) &
done

wait
echo "All queries complete"

# Combine results
test_targets=""
for f in "${tmpdir}"/*.txt; do
  [[ -s "$f" ]] && test_targets="${test_targets} $(cat "$f")"
done

test_targets=$(echo "${test_targets}" | xargs -n1 | sort -u | xargs)

if [[ -z "${test_targets}" ]]; then
  echo "No test targets found for the changed files."
  echo "bazel-targets=''" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "Found test targets:"
echo "${test_targets}" | xargs -n1

{
  echo "bazel-targets<<EOF"
  echo "${test_targets}"
  echo "EOF"
} >> "$GITHUB_OUTPUT"
