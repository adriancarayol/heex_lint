// Lints style_cases.txt with @shadcn/lint's own no-inline-styles and prints one
// normalized line per distinct message: case, rule, message. Where a finding is
// differs between the languages, since upstream reports at the attribute.
import * as fs from "node:fs"
import * as path from "node:path"
import { Linter } from "eslint"
import parser from "@typescript-eslint/parser"
import { plugin } from "./shadcn-lint/packages/lint/dist/index.js"

const lines = fs
  .readFileSync(process.env.CASES ?? path.join(__dirname, "style_cases.txt"), "utf8")
  .split("\n")
  .filter((line) => line && !line.startsWith("#"))

const out = new Set<string>()
for (const line of lines) {
  const [name, names, source] = line.split("\t")
  const options =
    names === "-" ? [] : [{ allowDynamicIdentifiers: names ? names.split(",") : [] }]
  const linter = new Linter({ configType: "flat" })
  const messages = linter.verify(
    source,
    [
      {
        files: ["**/*.tsx"],
        languageOptions: { parser, parserOptions: { ecmaFeatures: { jsx: true } } },
        plugins: { shadcn: plugin },
        rules: { "shadcn/no-inline-styles": ["error", ...options] },
      },
    ] as any,
    { filename: "page.tsx" }
  )
  if (messages.some((m) => m.fatal)) throw new Error(`${name}: ${messages[0].message}`)
  for (const m of messages) {
    out.add(`${name}\tno_inline_styles\t${m.message}`)
  }
}
fs.writeFileSync(path.join(__dirname, "ref_out.tsv"), [...out].map((line) => line + "\n").join(""))
console.log(out.size, "findings")
