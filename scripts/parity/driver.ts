// Lints a generated page with @shadcn/lint's own rules and prints one
// normalized line per finding: class, element kind, rule, message.
//
// CONFIG picks the rule options, THEME the CSS file used as the project's
// theme (the fixture's current one if unset), CASES the class list
// (cases.txt if unset).
import * as fs from "node:fs"
import * as path from "node:path"
import { Linter } from "eslint"
import parser from "@typescript-eslint/parser"
// The built package, whose Tailwind worker no-unknown-classes needs.
import { plugin } from "./shadcn-lint/packages/lint/dist/index.js"

const fixture = path.resolve(__dirname, "fixture")
const cases = fs
  .readFileSync(process.env.CASES ?? path.join(__dirname, "cases.txt"), "utf8")
  .split("\n")
  .filter(Boolean)
const themeFile = path.join(fixture, "app/globals.css")
fs.mkdirSync(path.dirname(themeFile), { recursive: true })
if (process.env.THEME) fs.copyFileSync(process.env.THEME, themeFile)
const kinds = ["div", "Button", "CardTitle"]
const header = [
  `import { Button } from "@/components/ui/button"`,
  `import { CardTitle } from "@/components/ui/card"`,
  `export function Page() {`,
  `  return (`,
  `    <>`,
]
const lines = [...header]
const where: Record<number, [string, string]> = {}
cases.forEach((token) => {
  kinds.forEach((kind) => {
    where[lines.length + 1] = [token, kind]
    lines.push(
      kind === "div"
        ? `      <div className="${token}" />`
        : `      <${kind} className="${token}">x</${kind}>`
    )
  })
})
lines.push(`    </>`, `  )`, `}`)
const page = path.join(fixture, "app/page.tsx")
fs.writeFileSync(page, lines.join("\n") + "\n")

const linter = new Linter({ configType: "flat" })
const config: any = [
  {
    files: ["**/*.tsx"],
    languageOptions: { parser, parserOptions: { ecmaFeatures: { jsx: true } } },
    plugins: { shadcn: plugin },
    rules:
      process.env.CONFIG === "3"
        ? {
            "shadcn/no-unknown-classes": "error",
            "shadcn/no-raw-colors": "error",
          }
        : process.env.CONFIG === "2"
        ? {
            "shadcn/no-restyle": [
              "error",
              {
                allow: ["layout"],
                deny: ["w-*"],
                message: { spacing: "S {{className}} {{sizes|nosize}} {{around}}" },
                contracts: [
                  {
                    pattern: "^CardTitle$",
                    allow: ["layout", "typography"],
                    deny: ["font-*"],
                    message: { color: "C {{className}} on {{component}}: {{variants|none}} {{entries}}" },
                  },
                ],
              },
            ],
            "shadcn/no-raw-colors": [
              "error",
              {
                allow: ["*-amber-*", "*-lime-*"],
                deny: ["bg-amber-500"],
                message: "RC {{className}} [{{suggestions|-}}] ({{tokens}}) {{file}}",
                contracts: [{ pattern: "^Button$", allow: ["*-red-*"] }],
              },
            ],
            "shadcn/no-arbitrary-values": [
              "error",
              {
                allow: ["layout", "p-[13px]", "rounded"],
                message: "AV {{className}} [{{suggestions|none}}] <{{replacement}}>",
              },
            ],
          }
        : {
            "shadcn/no-restyle": ["error", { allow: ["layout"] }],
            "shadcn/no-raw-colors": "error",
            "shadcn/no-arbitrary-values": ["error", { allow: ["layout"] }],
          },
  },
]
const messages = linter.verify(fs.readFileSync(page, "utf8"), config, { filename: page })
const out: string[] = []
for (const m of messages) {
  const at = where[m.line]
  if (!at) {
    out.push(`?\t?\t${m.ruleId}\t${m.message}`)
    continue
  }
  const rule = (m.ruleId ?? "").replace("shadcn/", "").replace(/-/g, "_")
  const message = m.message
    .replace(/(?:fixture\/)?components\/ui\/\w+\.tsx/g, "FILE")
    .replace(/(?:fixture\/)?app\/globals\.css/g, "THEME")
  out.push(`${at[0]}\t${at[1]}\t${rule}\t${message}`)
}
fs.writeFileSync(path.join(__dirname, "ref_out.tsv"), out.map((line) => line + "\n").join(""))
console.log(messages.length, "findings")
