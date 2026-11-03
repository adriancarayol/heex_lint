#!/usr/bin/env bash
# Lints the same classes with @shadcn/lint's own rules and with HeexLint,
# on equivalent React and HEEx projects, and compares the findings with the
# accepted differences in known_gaps/.
#
#   scripts/parity/run.sh            fails on new differences and stale gaps
#   scripts/parity/run.sh --update   rewrites known_gaps/ from this run
#
# Needs git, node, npm and mix. Clones @shadcn/lint at a pinned commit.
set -euo pipefail

usage="usage: scripts/parity/run.sh [--update]"
update=0
case "$#:${1:-}" in
  0:) ;;
  1:--update) update=1 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
commit="9231259"
deps="cn@0.4.0 @eslint/core@0.17.0 eslint@9.39.5 @typescript-eslint/parser@8.72.1 typescript@5.9.3 tsx@4.23.15 tsdown@0.12.9 tailwindcss@4.3.3 @tailwindcss/node@4.3.3"
configs="1 2 3"
# Every theme but the default runs the shorter themed_cases.txt.
themes="scales radius_reset full_reset scoped_values explicit_imports workspace_package prefixed installed_package installed_unnamed installed_resolution plugin_modules"

# The same bytes order on every machine, so known_gaps/ does not depend on it.
export LC_ALL=C

cd "$here"
if [ ! -d shadcn-lint ]; then
  git clone -q https://github.com/shadcn-ui/lint.git shadcn-lint
fi
git -C shadcn-lint cat-file -e "$commit^{commit}" 2>/dev/null || git -C shadcn-lint fetch -q origin
git -C shadcn-lint checkout -q "$commit"

# Moving the pin must not reuse what the old pin installed or built.
if [ "$(cat node_modules/.parity-deps 2>/dev/null || true)" != "$deps" ]; then
  rm -rf node_modules package.json package-lock.json
  npm init -y >/dev/null
  # shellcheck disable=SC2086 # deps is a list of packages.
  npm i -q -D $deps >/dev/null
  echo "$deps" > node_modules/.parity-deps
fi

# A workspace package, linked the way pnpm links one: the theme of that name
# imports it by name, and both linters have to see past the link.
mkdir -p node_modules
ln -sfn ../workspace_kit node_modules/parity-workspace-kit

# A design system installed as a package: a real directory under node_modules,
# so its tokens count only where both drivers' theme_imports name its import.
rm -rf node_modules/parity-installed-kit node_modules/parity-installed-bare node_modules/parity-plugin-kit
cp -R installed_kit node_modules/parity-installed-kit
cp -R installed_bare node_modules/parity-installed-bare
# A plugin and a config, which the plugin_modules theme loads the same way in both
# projects: by package, since its stylesheet sits at another depth in each.
cp -R plugin_kit node_modules/parity-plugin-kit

# The built package carries the Tailwind worker no-unknown-classes needs.
dist=shadcn-lint/packages/lint/dist
if [ "$(cat "$dist/.parity-commit" 2>/dev/null || true)" != "$commit" ] || [ ! -f "$dist/tailwind-worker.js" ]; then
  rm -rf "$dist"
  (cd shadcn-lint/packages/lint && NODE_PATH="$here/node_modules" "$here/node_modules/.bin/tsdown" >/dev/null)
  echo "$commit" > "$dist/.parity-commit"
fi

mkdir -p fixture/app known_gaps
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The default theme is the one HeexLint's test project uses.
(cd "$root" && OUT="$work/default.css" MIX_ENV=test mix run -e \
  'File.write!(System.fetch_env!("OUT"), HeexLint.TestProject.theme())')

status=0
gaps=0
checked=""

check() {
  local config="$1" name="$2" theme="$3" cases="$4" driver="${5:-driver}"
  local label="config $config, theme $name"
  local known="known_gaps/config$config-$name.txt"
  checked="$checked $known"

  export CONFIG="$config" THEME="$theme" CASES="$cases"

  # The reference must really ask Tailwind: every warning it prints says it
  # fell back to the bundled grammar, and then the comparison says nothing
  # about the project's theme.
  if ! npx tsx "$driver.ts" >/dev/null 2>"$work/stderr"; then
    echo "$label: $driver.ts failed" >&2
    cat "$work/stderr" >&2
    exit 1
  fi
  if grep -qF "[@shadcn/lint]" "$work/stderr"; then
    echo "$label: @shadcn/lint did not use Tailwind" >&2
    cat "$work/stderr" >&2
    exit 1
  fi

  (cd "$root" && MIX_ENV=test mix run "$here/$driver.exs" >/dev/null)
  unset CONFIG THEME CASES

  sort -o ref_out.tsv ref_out.tsv
  sort -o ours_out.tsv ours_out.tsv

  # A sorted list of differences: "<" only @shadcn/lint reports it, ">" only
  # HeexLint does.
  {
    comm -23 ref_out.tsv ours_out.tsv | awk '{ print "< " $0 }'
    comm -13 ref_out.tsv ours_out.tsv | awk '{ print "> " $0 }'
  } | sort > "$work/actual"

  local count findings
  count="$(wc -l < "$work/actual" | tr -d ' ')"
  findings="$(wc -l < ref_out.tsv | tr -d ' ')"
  gaps=$((gaps + count))

  if [ "$update" = 1 ]; then
    cp "$work/actual" "$known"
    echo "$label: $findings findings upstream, wrote $count known gaps"
    return
  fi

  local expected="$known"
  [ -f "$known" ] || expected=/dev/null
  comm -13 "$expected" "$work/actual" > "$work/new"
  comm -23 "$expected" "$work/actual" > "$work/stale"

  if [ -s "$work/new" ] || [ -s "$work/stale" ]; then
    status=1
    echo "$label: FAILED ($findings findings upstream, $count differences)"
    if [ -s "$work/new" ]; then
      echo "  new differences, not in $known:"
      sed 's/^/    /' "$work/new"
    fi
    if [ -s "$work/stale" ]; then
      echo "  stale entries in $known, no longer different:"
      sed 's/^/    /' "$work/stale"
    fi
  else
    echo "$label: ok ($findings findings upstream, $count known gaps)"
  fi
}

for config in $configs; do
  check "$config" default "$work/default.css" "$here/cases.txt"
  for theme in $themes; do
    check "$config" "$theme" "$here/themes/$theme.css" "$here/themed_cases.txt"
  done
done

# no-inline-styles reads style values rather than classes, so it has its own
# cases and drivers, and no theme or Tailwind.
check style cases "" "$here/style_cases.txt" style_driver

# A gap file no run wrote belongs to a config or theme that is gone.
for file in known_gaps/*.txt; do
  case " $checked " in
    *" $file "*) ;;
    *)
      if [ "$update" = 1 ]; then
        rm "$file"
        echo "removed $file: no config or theme uses it"
      else
        status=1
        echo "stale file $file: no config or theme uses it"
      fi
      ;;
  esac
done

if [ "$update" = 1 ]; then
  echo "known_gaps/ updated: $gaps known gaps"
elif [ "$status" = 0 ]; then
  echo "parity ok against $commit: $gaps known gaps"
else
  echo "parity FAILED against $commit. If a difference is accepted, or a gap was closed, run scripts/parity/run.sh --update and commit known_gaps/."
fi

exit $status
