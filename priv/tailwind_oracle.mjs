// Asks the project's own Tailwind whether a class generates CSS, from a
// design system built the way Tailwind builds it, imports and plugins
// included. Ported from @shadcn/lint's src/tailwind/oracle.ts (MIT).
//
// Protocol: one JSON request per stdin line,
//   {"id": 1, "css": "/abs/app.css", "candidates": ["flex", "hovr:flex"]}
// answered by one JSON line on stdout,
//   {"id": 1, "ok": true, "unknown": [{"token", "suggestion", "baseKnown"}], "fontSizes": ["text-sm"]}
// or {"id": 1, "ok": false, "reason": "...", "final": false, "absent": false}, where
// `final` says the standalone binary would do no better, and `absent` that nothing
// named tailwindcss was anywhere this looked, so no theme failed to build.
//
// Two threads. Tailwind and the project's plugins run in a worker thread, where
// they can spin for as long as they like. This file's main thread only passes
// lines along and watches stdin, so it is free to end the process the moment
// the linter is gone, whatever the work is doing.

import * as fs from "node:fs"
import { createRequire } from "node:module"
import * as path from "node:path"
import * as readline from "node:readline"
import { pathToFileURL } from "node:url"
import { isMainThread, parentPort, Worker } from "node:worker_threads"

