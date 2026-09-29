// Asks the project's own Tailwind whether a class generates CSS, from a
// design system built the way Tailwind builds it, imports and plugins
// included. Ported from @shadcn/lint's src/tailwind/oracle.ts (MIT).
//
// Protocol: one JSON request per stdin line,
//   {"id": 1, "css": "/abs/app.css", "candidates": ["flex", "hovr:flex"]}
// answered by one JSON line on stdout,
//   {"id": 1, "ok": true, "unknown": [{"token", "suggestion", "baseKnown"}]}
// or {"id": 1, "ok": false, "reason": "..."}.

import * as fs from "node:fs"
import { createRequire } from "node:module"
import * as path from "node:path"
import * as readline from "node:readline"
import { pathToFileURL } from "node:url"

const loaded = new Map()

// Brackets and parens keep their inner colons.
function splitVariants(token) {
  if (!token.includes(":")) return { variants: [], base: token }
  const segments = []
  let bracketDepth = 0
  let parenDepth = 0
  let current = ""
  for (const char of token) {
    if (char === "[") bracketDepth++
    else if (char === "]") bracketDepth--
    else if (bracketDepth === 0) {
      if (char === "(") parenDepth++
      else if (char === ")") parenDepth--
    }
    if (char === ":" && bracketDepth === 0 && parenDepth === 0) {
      segments.push(current)
      current = ""
      continue
    }
    current += char
  }
  segments.push(current)
  return { variants: segments.slice(0, -1), base: segments[segments.length - 1] }
}

function editDistance(a, b) {
  const rows = a.length + 1
  const cols = b.length + 1
  const d = Array.from({ length: rows }, (_, i) => {
    const row = new Array(cols).fill(0)
    row[0] = i
    return row
  })
  for (let j = 0; j < cols; j++) d[0][j] = j
  for (let i = 1; i < rows; i++) {
    for (let j = 1; j < cols; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1)
      }
    }
  }
  return d[rows - 1][cols - 1]
}

function didYouMean(value, candidates, budget = value.length < 6 ? 1 : 2) {
  if (value.length < 3) return null
  let best = null
  for (const name of candidates) {
    if (name === value) return null
    if (Math.abs(name.length - value.length) > budget) continue
    const distance = editDistance(value, name)
    if (distance > budget) continue
    if (!best || distance < best.distance || (distance === best.distance && name.localeCompare(best.name) < 0)) {
      best = { name, distance }
    }
  }
  return best?.name ?? null
}

function existingFile(candidate) {
  try {
    return fs.statSync(candidate).isFile() ? candidate : null
  } catch {
    return null
  }
}

function stylesheetAt(dir, name) {
  const base = path.join(dir, name)
  return existingFile(base) ?? existingFile(`${base}.css`) ?? existingFile(path.join(base, "index.css"))
}

function styleTarget(entry) {
  if (typeof entry === "string") return entry
  if (!entry || typeof entry !== "object") return null
  for (const key of ["style", "default"]) {
    const target = styleTarget(entry[key])
    if (target) return target
  }
  return null
}

