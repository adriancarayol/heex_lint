#!/usr/bin/env bash
# Lints the same classes with @shadcn/lint's own rules and with HeexLint,
# on equivalent React and HEEx projects, and diffs the findings.
#
#   scripts/parity/run.sh
#
# Needs git, node and npm. Clones @shadcn/lint at a pinned commit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
commit="a89d047"

cd "$here"
if [ ! -d shadcn-lint ]; then
  git clone -q https://github.com/shadcn-ui/lint.git shadcn-lint
fi
git -C shadcn-lint checkout -q "$commit"

if [ ! -d node_modules ]; then
  npm init -y >/dev/null
  npm i -q -D cn@0.3.2 @eslint/core@0.17.0 eslint@9 @typescript-eslint/parser@8 typescript tsx@4 >/dev/null
fi

# The React fixture uses the same theme as HeexLint's test project.
(cd "$root" && OUT="$here/fixture/app/globals.css" MIX_ENV=test mix run -e \
  'File.write!(System.fetch_env!("OUT"), HeexLint.TestProject.theme())')

status=0
for config in 1 2; do
  CONFIG=$config npx tsx driver.ts 2>/dev/null
  sed -i 's|fixture/FILE|FILE|g; s|fixture/THEME|THEME|g' ref_out.tsv
  (cd "$root" && CONFIG=$config MIX_ENV=test mix run "$here/driver.exs")
  sort -o ref_out.tsv ref_out.tsv
  sort -o ours_out.tsv ours_out.tsv

  if diff -q ref_out.tsv ours_out.tsv >/dev/null; then
    echo "config $config: $(wc -l < ref_out.tsv) findings, identical"
  else
    echo "config $config: differences"
    diff ref_out.tsv ours_out.tsv | head -40
    status=1
  fi
done

exit $status