const FONT_SIZE = /(?:^|[;{\s])font-size\s*:/

// Far past any real class. Tailwind parses a candidate recursively, once per
// variant, and slows quadratically on a long value, so one hostile token could
// stall the worker or overflow its stack. A class past either limit is not
// judged, the way an arbitrary property is not.
const MAX_CANDIDATE_LENGTH = 10_000
const MAX_VARIANTS = 64

// Far past any real theme, and not in @shadcn/lint. Tailwind expands an @import
// again wherever it is reached and stops a chain only at depth 100, so a cycle
// with fan-out is 2^100 reads. Nothing would end them but the linter's deadline.
const MAX_STYLESHEET_READS = 10_000

const MAX_CONDITION_DEPTH = 32

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

function resolveFrom(base, id) {
  return createRequire(path.join(base, "noop.js")).resolve(id)
}

// Comments go first: a partial whose comment spells out the consumer's
// `@import "tailwindcss"` does not import Tailwind.
function stripComments(css) {
  const parts = []
  let start = 0
  let i = 0
  while (i < css.length) {
    const char = css[i]
    if (char === "/" && css[i + 1] === "*") {
      parts.push(css.slice(start, i))
      const end = css.indexOf("*/", i + 2)
      i = end === -1 ? css.length : end + 2
      start = i
    } else if (char === '"' || char === "'") {
      i++
      while (i < css.length && css[i] !== char) i += css[i] === "\\" ? 2 : 1
      i++
    } else if (css.startsWith("url(", i)) {
      const end = css.indexOf(")", i + 4)
      i = end === -1 ? css.length : end + 1
    } else {
      i++
    }
  }
  parts.push(css.slice(start))
  return parts.join("")
}

function parseImports(css) {
  const out = []
  const text = stripComments(css)
  const re = /@import\s+(?:url\(\s*)?["']([^"']+)["']/g
  for (let match = re.exec(text); match; match = re.exec(text)) {
    const end = text.indexOf(";", re.lastIndex)
    // No `;` ends this @import, so none ends a later one either.
    if (end === -1) break
    out.push(match[1])
    re.lastIndex = end + 1
  }
  return out
}

// The directories of the stylesheets that import Tailwind, reached through the
// entry's @imports. In a workspace or an umbrella the app's stylesheet may import
// a UI package's, and only that package depends on Tailwind.
function* tailwindImporters(cssFile) {
  const seen = new Set()
  const queue = [cssFile]
  while (queue.length) {
    const file = queue.shift()
    if (seen.has(file)) continue
    seen.add(file)
    let css
    try {
      css = fs.readFileSync(file, "utf-8")
    } catch {
      continue
    }
    for (const id of parseImports(css)) {
      if (id === "tailwindcss" || id.startsWith("tailwindcss/")) {
        yield path.dirname(file)
        continue
      }
      const resolved = resolveImport(path.dirname(file), id)
      if (resolved) queue.push(realpathOf(resolved))
    }
  }
}

function* tailwindBases(cssFile) {
  yield path.dirname(cssFile)
  yield* tailwindImporters(cssFile)
  yield process.cwd()
}

// Resolved from the stylesheet outward: ours is not a substitute for the version
// that actually generates the project's CSS.
async function loadTailwind(cssFile) {
  for (const from of tailwindBases(cssFile)) {
    let resolved
    try {
      resolved = resolveFrom(from, "tailwindcss")
    } catch {
      continue
    }
    // Tailwind's entry is CommonJS: its API may sit on `default`.
    const mod = await import(pathToFileURL(resolved).href)
    const api =
      typeof mod.__unstable__loadDesignSystem === "function"
        ? mod
        : typeof mod.default?.__unstable__loadDesignSystem === "function"
          ? mod.default
          : null
    if (api) return { api, resolved }
    throw new Error(`${resolved} is not Tailwind v4 (no __unstable__loadDesignSystem)`)
  }
  return null
}

// The loader the CLI, Vite and PostCSS plugins use for @config and @plugin. Its
// jiti takes what native import() refuses: extensionless relative imports and
// TypeScript beyond type stripping. Installed beside whichever of them the
// project uses, so it is looked for where Tailwind was found and in the directory
// Tailwind really lives in.
async function loadNodeLoader(cssFile, tailwind) {
  const bases = [...tailwindBases(cssFile), path.dirname(realpathOf(tailwind))]
  for (const from of bases) {
    let resolved
    try {
      resolved = resolveFrom(from, "@tailwindcss/node")
    } catch {
      continue
    }
    try {
      const mod = await import(pathToFileURL(resolved).href)
      const loader = mod.loadModule ?? mod.default?.loadModule
      if (typeof loader === "function") return loader
    } catch {
      // A broken install falls back to native import().
    }
  }
  return null
}

// Without @tailwindcss/node, Node's own import().
async function importModule(id, base) {
  const resolved = resolveFrom(base, id)
  const mod = await import(pathToFileURL(resolved).href)
  return { path: resolved, base: path.dirname(resolved), module: mod.default ?? mod }
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

function isInside(dir, file) {
  const relative = path.relative(dir, file)
  return relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative)
}

// A UNC path reaches the network on Windows: stat one and the OS sends the user's
// credentials to whatever host it names.
function isStrayUncPath(file, ...within) {
  return /^[\\/]{2}/.test(file) && !within.some((dir) => isInside(dir, file))
}

const BAD_SEGMENT = /^(?:\.|%2e){1,2}$|^node_modules$/i

// What Node refuses in a target or a `*` capture: walking up, reaching into
// node_modules, and percent-encoded separators.
function safeSegments(text) {
  return !/%2f|%5c/i.test(text) && !text.split(/[\\/]/).some((segment) => BAD_SEGMENT.test(segment))
}

function isPackageTarget(target) {
  return target.startsWith("./") && safeSegments(target.slice(2))
}

// The file a target names, expanded with its `*` capture, or null when either
// would leave the package. Node treats that as no match.
function packageTarget(dir, target, captured = "") {
  if (!isPackageTarget(target) || !safeSegments(captured)) return null
  const file = path.resolve(dir, target.replace("*", captured))
  return isInside(dir, file) ? file : null
}

// Only a target Node accepts: one that would leave the package falls through to
// the next condition.
function styleTarget(entry, depth = 0) {
  if (typeof entry === "string") return isPackageTarget(entry) ? entry : null
  if (!entry || typeof entry !== "object") return null
  if (depth >= MAX_CONDITION_DEPTH) return null
  for (const key of ["style", "default"]) {
    const target = styleTarget(entry[key], depth + 1)
    if (target) return target
  }
  return null
}

// The exports entry for a subpath: the exact key, else the longest pattern key
// whose `*` matches, expanded the way Node expands it, so `"./*.css":
// "./dist/*.css"` serves `demo-widgets/styles.css`.
function exportedStyle(pkgDir, exports, subpath) {
  const exact = styleTarget(exports[`./${subpath}`])
  if (exact) return packageTarget(pkgDir, exact)
  const patterns = Object.keys(exports)
    .filter((key) => key.startsWith("./") && key.includes("*"))
    .sort((a, b) => b.length - a.length)
  for (const key of patterns) {
    const star = key.indexOf("*")
    const prefix = key.slice(2, star)
    const suffix = key.slice(star + 1)
    if (subpath.length < prefix.length + suffix.length || !subpath.startsWith(prefix) || !subpath.endsWith(suffix)) {
      continue
    }
    const target = styleTarget(exports[key])
    if (!target) continue
    const file = packageTarget(pkgDir, target, subpath.slice(prefix.length, subpath.length - suffix.length))
    if (file) return file
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

// Resolves an @import the way Tailwind's bundler does. Node's own resolver cannot:
// tw-animate-css exports only a style condition.
function resolveStylesheet(base, id) {
  if (id === "tailwindcss") return resolveStylesheet(base, "tailwindcss/index.css")
  if (id.startsWith(".") || path.isAbsolute(id)) {
    const file = path.resolve(base, id)
    if (isStrayUncPath(id, base) || isStrayUncPath(file, base)) return null
    return stylesheetAt(path.dirname(file), path.basename(id))
  }
  const match = id.match(/^(@[^/]+\/[^/]+|[^/]+)(?:\/(.*))?$/)
  if (!match) return null
  const [, name, subpath] = match
  const pkgDir = packageDirectory(base, name)
  if (!pkgDir) return null
  let pkg = {}
  try {
    pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf-8"))
  } catch {
    // A package without a readable manifest still has files.
  }
  const exports = pkg.exports
  if (subpath) {
    const target = exports && typeof exports === "object" ? exportedStyle(pkgDir, exports, subpath) : null
    if (target) return existingFile(target)
    const file = path.join(pkgDir, subpath)
    if (!isInside(pkgDir, file)) return null
    return stylesheetAt(path.dirname(file), path.basename(subpath))
  }
  const root =
    typeof exports === "string"
      ? exports
      : exports && typeof exports === "object"
        ? styleTarget(exports["."] ?? exports)
        : null
  const rootFile = root ? packageTarget(pkgDir, root) : null
  if (rootFile && existingFile(rootFile)) return rootFile
  for (const target of [pkg.style, pkg.main]) {
    if (typeof target !== "string") continue
    const joined = path.join(pkgDir, target)
    if (!isInside(pkgDir, joined)) continue
    const file = existingFile(joined)
    if (file) return file
  }
  return stylesheetAt(pkgDir, "index")
}

function readManifest(dir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf-8"))
  } catch {
    return null
  }
}

function findUp(from, name) {
  let dir = from
  for (let depth = 0; depth < 32; depth++) {
    const candidate = path.join(dir, name)
    if (fs.existsSync(candidate)) return candidate
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

const PREFERRED_CONDITIONS = ["import", "default", "require", "node", "types"]

// The first target `valid` accepts, so an invalid one falls through to the next.
function pickTarget(value, valid, depth = 0) {
  if (typeof value === "string") return valid(value) ? value : null
  if (depth >= MAX_CONDITION_DEPTH) return null
  if (Array.isArray(value)) {
    for (const item of value) {
      const picked = pickTarget(item, valid, depth + 1)
      if (picked) return picked
    }
    return null
  }
  if (value && typeof value === "object") {
    for (const key of PREFERRED_CONDITIONS) {
      if (key in value) {
        const picked = pickTarget(value[key], valid, depth + 1)
        if (picked) return picked
      }
    }
    for (const key of Object.keys(value)) {
      if (key.startsWith(".") || PREFERRED_CONDITIONS.includes(key)) continue
      const picked = pickTarget(value[key], valid, depth + 1)
      if (picked) return picked
    }
  }
  return null
}

// The text `*` captured, "" for an exact match, or null.
function matchPattern(pattern, value) {
  const star = pattern.indexOf("*")
  if (star === -1) return pattern === value ? "" : null
  const prefix = pattern.slice(0, star)
  const suffix = pattern.slice(star + 1)
  if (value.length < prefix.length + suffix.length || !value.startsWith(prefix) || !value.endsWith(suffix)) {
    return null
  }
  return value.slice(prefix.length, value.length - suffix.length)
}

// Through an exports/imports map, longest key first: files inside `dir`, or with
// `bare`, package specifiers an imports map points at.
function mapSubpath(map, subpath, dir, bare = false) {
  const keys = Object.keys(map)
    .filter((key) => key.startsWith(".") || key.startsWith("#"))
    .sort((a, b) => b.length - a.length)
  const out = []
  for (const key of keys) {
    const captured = matchPattern(key, subpath)
    if (captured === null || !safeSegments(captured)) continue
    const target = pickTarget(map[key], (t) => isPackageTarget(t) || (bare && /^[^./\\#][^:\\]*$/.test(t)))
    if (!target) continue
    if (!target.startsWith("./")) {
      out.push({ spec: target.replace("*", captured) })
      continue
    }
    const file = packageTarget(dir, target, captured)
    if (file) out.push({ file })
  }
  return out
}

function packageCandidates(spec, rootDir, out, fromDir = rootDir) {
  const parts = spec.split("/")
  const nameLength = spec.startsWith("@") ? 2 : 1
  if (parts.length < nameLength) return
  const name = parts.slice(0, nameLength).join("/")
  const rest = parts.slice(nameLength).join("/")
  const self = (from) => {
    const manifest = findUp(from, "package.json")
    if (!manifest) return null
    const dir = path.dirname(manifest)
    return readManifest(dir)?.name === name ? realpathOf(dir) : null
  }
  const installed = (from) => {
    const found = findUp(from, path.join("node_modules", name))
    return found ? realpathOf(found) : null
  }
  const dir = self(rootDir) ?? self(fromDir) ?? installed(rootDir) ?? installed(fromDir)
  if (!dir) return
  const subpath = rest ? `./${rest}` : "."
  const exportsMap = readManifest(dir)?.exports
  if (exportsMap && typeof exportsMap === "object") {
    for (const target of mapSubpath(exportsMap, subpath, dir)) {
      if (target.file) out.push(target.file)
    }
    // A directory alias against a wildcard key ("./components/*").
    for (const target of mapSubpath(exportsMap, `${subpath}/*`, dir)) {
      if (target.file) out.push(path.dirname(target.file))
    }
  }
  // The package's own files, never a path that walks out of it.
  const own = rest ? [path.join(dir, rest), path.join(dir, "src", rest)] : [dir, path.join(dir, "src")]
  for (const file of own) {
    if (isInside(dir, file)) out.push(file)
  }
}

// nodenext and bundler resolution import "./button.js" for button.ts.
const SOURCE_FOR_JS = { ".js": [".ts", ".tsx"], ".jsx": [".tsx"], ".mjs": [".mts", ".ts"], ".cjs": [".cts", ".ts"] }

// @shadcn/lint's resolveFile for a stylesheet: the theme read's way to a file,
// where the bundler's way above finds none, such as an `imports` map's #tokens.
// tsconfig paths and the @/ aliases are not followed, as HeexLint.Theme does not.
function resolveByManifest(id, fromDir, rootDir) {
  const out = []
  if (id.startsWith("./") || id.startsWith("../") || id === "." || id === "..") {
    out.push(path.resolve(fromDir, id))
  } else if (path.isAbsolute(id)) {
    out.push(id)
  } else if (id.startsWith("#")) {
    const imports = readManifest(rootDir)?.imports
    if (imports && typeof imports === "object") {
      for (const target of mapSubpath(imports, id, rootDir, true)) {
        if (target.file) out.push(target.file)
        else if (target.spec) packageCandidates(target.spec, rootDir, out)
      }
      for (const target of mapSubpath(imports, `${id}/*`, rootDir)) {
        if (target.file) out.push(path.dirname(target.file))
      }
    }
  } else {
    packageCandidates(id, rootDir, out, fromDir)
  }
  for (const candidate of out) {
    if (isStrayUncPath(candidate, rootDir, fromDir)) continue
    if (existingFile(candidate)) return candidate
    const ext = path.extname(candidate)
    for (const source of SOURCE_FOR_JS[ext] ?? []) {
      const swapped = existingFile(candidate.slice(0, -ext.length) + source)
      if (swapped) return swapped
    }
    const file = existingFile(`${candidate}.css`) ?? existingFile(path.join(candidate, "index.css"))
    if (file) return file
  }
  return null
}

function packageRoot(dir) {
  const manifest = findUp(dir, "package.json")
  return manifest ? path.dirname(manifest) : null
}

function resolveImport(base, id) {
  return resolveStylesheet(base, id) ?? resolveByManifest(id, base, packageRoot(base) ?? base)
}

// The real path of a file reached through a symlink: what its own imports resolve
// from.
function realpathOf(file) {
  try {
    return fs.realpathSync.native(file)
  } catch {
    return file
  }
}

async function build(cssFile) {
  const dir = path.dirname(cssFile)
  const tailwind = await loadTailwind(cssFile)
  if (!tailwind) {
    const error = new Error(`tailwindcss v4 could not be resolved from ${dir}`)
    error.absent = ![...tailwindBases(cssFile)].some((from) => findUp(from, path.join("node_modules", "tailwindcss")))
    throw error
  }
  let loader
  let reads = 0
  const ds = await tailwind.api.__unstable__loadDesignSystem(fs.readFileSync(cssFile, "utf-8"), {
    base: dir,
    async loadStylesheet(id, base) {
      if (/^(?:https?:|data:)/.test(id)) return { base, content: "" }
      if (++reads > MAX_STYLESHEET_READS) {
        const error = new Error(`its @imports reach more than ${MAX_STYLESHEET_READS} stylesheets, so they probably form a cycle`)
        // Tailwind's own CLI would read them as well, until something stopped it.
        error.final = true
        throw error
      }
      const resolved = resolveImport(base, id)
      // Refusing to judge beats judging against half a theme.
      if (!resolved) throw new Error(`@import "${id}" could not be resolved from ${base}`)
      // A pnpm-installed package is a link into node_modules/.pnpm and its own
      // dependencies sit beside the real file, so the base for the imports inside
      // it is the directory that file really lives in. Read in one call: open
      // files kept waiting are what a cycle with fan-out exhausts first.
      const file = realpathOf(resolved)
      return { base: path.dirname(file), content: fs.readFileSync(file, "utf-8") }
    },
    async loadModule(id, base) {
      if (loader === undefined) loader = await loadNodeLoader(cssFile, tailwind.resolved)
      const result = loader ? await loader(id, base, () => {}) : await importModule(id, base)
      return { base: result.base, module: result.module }
    },
  })
  const variants = ds.getVariants()
  return {
    ds,
    prefix: ds.theme?.prefix ?? null,
    classNames: null,
    staticVariants: variants.filter((v) => !v.isArbitrary && !v.values.length).map((v) => v.name),
    functionalVariants: variants.filter((v) => v.isArbitrary || v.values.length).map((v) => v.name),
  }
}

async function systemFor(cssFile) {
  let system = loaded.get(cssFile)
  if (!system) {
    system = await build(cssFile)
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

function checkable(candidate) {
  return candidate.length <= MAX_CANDIDATE_LENGTH && splitVariants(candidate).variants.length <= MAX_VARIANTS
}

// Undefined when Tailwind throws on this one candidate, from a plugin or its own
// parser: that costs the candidate its answer, not the theme.
function cssOf(system, candidate) {
  try {
    return system.ds.candidatesToCss([candidate])[0]
  } catch {
    return undefined
  }
}

function cssOfAll(system, candidates) {
  try {
    return system.ds.candidatesToCss(candidates)
  } catch {
    return candidates.map((candidate) => cssOf(system, candidate))
  }
}

// A base utility that exists on its own means the variant is misspelled;
// otherwise the utility is, matched against every class Tailwind knows.
function suggestionFor(system, candidate) {
  const { variants, base } = splitVariants(candidate)
  const prefixed = system.prefix !== null && variants[0] === system.prefix
  const probe = prefixed ? `${system.prefix}:${base}` : base
  if (variants.length && typeof cssOf(system, probe) === "string") {
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
  return typeof cssOf(system, bare) === "string"
}

function reasonOf(error) {
  return String(error?.message ?? error)
}

async function query(cssFile, candidates) {
  let system
  try {
    system = await systemFor(cssFile)
  } catch (error) {
    return { ok: false, reason: reasonOf(error), final: error?.final === true, absent: error?.absent === true }
  }
  const checked = candidates.filter(checkable)
  const css = cssOfAll(system, checked)
  const unknown = []
  // Known candidates that set a font size: text-body from an @config fontSize reads
  // as a color to a grammar that only knows the name.
  const fontSizes = []
  for (let i = 0; i < checked.length; i++) {
    if (css[i] === undefined) continue
    if (css[i] !== null) {
      if (FONT_SIZE.test(css[i])) fontSizes.push(checked[i])
      continue
    }
    unknown.push({
      token: checked[i],
      suggestion: suggestionFor(system, checked[i]),
      baseKnown: baseKnownOf(system, checked[i]),
    })
  }
  return { ok: true, unknown, fontSizes }
}

function answerRequests() {
  let queue = Promise.resolve()
  parentPort.on("message", (request) => {
    queue = queue.then(async () => {
      let answer
      try {
        answer = await query(request.css, request.candidates)
      } catch (error) {
        answer = { ok: false, reason: reasonOf(error) }
      }
      parentPort.postMessage({ id: request.id, ...answer })
    })
  })
}

// Now, with whatever the worker thread is doing. process.exit waits for the
// thread to stop, which code stuck in a native call may never do. The process
// leads its group when the linter starts it, which takes a plugin's own children
// along; otherwise there is no such group.
function endProcess() {
  try {
    process.kill(-process.pid, "SIGKILL")
  } catch {}
  process.kill(process.pid, "SIGKILL")
}

function relayRequests() {
  const waiting = new Set()
  let worker = null

  const answer = (message) => {
    waiting.delete(message.id)
    process.stdout.write(JSON.stringify(message) + "\n")
  }

  // A plugin can take the thread down: every question it held is unanswerable,
  // and the next one gets a new thread.
  const lost = (thread, reason) => {
    if (worker !== thread) return
    worker = null
    for (const id of [...waiting]) answer({ id, ok: false, reason })
  }

  const workerThread = () => {
    if (worker) return worker
    // Stdout is the protocol, and a plugin's console.log is no part of it.
    const thread = new Worker(new URL(import.meta.url), { stdout: true })
    thread.stdout.resume()
    thread.on("message", answer)
    thread.on("error", (error) => lost(thread, reasonOf(error)))
    thread.on("exit", (code) => lost(thread, `the Tailwind thread exited with code ${code}`))
    worker = thread
    return thread
  }

  const lines = readline.createInterface({ input: process.stdin })
  lines.on("line", (line) => {
    let request
    try {
      request = JSON.parse(line)
    } catch {
      return
    }
    waiting.add(request.id)
    workerThread().postMessage(request)
  })

  // The linter is gone. Nothing else ends a request in progress.
  lines.on("close", endProcess)
  process.stdin.on("error", endProcess)
  process.stdout.on("error", endProcess)
}

if (isMainThread) relayRequests()
else answerRequests()