function packageDirectory(base, name) {
  let dir = base
  for (let depth = 0; depth < 32; depth++) {
    const candidate = path.join(dir, "node_modules", name)
    if (existingFile(path.join(candidate, "package.json"))) return candidate
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

function resolveStylesheet(base, id) {
  if (id === "tailwindcss") return resolveStylesheet(base, "tailwindcss/index.css")
  if (id.startsWith(".") || path.isAbsolute(id)) {
    return stylesheetAt(path.dirname(path.resolve(base, id)), path.basename(id))
  }
  const match = id.match(/^(@[^/]+\/[^/]+|[^/]+)(?:\/(.*))?$/)
  if (!match) return null
  const [, name, subpath] = match
  const pkgDir = packageDirectory(base, name)
  if (!pkgDir) return null
  let pkg = {}
  try {
    pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf-8"))
  } catch {}
  const exports = pkg.exports
  if (subpath) {
    const target = exports && typeof exports === "object" ? styleTarget(exports[`./${subpath}`]) : null
    if (target) return existingFile(path.join(pkgDir, target))
    return stylesheetAt(path.dirname(path.join(pkgDir, subpath)), path.basename(subpath))
  }
  const root =
    typeof exports === "string" ? exports : exports && typeof exports === "object" ? styleTarget(exports["."] ?? exports) : null
  for (const target of [root, pkg.style, pkg.main]) {
    if (typeof target !== "string") continue
    const file = existingFile(path.join(pkgDir, target))
    if (file) return file
  }
  return stylesheetAt(pkgDir, "index")
}

// Prefer @tailwindcss/node, which loads plugins the way Tailwind's own
// CLI and Vite plugin do (CommonJS and ESM alike); fall back to
// tailwindcss with our own loaders.
async function loadDesignSystem(cssFile) {
  const dir = path.dirname(cssFile)
  const css = fs.readFileSync(cssFile, "utf-8")
  for (const from of [dir, process.cwd()]) {
    const require = createRequire(path.join(from, "noop.js"))
    let node = null
    try {
      node = require(require.resolve("@tailwindcss/node"))
    } catch {}
    if (node && typeof node.__unstable__loadDesignSystem === "function") {
      return node.__unstable__loadDesignSystem(css, { base: dir })
    }
    let resolved = null
    try {
      resolved = require.resolve("tailwindcss")
    } catch {
      continue
    }
    const mod = await import(pathToFileURL(resolved).href)
    const api = typeof mod.__unstable__loadDesignSystem === "function" ? mod : mod.default
    if (!api || typeof api.__unstable__loadDesignSystem !== "function") {
      throw new Error(`${resolved} is not Tailwind v4 (no __unstable__loadDesignSystem)`)
    }
    return api.__unstable__loadDesignSystem(css, {
      base: dir,
      async loadStylesheet(id, base) {
        if (/^(?:https?:|data:)/.test(id)) return { base, content: "" }
        const file = resolveStylesheet(base, id)
        if (!file) throw new Error(`@import "${id}" could not be resolved from ${base}`)
        return { base: path.dirname(file), content: fs.readFileSync(file, "utf-8") }
      },
      async loadModule(id, base) {
        const file = createRequire(path.join(base, "noop.js")).resolve(id)
        const loadedModule = await import(pathToFileURL(file).href)
        return { base: path.dirname(file), module: loadedModule.default ?? loadedModule }
      },
    })
  }
  throw new Error(`tailwindcss v4 could not be resolved from ${dir}`)
}

async function systemFor(cssFile) {
  let system = loaded.get(cssFile)
  if (!system) {
    const ds = await loadDesignSystem(cssFile)
    const variants = ds.getVariants()
    system = {
      ds,
      prefix: ds.theme?.prefix ?? null,
      classNames: null,
      staticVariants: variants.filter((v) => !v.isArbitrary && !v.values.length).map((v) => v.name),
      functionalVariants: variants.filter((v) => v.isArbitrary || v.values.length).map((v) => v.name),
    }
    loaded.set(cssFile, system)
  }
  return system
}

function classNamesOf(system) {
  system.classNames ??= system.ds.getClassList().map((entry) => (Array.isArray(entry) ? entry[0] : entry))
  return system.classNames
}

function variantKnown(system, variant) {
  const name = variant.replace(/\/.*$/, "")
  if (name.startsWith("[") || name.startsWith("@")) return true
  if (system.staticVariants.includes(name)) return true
  return system.functionalVariants.some((prefix) => name === prefix || name.startsWith(`${prefix}-`))
}

// A base utility that exists on its own means the variant is misspelled;
// otherwise the utility is, matched against every class Tailwind knows.
function suggestionFor(system, candidate) {
  const { variants, base } = splitVariants(candidate)
  const prefixed = system.prefix !== null && variants[0] === system.prefix
  const probe = prefixed ? `${system.prefix}:${base}` : base
  if (variants.length && system.ds.candidatesToCss([probe])[0] !== null) {
    let changed = false
    const fixed = variants.map((variant, i) => {
      if (prefixed && i === 0) return variant
      if (variantKnown(system, variant)) return variant
      const meant = didYouMean(variant, system.staticVariants, 1)
      if (!meant) return variant
      changed = true
      return meant
    })
    return changed ? [...fixed, base].join(":") : null
  }
  const bare = base.replace(/^!/, "").replace(/!$/, "").replace(/^-/, "")
  const meant = didYouMean(bare, classNamesOf(system))
  if (!meant) return null
  return [...variants, base.replace(bare, meant)].join(":")
}

function baseKnownOf(system, candidate) {
  const { variants, base } = splitVariants(candidate)
  if (!variants.length) return false
  const bare = system.prefix && variants[0] === system.prefix ? `${system.prefix}:${base}` : base
  if (variants.length === (bare === base ? 0 : 1)) return false
  return system.ds.candidatesToCss([bare])[0] !== null
}

async function query(cssFile, candidates) {
  let system
  try {
    system = await systemFor(cssFile)
  } catch (error) {
    return { ok: false, reason: error.message }
  }
  const css = system.ds.candidatesToCss(candidates)
  const unknown = []
  for (let i = 0; i < candidates.length; i++) {
    if (css[i] !== null) continue
    unknown.push({
      token: candidates[i],
      suggestion: suggestionFor(system, candidates[i]),
      baseKnown: baseKnownOf(system, candidates[i]),
    })
  }
  return { ok: true, unknown }
}

const lines = readline.createInterface({ input: process.stdin })
let queue = Promise.resolve()

lines.on("line", (line) => {
  queue = queue.then(async () => {
    let request
    try {
      request = JSON.parse(line)
    } catch {
      return
    }
    let answer
    try {
      answer = await query(request.css, request.candidates)
    } catch (error) {
      answer = { ok: false, reason: error.message }
    }
    process.stdout.write(JSON.stringify({ id: request.id, ...answer }) + "\n")
  })
})
