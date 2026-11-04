// Classifies Tailwind's own class list with @shadcn/lint's grammar and prints one
// line per name: class, group, category. Every class comes with each modifier
// Tailwind lists for it and behind `hover:`, and every variant goes in front of a
// sample of the classes. grammar_driver.exs classifies the same names.
import * as fs from "node:fs"
import * as path from "node:path"
import { __unstable__loadDesignSystem } from "tailwindcss"
import { categoryOf } from "./shadcn-lint/packages/lint/src/grammar/categories"
import { groupOf } from "./shadcn-lint/packages/lint/src/grammar/classifier"

async function main() {
  const css = fs.readFileSync(path.join(__dirname, "node_modules/tailwindcss/index.css"), "utf8")
  const system = await __unstable__loadDesignSystem(css, { base: __dirname })
  const list = system.getClassList() as [string, { modifiers?: string[] }][]

  const names = new Set<string>()
  for (const [name, { modifiers }] of list) {
    names.add(name)
    names.add(`hover:${name}`)
    for (const modifier of modifiers ?? []) names.add(`${name}/${modifier}`)
  }
  for (const variant of system.getVariants()) {
    if (!variant.selectors) continue
    const written = [variant.name, ...(variant.values ?? []).map((v: string) => `${variant.name}-${v}`)]
    for (const prefix of written) {
      for (let i = 0; i < list.length; i += 97) names.add(`${prefix}:${list[i][0]}`)
    }
  }

  const lines = [...names].map((name) => {
    const group = groupOf(name) ?? null
    return `${name}\t${group ?? "-"}\t${(group && categoryOf(group)) ?? "-"}\n`
  })
  fs.writeFileSync(path.join(__dirname, "ref_out.tsv"), lines.join(""))
  console.log(lines.length, "names")
}

main()
