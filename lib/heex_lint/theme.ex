defmodule HeexLint.Theme do
  @moduledoc """
  What a project's Tailwind stylesheet declares: the `--color-*` tokens in
  `@theme`, the scales, and the classes its CSS defines.

  Ported from @shadcn/lint's `src/project/theme.ts` (MIT). Imports are
  followed past symlinks; files under `node_modules` contribute `@utility`
  names, class selectors and `--animate-*` theme names but not tokens, since
  Tailwind's own palette is not the project's vocabulary. A workspace package
  linked into `node_modules` really lives outside it, so it counts as the
  project's own, and so does a design system installed as a package once the
  `theme_imports` setting names its import. Dark-mode blocks are skipped, so
  values are the light theme's.

  `load/2` also applies the scales the stylesheets declare to cn's grammar,
  once per read, and `signature` tells two reads of an edited file apart.

  `prefix` is the `tw` of `@import "tailwindcss" prefix(tw)`, read like the
  tokens from the project's own files.

  `modules` says the stylesheets load an `@config` or `@plugin`, in any file: then
  JavaScript adds to the theme and only Tailwind can say what. `oracle` is how to
  ask, `{oracle, entry}`, for a theme in a run that has one and needs it.
  """

  @derive {Inspect, except: [:grammar]}

  alias HeexLint.Grammar.{Classes, Classifier, Colors, Lengths, TailwindTheme, ThemeScales, Trie}

  defstruct file: nil,
            tailwind: false,
            prefix: nil,
            modules: false,
            oracle: nil,
            tokens: MapSet.new(),
            scoped: %{},
            utilities: MapSet.new(),
            utility_properties: [],
            classes: MapSet.new(),
            values: %{},
            scoped_names: MapSet.new(),
            theme_names: MapSet.new(),
            declarations: [],
            variables: MapSet.new(),
            files: [],
            missing_imports: [],
            colors: %{},
            scales: %{},
            spacing: nil,
            grammar: nil,
            signature: nil

  @type declaration :: %{name: String.t(), value: String.t(), theme: boolean()}

  @typedoc "Steps in the order they were declared, which breaks ties between equal values."
  @type scale :: [{String.t(), float()}]

  @typedoc """
  Each `@utility`, with the CSS properties its body sets, in the order the
  utilities were read: the first prefix that matches a class answers for it.
  """
  @type utility_properties :: [{String.t(), [String.t()]}]

  @type t :: %__MODULE__{
          file: String.t() | nil,
          tailwind: boolean(),
          prefix: String.t() | nil,
          modules: boolean(),
          oracle: {pid(), String.t()} | nil,
          tokens: MapSet.t(String.t()),
          scoped: %{String.t() => MapSet.t(String.t())},
          utilities: MapSet.t(String.t()),
          utility_properties: utility_properties(),
          classes: MapSet.t(String.t()),
          values: %{String.t() => String.t()},
          scoped_names: MapSet.t(String.t()),
          theme_names: MapSet.t(String.t()),
          declarations: [declaration()],
          variables: MapSet.t(String.t()),
          files: [String.t()],
          missing_imports: [String.t()],
          colors: %{String.t() => Colors.lab()},
          scales: %{radius: scale(), text: scale()},
          spacing: float() | nil,
          grammar: Trie.t() | nil,
          signature: integer() | nil
        }

  # The namespaces Tailwind reads a color utility from before --color-*,
  # verified against Tailwind 4.3.3 by @shadcn/lint.
  @color_namespaces ~w(
    background-color text-color border-color divide-color ring-color outline-color
    accent-color caret-color placeholder-color text-decoration-color
    text-shadow-color drop-shadow-color fill stroke
  )

  @dark_prelude ~r/\.dark(?![\w-])|prefers-color-scheme\s*:\s*dark|data-(?:theme|mode)=["']?dark|@variant\s+dark\b/

  # An @import up to the end of its quoted id.
  @import_head ~r/@import\s+(?:url\(\s*)?["']([^"']+)["']/

  @prefix_function ~r/\bprefix\(\s*([\w-]+)\s*\)/

  @module_rule ~r/@(?:config|plugin)\s/

  # `:root, :host` is how Tailwind writes its own theme.
  @root_selector ~r/^(?::root|html|:host)$/

  @skip_dirs MapSet.new(~w(
    node_modules dist build out coverage public .next .git .turbo .registry
    _build deps .elixir_ls .lexical cover tmp
  ))

  @doc "The color namespaces a utility reads before `--color-*`."
  def color_namespaces, do: @color_namespaces

  @doc """
  Reads the theme at `file`, following its imports. An empty theme when
  `file` is `nil`.

  `theme_imports` are regexes, as strings or `Regex`es, on `@import` specifiers
  as written: the stylesheets they reach count as the project's own though they
  resolve under `node_modules`, and so do the files those import from within
  the same package. A string that is not a regex is skipped; `compile_imports/1`
  says which.
  """
  @spec load(String.t() | nil, [String.t() | Regex.t()]) :: t()
  def load(file, theme_imports \\ [])
  def load(nil, _theme_imports), do: %__MODULE__{}

  def load(file, theme_imports) do
    theme = read_stylesheets(file, theme_imports)

    %{theme | grammar: theme.declarations |> ThemeScales.of() |> Classifier.grammar()}
  end

  @doc """
  The `theme_imports` setting as regexes, and the strings that are not regexes.
  """
  @spec compile_imports(String.t() | Regex.t() | [String.t() | Regex.t()] | nil) ::
          {[Regex.t()], [String.t()]}
  def compile_imports(patterns) do
    {valid, invalid} =
      patterns
      |> List.wrap()
      |> Enum.map(&compile_import/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    {Enum.map(valid, &elem(&1, 1)), Enum.map(invalid, &elem(&1, 1))}
  end

  defp compile_import(%Regex{} = regex), do: {:ok, regex}

  defp compile_import(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, pattern}
    end
  end

  # Without the grammar, which only a theme the rules read needs.
  defp read_stylesheets(file, theme_imports \\ []) do
    file = Path.expand(file)
    {patterns, _invalid} = compile_imports(theme_imports)
    walk = %{patterns: patterns, from_package: false, own_package: nil}

    {read, _seen} = read(file, MapSet.new(), %__MODULE__{file: file}, walk)

    finalize(read)
  end

  @doc """
  The prefix the stylesheet at `file` gives Tailwind, for a theme file that is
  not the stylesheet Tailwind builds. `theme_imports` plays no part, as in
  @shadcn/lint: a prefix a design system's package declares is not read.
  """
  @spec prefix_of(String.t()) :: String.t() | nil
  def prefix_of(file), do: read_stylesheets(file).prefix

  @doc """
  Whether the stylesheet at `file` loads an `@config` or `@plugin`, for a theme file
  that is not the stylesheet Tailwind builds.
  """
  @spec modules_of(String.t()) :: boolean()
  def modules_of(file), do: read_stylesheets(file).modules

  @doc """
  Finds the stylesheet that imports Tailwind under `root`, the way the
  shadcn CLI does: when several do, the one declaring the most color tokens
  wins, then the one nearest the root. `theme_imports` is as in `load/2`, so
  the tokens of a package it names count.
  """
  @spec discover(String.t(), [String.t() | Regex.t()]) :: String.t() | nil
  def discover(root, theme_imports \\ []) do
    root = Path.expand(root)

    root
    |> css_files(0, [])
    |> Enum.sort()
    |> Enum.reduce(nil, fn file, best ->
      theme = read_stylesheets(file, theme_imports)

      if theme.tailwind do
        tokens = MapSet.size(theme.tokens)
        depth = file |> Path.relative_to(root) |> Path.split() |> length()

        case best do
          nil -> {file, tokens, depth}
          {_, best_tokens, _} when tokens > best_tokens -> {file, tokens, depth}
          {_, ^tokens, best_depth} when depth < best_depth -> {file, tokens, depth}
          _ -> best
        end
      else
        best
      end
    end)
    |> case do
      {file, _, _} -> file
      nil -> nil
    end
  end

  defp css_files(_dir, depth, acc) when depth > 5 or length(acc) > 200, do: acc

  defp css_files(dir, depth, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(Enum.sort(entries), acc, fn entry, acc ->
          full = Path.join(dir, entry)

          cond do
            String.starts_with?(entry, ".") ->
              acc

            File.dir?(full) and not MapSet.member?(@skip_dirs, entry) ->
              css_files(full, depth + 1, acc)

            File.dir?(full) ->
              acc

            String.ends_with?(entry, ".css") and full_path_ok?(full) ->
              [full | acc]

            true ->
              acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  # Phoenix writes built CSS to priv/static; it is output, not a theme.
  defp full_path_ok?(file), do: not String.contains?(file, "/priv/static/")

  @doc """
  Whether the theme declares the CSS custom property `name` (with or
  without the leading `--`), in any mode.
  """
  @spec variable?(t(), String.t()) :: boolean()
  def variable?(%__MODULE__{variables: variables}, "--" <> name),
    do: MapSet.member?(variables, name)

  def variable?(%__MODULE__{variables: variables}, name), do: MapSet.member?(variables, name)

  @doc """
  The declared color tokens, or `nil` when the theme declares none.
  """
  @spec color_tokens(t()) :: MapSet.t(String.t()) | nil
  def color_tokens(%__MODULE__{tokens: tokens}), do: if(MapSet.size(tokens) > 0, do: tokens)

  @doc """
  Token colors in OKLab, or `nil` when the theme declares no tokens.
  """
  @spec color_values(t()) :: %{String.t() => Colors.lab()} | nil
  def color_values(%__MODULE__{tokens: tokens, colors: colors}),
    do: if(MapSet.size(tokens) > 0, do: colors)

  @doc """
  Whether the project's CSS declares `token` with `@utility`, by name or by
  prefix (`@utility tab-*`).
  """
  @spec declares_utility?(t(), String.t()) :: boolean()
  def declares_utility?(%__MODULE__{} = theme, token),
    do: utility_properties_of(theme, token) != nil

  @doc """
  The properties set by the `@utility` that generates `token`, by name and
  then by prefix, or `nil` when no `@utility` declares it. An empty list is
  a body that sets nothing a category can be read from.
  """
  @spec utility_properties_of(t(), String.t()) :: [String.t()] | nil
  def utility_properties_of(%__MODULE__{utility_properties: utilities}, token) do
    base = token |> Classes.normalize() |> String.replace(Classes.opacity_modifier(), "")

    if base != "" do
      case List.keyfind(utilities, base, 0) do
        {_name, properties} ->
          properties

        nil ->
          Enum.find_value(utilities, fn {name, properties} ->
            if String.ends_with?(name, "*") and
                 String.starts_with?(base, String.slice(name, 0..-2//1)),
               do: properties
          end)
      end
    end
  end

  @doc """
  Whether the project's CSS declares `token`: an `@utility` or a plain
  class selector.
  """
  @spec declares_class?(t(), String.t()) :: boolean()
  def declares_class?(%__MODULE__{classes: classes} = theme, token) do
    declares_utility?(theme, token) or
      (fn base -> base != "" and MapSet.member?(classes, base) end).(
        token
        |> Classes.normalize()
        |> String.replace(Classes.opacity_modifier(), "")
      )
  end

  @doc "The `tab-` of an `@utility tab-*`."
  @spec utility_prefixes(MapSet.t(String.t())) :: [String.t()]
  def utility_prefixes(utilities) do
    for name <- utilities, String.ends_with?(name, "*"), do: String.slice(name, 0..-2//1)
  end

  @doc """
  Whether the stylesheet defines a plain CSS class starting with `prefix`,
  such as `.toast--error` for `toast--`.
  """
  @spec class_prefix?(t(), String.t()) :: boolean()
  def class_prefix?(%__MODULE__{classes: classes}, prefix),
    do: prefix != "" and Enum.any?(classes, &String.starts_with?(&1, prefix))

  @doc "The class map with the theme's scales applied, or `nil` for cn's own."
  @spec grammar(t() | nil) :: Trie.t() | nil
  def grammar(nil), do: nil
  def grammar(%__MODULE__{grammar: grammar}), do: grammar

  @doc """
  What a memo of answers about this theme should key on: the same for two reads
  of the same stylesheets, different once one is edited.
  """
  @spec signature(t() | nil) :: integer() | nil
  def signature(nil), do: nil
  def signature(%__MODULE__{signature: signature}), do: signature

  @doc "The radius or text scale in pixels, Tailwind's defaults with the theme's declarations over them."
  @spec scale(t(), :radius | :text) :: scale()
  def scale(%__MODULE__{scales: scales}, kind), do: Map.get(scales, kind) || default_scale(kind)

  ## Reading

  # `seen` comes back out because it spans the whole walk: a stylesheet two
  # imports reach is read at the first, and reading it again at the second
  # would put its declarations over the ones read between them.
  defp read(file, seen, acc, walk) do
    key = seen_key(file)

    if MapSet.member?(seen, key) or MapSet.size(seen) > 64 do
      {acc, seen}
    else
      seen = MapSet.put(seen, key)
      acc = %{acc | files: acc.files ++ [file]}

      case File.read(file) do
        {:ok, css} -> read_css(without_bom(css), file, seen, acc, walk)
        {:error, _} -> {acc, seen}
      end
    end
  end

  # @shadcn/lint's realpath gives a case-insensitive disk's own spelling, and Elixir has
  # no such call. Two spellings of one file agree on this, where two files or two hard
  # links, which that realpath keeps apart, do not.
  defp seen_key(file) do
    case File.stat(file) do
      {:ok, stat} -> {String.downcase(file), stat.major_device, stat.inode}
      {:error, _} -> file
    end
  end

  # JavaScript's `trim` and `\s` take a byte order mark for white space, and Elixir's do
  # not: left in, a leading `:root` reads as a scoped selector.
  defp without_bom(<<0xEF, 0xBB, 0xBF, css::binary>>), do: css
  defp without_bom(css), do: css

  defp read_css(css, file, seen, acc, walk) do
    utilities = parse_utilities(css)

    acc = %{
      acc
      | utilities: MapSet.union(acc.utilities, MapSet.new(utilities, &elem(&1, 0))),
        utility_properties: merge_utilities(acc.utility_properties, utilities),
        classes: MapSet.union(acc.classes, parse_class_selectors(css)),
        prefix:
          if(walk.from_package, do: acc.prefix, else: acc.prefix || parse_tailwind_prefix(css)),
        modules: acc.modules or Regex.match?(@module_rule, strip_comments(css))
    }

    dir = Path.dirname(file)

    # Imports come first in the cascade.
    {acc, seen} =
      Enum.reduce(parse_imports(css), {acc, seen}, fn spec, {acc, seen} ->
        acc = if tailwind_spec?(spec), do: %{acc | tailwind: true}, else: acc

        case resolve_stylesheet(dir, spec) do
          nil ->
            {%{acc | missing_imports: acc.missing_imports ++ [spec]}, seen}

          target when spec == "tailwindcss" ->
            read_tailwind_entry(target, seen, acc)

          target ->
            read(target, seen, acc, import_walk(walk, spec, target))
        end
      end)

    # Every declaration anywhere, dark mode included, for variable checks.
    acc = %{acc | variables: MapSet.union(acc.variables, all_variable_names(css))}

    if walk.from_package do
      {%{acc | theme_names: MapSet.union(acc.theme_names, package_animations(css))}, seen}
    else
      {values, scoped_names, theme_names, declarations} = parse_declarations(css)

      # Across files too, a :root value is not replaced by a scoped one.
      {merged, merged_scoped} =
        Enum.reduce(values, {acc.values, acc.scoped_names}, fn {name, value}, read ->
          put_value(read, name, value, MapSet.member?(scoped_names, name))
        end)

      {%{
         acc
         | values: merged,
           scoped_names: merged_scoped,
           theme_names: MapSet.union(acc.theme_names, theme_names),
           declarations: acc.declarations ++ declarations
       }, seen}
    end
  end

  # For `@import "tailwindcss"` @shadcn/lint follows the package's exports to
  # its JavaScript entry, so Tailwind's stylesheets add no animations and
  # `--animate-*: initial` removes the grammar's defaults. Any other path into
  # the package reads a stylesheet like any package's. So this walk keeps no
  # animations and marks none of them seen: a later `tailwindcss/theme.css` still
  # counts. It adds no declarations, being all inside node_modules, so that
  # later read cannot put any over the ones read in between. No `theme_imports`
  # reaches this walk, so that stays true of an index.css that imports its parts:
  # the JavaScript entry imports none for a pattern to match. What it marks is the
  # entry, which takes a slot of the limit there and is not read twice.
  defp read_tailwind_entry(target, seen, acc) do
    entry = {:tailwind_entry, target}

    if MapSet.member?(seen, entry) do
      {acc, seen}
    else
      walk = %{patterns: [], from_package: true, own_package: nil}
      {walked, _seen} = read(target, seen, acc, walk)
      {%{walked | theme_names: acc.theme_names}, MapSet.put(seen, entry)}
    end
  end

  # A package's own @theme animations are generated all the same:
  # tw-animate-css declares --animate-in there.
  defp package_animations(css) do
    if String.contains?(css, "--animate-") do
      {_values, _scoped_names, theme_names, _declarations} = parse_declarations(css)
      MapSet.filter(theme_names, &String.starts_with?(&1, "animate-"))
    else
      MapSet.new()
    end
  end

  # A utility declared again takes the new body and keeps its place.
  defp merge_utilities(utilities, new) do
    bodies = Map.new(new)
    known = MapSet.new(utilities, &elem(&1, 0))

    kept = Enum.map(utilities, fn {name, body} -> {name, Map.get(bodies, name, body)} end)

    added =
      new
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reject(fn {name, _} -> MapSet.member?(known, name) end)
      |> Enum.map(fn {name, _} -> {name, Map.fetch!(bodies, name)} end)

    kept ++ added
  end

  defp finalize(%__MODULE__{} = theme) do
    {tokens, scoped} = apply_token_declarations(theme.declarations, MapSet.new(), %{})
    theme = %{theme | tokens: tokens, scoped: scoped, files: Enum.uniq(theme.files)}

    %{
      theme
      | colors: colors_of(theme),
        scales: %{radius: build_scale(theme, :radius), text: build_scale(theme, :text)},
        spacing: spacing_of(theme),
        signature: read_signature(theme)
    }
  end

  defp read_signature(%__MODULE__{} = theme) do
    :erlang.phash2(
      {theme.file, theme.declarations, theme.utility_properties, theme.classes, theme.theme_names,
       theme.values, theme.variables, theme.tailwind, theme.prefix, theme.modules}
    )
  end

  defp package_file?(file), do: String.contains?(file, "/node_modules/")

  # How an import is read: as the project's own if it reaches an owned package,
  # and otherwise as a package's once it is under node_modules or its importer
  # was. Walking through another package forgets the owned one.
  defp import_walk(walk, spec, target) do
    own = own_package_of(spec, target, walk)

    %{
      walk
      | own_package: own,
        from_package: if(own, do: false, else: walk.from_package or package_file?(target))
    }
  end

  # The package whose tokens an import contributes: one `theme_imports` names,
  # or the same package a counted file imports from within. A kit's own
  # `@import "tailwindcss"` is another package, so Tailwind's palette stays out.
  defp own_package_of(spec, target, %{patterns: patterns, own_package: current}) do
    dir = package_dir_of(target)

    cond do
      dir == nil -> nil
      Enum.any?(patterns, &Regex.match?(&1, spec)) -> dir
      dir == current -> dir
      true -> nil
    end
  end

  # The installed package a file belongs to: the directory after the last
  # node_modules, two segments for a scope. Nil outside node_modules.
  defp package_dir_of(file) do
    segments = String.split(file, "/")

    last_marker =
      segments
      |> Enum.drop(-1)
      |> Enum.with_index()
      |> Enum.filter(fn {segment, _at} -> segment == "node_modules" end)
      |> List.last()

    case last_marker do
      nil ->
        nil

      {_segment, at} ->
        {head, [first | _] = rest} = Enum.split(segments, at + 1)
        depth = if String.starts_with?(first, "@"), do: 2, else: 1
        Enum.join(head ++ Enum.take(rest, depth), "/")
    end
  end

  @doc false
  # Removes /* */ comments the way a CSS tokenizer would: a "/*" inside a
  # string or an unquoted url() is text.
  def strip_comments(css), do: strip(css, [], [])

  defp strip("", _quote, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip("/*" <> rest, [], acc) do
    case :binary.match(rest, "*/") do
      {pos, 2} -> strip(binary_part(rest, pos + 2, byte_size(rest) - pos - 2), [], acc)
      :nomatch -> strip("", [], acc)
    end
  end

  defp strip(<<q, rest::binary>>, [], acc) when q in [?", ?'] do
    {string, rest} = take_string(rest, q, [q])
    strip(rest, [], [string | acc])
  end

  defp strip("url(" <> rest, [], acc) do
    case :binary.match(rest, ")") do
      {pos, 1} ->
        strip(binary_part(rest, pos + 1, byte_size(rest) - pos - 1), [], [
          "url(" <> binary_part(rest, 0, pos + 1) | acc
        ])

      :nomatch ->
        strip("", [], ["url(" <> rest | acc])
    end
  end

  # By the byte: a stylesheet saved as Latin-1 is no reason to stop.
  defp strip(<<byte, rest::binary>>, quote, acc), do: strip(rest, quote, [byte | acc])

  defp take_string("", _q, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_string(<<?\\, byte, rest::binary>>, q, acc),
    do: take_string(rest, q, [byte, "\\" | acc])

  defp take_string(<<q, rest::binary>>, q, acc),
    do: {[q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string(<<byte, rest::binary>>, q, acc),
    do: take_string(rest, q, [byte | acc])

  @doc false
  def parse_imports(css), do: css |> strip_comments() |> imports(0, [])

  # A rule's end is its `;`, found with one search. A `[^;]*` after each @import reads
  # the rest of a file that has none once per @import in it.
  defp imports(text, offset, acc) do
    case Regex.run(@import_head, text, offset: offset, return: :index) do
      nil ->
        Enum.reverse(acc)

      [{start, length}, {id_start, id_length}] ->
        head_end = start + length

        case :binary.match(text, ";", scope: {head_end, byte_size(text) - head_end}) do
          # No `;` ends this @import, so none ends a later one either.
          :nomatch -> Enum.reverse(acc)
          {at, _} -> imports(text, at + 1, [binary_part(text, id_start, id_length) | acc])
        end
    end
  end

  @doc false
  # The prefix a Tailwind import declares before the `;` that ends it, if any.
  def parse_tailwind_prefix(css), do: css |> strip_comments() |> tailwind_prefix(0)

  defp tailwind_prefix(text, offset) do
    case Regex.run(@import_head, text, offset: offset, return: :index) do
      nil ->
        nil

      [{start, length}, {id_start, id_length}] ->
        head_end = start + length

        if tailwind_spec?(binary_part(text, id_start, id_length)),
          do: prefix_of_import(text, head_end),
          else: tailwind_prefix(text, head_end)
    end
  end

  defp prefix_of_import(text, head_end) do
    rule_end =
      case :binary.match(text, ";", scope: {head_end, byte_size(text) - head_end}) do
        {at, _} -> at
        :nomatch -> nil
      end

    rest = binary_part(text, head_end, (rule_end || byte_size(text)) - head_end)

    case Regex.run(@prefix_function, rest, capture: :all_but_first) do
      [prefix] -> prefix
      # A Tailwind @import inside `rest` ends at the same `;`.
      nil when rule_end == nil -> nil
      nil -> tailwind_prefix(text, rule_end)
    end
  end

  defp tailwind_spec?(spec),
    do: spec == "tailwindcss" or String.starts_with?(spec, "tailwindcss/")

  # Not in @shadcn/lint. Bodies with no other inside them cannot overlap, so reading all
  # of them is one pass over the file. One that holds another, nested in it or left open,
  # can run on to the end of the file, so a file of them is quadratic, and a `{` in a
  # string counts as a brace here too. Past this many passes such a body reads as setting
  # nothing a category can be read from.
  @utility_body_passes 16

  @doc false
  # Each @utility in source order, with the properties its body sets.
  def parse_utilities(css) do
    stripped = strip_comments(css)
    heads = Regex.scan(~r/@utility\s+([\w-]+\*?)\s*\{/, stripped, return: :index)
    closes = body_closes(stripped, heads)
    next_heads = Enum.map(Enum.drop(heads, 1), fn [{start, _} | _] -> start end)

    {utilities, _left} =
      heads
      |> Enum.zip(next_heads ++ [byte_size(stripped)])
      |> Enum.map_reduce(
        @utility_body_passes * byte_size(stripped),
        fn {[{start, length}, {name_start, name_length}], next_head}, left ->
          open = start + length
          # An unclosed body runs to the end of the file.
          close = Map.get(closes, open, byte_size(stripped))
          {properties, left} = declared_properties(stripped, open, close, next_head, left)
          {{binary_part(stripped, name_start, name_length), properties}, left}
        end
      )

    merge_utilities([], utilities)
  end

  # Where each body closes, by where it opens, with one pass over the braces.
  defp body_closes(css, heads) do
    opens = MapSet.new(heads, fn [{start, length} | _] -> start + length end)

    {_stack, closes} =
      css
      |> :binary.matches(["{", "}"])
      |> Enum.reduce({[], %{}}, fn {at, 1}, {stack, closes} ->
        case {:binary.at(css, at), stack} do
          {?{, stack} ->
            {[at + 1 | stack], closes}

          {?}, []} ->
            {[], closes}

          {?}, [open | stack]} ->
            {stack, if(MapSet.member?(opens, open), do: Map.put(closes, open, at), else: closes)}
        end
      end)

    closes
  end

  # The properties an @utility body sets, from just inside its brace to the
  # matching close, nesting included: a declaration follows a brace or a
  # semicolon, which neither a selector like &:hover nor an at-rule prelude
  # does. Custom properties stay in: a body that sets --tw-shadow-color is
  # as much a color as one that sets box-shadow.
  defp declared_properties(_css, _open, close, next_head, left)
       when next_head < close and left <= 0,
       do: {[], left}

  defp declared_properties(css, open, close, next_head, left) do
    properties =
      ~r/(?:^|[;{}])\s*(-{0,2}[a-zA-Z][\w-]*)\s*:/
      |> Regex.scan(binary_part(css, open, close - open), capture: :all_but_first)
      |> Enum.map(fn [name] -> String.downcase(name) end)
      |> Enum.uniq()

    {properties, if(next_head < close, do: left - (close - open), else: left)}
  end

  @doc false
  # A class that exists in CSS (.legacy-card) is not an unknown class. A
  # "dist/*.js" in a string is a glob, not a .js selector.
  def parse_class_selectors(css) do
    stripped = css |> strip_comments() |> blank_strings()

    ~r/\.(-?[_a-zA-Z][\w-]*)/
    |> Regex.scan(stripped, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc false
  # Replaces what `"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'` matches with `""`, in one pass. That
  # regex retries from each quote of a string that never closes, so `\"` repeated is
  # quadratic. A retry cannot do better: a quote like it before the point the read stopped
  # was escaped, or it would have closed the string, so reading on from it stops there too.
  def blank_strings(css), do: blank_strings(css, 0, 0, {0, 0}, [])

  defp blank_strings(css, from, at, stops, acc) do
    case :binary.match(css, ["\"", "'"], scope: {at, byte_size(css) - at}) do
      :nomatch ->
        [binary_part(css, from, byte_size(css) - from) | acc]
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      {open, 1} ->
        quote = :binary.at(css, open)
        rest = binary_part(css, open + 1, byte_size(css) - open - 1)

        case open >= stop_for(stops, quote) && string_close(rest, quote, open + 1) do
          false ->
            blank_strings(css, from, open + 1, stops, acc)

          {:closed, close} ->
            acc = [~s(""), binary_part(css, from, open - from) | acc]
            blank_strings(css, close + 1, close + 1, stops, acc)

          {:open, stop} ->
            blank_strings(css, from, open + 1, put_stop(stops, quote, stop), acc)
        end
    end
  end

  defp stop_for({double, _single}, ?"), do: double
  defp stop_for({_double, single}, ?'), do: single

  defp put_stop({_double, single}, ?", stop), do: {stop, single}
  defp put_stop({double, _single}, ?', stop), do: {double, stop}

  # `.` takes no newline, so a backslash before one, or before nothing, ends the read.
  defp string_close(<<quote, _::binary>>, quote, at), do: {:closed, at}
  defp string_close(<<?\\, ?\n, _::binary>>, _quote, at), do: {:open, at}
  defp string_close(<<?\\, _, rest::binary>>, quote, at), do: string_close(rest, quote, at + 2)
  defp string_close(<<?\\>>, _quote, at), do: {:open, at}
  defp string_close(<<_, rest::binary>>, quote, at), do: string_close(rest, quote, at + 1)
  defp string_close(<<>>, _quote, at), do: {:open, at}

  defp all_variable_names(css) do
    ~r/(?<![\w-])--([\w-]+)\s*:/
    |> Regex.scan(strip_comments(css), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc false
  # Declarations in cascade order, dark-mode blocks skipped. Later
  # declarations win in `values`, as in CSS, but a value set under `:root` or
  # `@theme` wins over one a scoped selector such as `.compact` sets: the
  # scoped value applies only inside that selector. `scoped_names` lists the
  # values only a scoped selector sets.
  def parse_declarations(css) do
    stripped = strip_comments(css)

    {_stack, _start, {values, scoped_names}, names, declarations} =
      stripped
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce({[], 0, {%{}, MapSet.new()}, MapSet.new(), []}, fn
        {?{, i}, {stack, start, values, names, decls} ->
          prelude = stripped |> binary_part(start, i - start) |> String.trim()
          outer = List.first(stack, %{theme: false, dark: false, scoped: false})

          scope = %{
            theme: outer.theme or Regex.match?(~r/^@theme\b/, prelude),
            dark: outer.dark or Regex.match?(@dark_prelude, prelude),
            scoped: outer.scoped or scoped_prelude?(prelude)
          }

          {[scope | stack], i + 1, values, names, decls}

        {c, i}, {stack, start, values, names, decls} when c in [?}, ?;] ->
          statement = binary_part(stripped, start, i - start)
          scope = List.first(stack)

          {values, names, decls} =
            case Regex.run(~r/^\s*--((?:[\w-]+\*?)|\*)\s*:\s*([\s\S]+)\z/, statement) do
              [_, name, value] when scope == nil or not scope.dark ->
                theme = scope != nil and scope.theme
                value = trim_value(value)

                {put_value(values, name, value, scope != nil and scope.scoped),
                 if(theme, do: MapSet.put(names, name), else: names),
                 [%{name: name, value: value, theme: theme} | decls]}

              _ ->
                {values, names, decls}
            end

          stack = if c == ?}, do: Enum.drop(stack, 1), else: stack
          {stack, i + 1, values, names, decls}

        _, acc ->
          acc
      end)

    {values, scoped_names, names, Enum.reverse(declarations)}
  end

  # Greedy, then trimmed: a lazy value retries the trailing whitespace at every
  # character of a run of it, and past the regex engine's limit it reads as no
  # value at all. A value of only whitespace keeps its one character.
  defp trim_value(value) do
    case String.trim_trailing(value) do
      "" -> value
      trimmed -> trimmed
    end
  end

  # An at-rule's prelude is a condition, not a selector.
  defp scoped_prelude?("@" <> _), do: false

  defp scoped_prelude?(prelude) do
    not (prelude
         |> String.split(",")
         |> Enum.all?(&Regex.match?(@root_selector, String.trim(&1))))
  end

  defp put_value({values, scoped_names} = read, name, value, scoped) do
    cond do
      not scoped -> {Map.put(values, name, value), MapSet.delete(scoped_names, name)}
      Map.has_key?(values, name) and not MapSet.member?(scoped_names, name) -> read
      true -> {Map.put(values, name, value), MapSet.put(scoped_names, name)}
    end
  end

  # In cascade order: `--color-x: initial` drops x, `--color-*: initial` and
  # `--*: initial` drop everything declared so far. A scoped namespace
  # resets on its own.
  defp apply_token_declarations(declarations, tokens, scoped) do
    Enum.reduce(declarations, {tokens, scoped}, fn
      %{theme: false}, acc ->
        acc

      %{name: "*", value: value}, {tokens, scoped} ->
        if String.trim(value) == "initial", do: {MapSet.new(), %{}}, else: {tokens, scoped}

      %{name: name, value: value}, {tokens, scoped} ->
        reset = String.trim(value) == "initial"

        namespace =
          if String.starts_with?(name, "color-"),
            do: "color",
            else: Enum.find(@color_namespaces, &String.starts_with?(name, &1 <> "-"))

        case namespace do
          nil ->
            {tokens, scoped}

          "color" ->
            {apply_token(tokens, String.slice(name, 6..-1//1), reset), scoped}

          namespace ->
            token = String.slice(name, (String.length(namespace) + 1)..-1//1)
            set = apply_token(Map.get(scoped, namespace, MapSet.new()), token, reset)
            {tokens, Map.put(scoped, namespace, set)}
        end
    end)
  end

  defp apply_token(_set, "*", true), do: MapSet.new()
  defp apply_token(set, "*", false), do: set
  defp apply_token(set, token, true), do: MapSet.delete(set, token)
  defp apply_token(set, token, false), do: MapSet.put(set, token)

  # Far past any real theme value. A value that names a variable k times, each
  # naming another k times, grows as k^6 through six levels: k = 10 builds 4 MB and
  # k = 16 takes seconds to. Every substitution spends its length in UTF-16 units and
  # one more from a budget shared by the whole resolution.
  @resolve_budget 100_000

  @doc false
  # Resolves var() references against `values`; nil when a variable has no value
  # and no fallback, or when resolving the value would spend more than the budget.
  def resolve_variables(value, values, depth \\ 0) do
    {resolved, _known} = resolve_known(value, values, %{}, depth)
    resolved
  end

  # The budget pays for what a substitution yields, not for the text read to get there:
  # `--pad: var(--k, ...)` with a fallback of 100 KB, named 20,000 times, reads 2 GB for
  # 80,000 units. So `known` keeps what each variable comes to, per level since a level
  # can be too deep, and a theme's values read against the same `values` share it.
  #
  # That leaves the results as they were. A resolution stops at the first failure and
  # all it returns then is nil, so a variable either fails from any budget, or spends the
  # same amount from any budget and fits or does not. A read is `{text, units, spent}`,
  # or nil when it fails from a full budget. `text` is iodata, because a copy of each
  # result is up to 300 KB kept per variable.
  defp resolve_known(value, values, known, depth \\ 0) do
    case read_value(value, values, depth, known) do
      {nil, known} -> {nil, known}
      {{text, _units, _spent}, known} -> {IO.iodata_to_binary(text), known}
    end
  end

  defp read_value(value, values, depth, known) do
    cond do
      not String.contains?(value, "var(") ->
        {{value, units(value), 0}, known}

      depth > 6 ->
        {nil, known}

      true ->
        ~r/var\(\s*--([\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\)[^()]*)*))?\)/
        |> Regex.scan(value, return: :index)
        |> substitute(value, values, depth, known, {0, [], 0, 0})
    end
  end

  defp substitute([], value, _values, _depth, known, {from, parts, units, spent}) do
    rest = binary_part(value, from, byte_size(value) - from)
    {{Enum.reverse([rest | parts]), units + units(rest), spent}, known}
  end

  # Left to right, stopping at the first that fails: what follows one past the
  # budget would only spend more.
  defp substitute(
         [[{start, length} | groups] | matches],
         value,
         values,
         depth,
         known,
         {from, parts, units, spent}
       ) do
    [name | rest] = Enum.map(groups, fn {s, l} -> if s >= 0, do: binary_part(value, s, l) end)

    case read_reference(name, List.first(rest), values, depth + 1, known) do
      {nil, known} ->
        {nil, known}

      {{text, text_units, text_spent}, known} ->
        spent = spent + text_spent + 1 + text_units

        if spent > @resolve_budget do
          {nil, known}
        else
          before = binary_part(value, from, start - from)

          read =
            {start + length, [text, before | parts], units + units(before) + text_units, spent}

          substitute(matches, value, values, depth, known, read)
        end
    end
  end

  # A fallback is part of the value that holds it, which is read once.
  defp read_reference(name, fallback, values, depth, known) do
    case {Map.fetch(known, {name, depth}), Map.fetch(values, name)} do
      {{:ok, read}, _value} ->
        {read, known}

      {:error, {:ok, value}} ->
        {read, known} = read_value(String.trim(value), values, depth, known)
        {read, Map.put(known, {name, depth}, read)}

      {:error, :error} when fallback == nil ->
        {nil, known}

      {:error, :error} ->
        read_value(String.trim(fallback), values, depth, known)
    end
  end

  # JavaScript's `.length`: UTF-16 units, of the text Node reads, where each run of bytes
  # it cannot decode is one U+FFFD. Characters will not do: one letter with any number of
  # combining marks would cost 1, and every substitution copies all of them. No unit takes
  # more than three bytes, so a text past three times the budget is over without reading it.
  defp units(text) when byte_size(text) > 3 * @resolve_budget, do: @resolve_budget + 1
  defp units(text), do: count_units(text, 0)

  defp count_units(<<char::utf8, rest::binary>>, count),
    do: count_units(rest, count + if(char > 0xFFFF, do: 2, else: 1))

  defp count_units(<<>>, count), do: count
  defp count_units(rest, count), do: rest |> String.replace_invalid() |> count_units(count)

  defp colors_of(theme) do
    {colors, _known} =
      for token <- theme.tokens,
          raw = Map.get(theme.values, "color-" <> token),
          raw != nil,
          reduce: {%{}, %{}} do
        {colors, known} ->
          {resolved, known} = resolve_known(raw, theme.values, known)
          lab = resolved && Colors.parse(resolved)
          {if(lab, do: Map.put(colors, token, lab), else: colors), known}
      end

    colors
  end

  defp default_scale(kind) do
    defaults = if kind == :radius, do: TailwindTheme.radii(), else: TailwindTheme.font_sizes()

    # Tailwind declares its defaults smallest first.
    for({name, value} <- defaults, px = Lengths.px(value), px != nil, do: {name, px})
    |> List.keysort(1)
  end

  @doc false
  def default_scales, do: %{radius: default_scale(:radius), text: default_scale(:text)}

  # The theme's own --radius-* / --text-* declarations over Tailwind's defaults,
  # in cascade order, the way Tailwind reads them. Each step remembers when it was
  # first declared: a step replaced keeps its place, and one removed and declared
  # again goes last.
  defp build_scale(theme, kind) do
    prefix = "#{kind}-"

    declared =
      kind
      |> default_scale()
      |> Enum.with_index(fn {name, px}, order -> {name, {order, px}} end)
      |> Map.new()

    {steps, _next, _known} =
      Enum.reduce(theme.declarations, {declared, map_size(declared), %{}}, fn
        %{theme: false}, read ->
          read

        %{name: "*", value: value}, {_steps, next, known} = read ->
          if String.trim(value) == "initial", do: {%{}, next, known}, else: read

        %{name: name, value: value}, {steps, next, known} = read ->
          if String.starts_with?(name, prefix) and not String.contains?(name, "--") do
            step = String.slice(name, String.length(prefix)..-1//1)
            reset = String.trim(value) == "initial"

            cond do
              step == "*" -> if reset, do: {%{}, next, known}, else: read
              reset -> {Map.delete(steps, step), next, known}
              true -> scale_step(read, step, value, theme.values)
            end
          else
            read
          end
      end)

    steps
    |> Enum.sort_by(fn {_name, {order, _px}} -> order end)
    |> Enum.map(fn {name, {_order, px}} -> {name, px} end)
  end

  defp scale_step({steps, next, known}, step, value, values) do
    {resolved, known} = resolve_known(value, values, known)
    px = resolved && Lengths.px(resolved)

    case {px, steps} do
      {nil, steps} -> {Map.delete(steps, step), next, known}
      {px, %{^step => {order, _old}}} -> {Map.put(steps, step, {order, px}), next, known}
      {px, steps} -> {Map.put(steps, step, {next, px}), next + 1, known}
    end
  end

  # Tailwind's 0.25rem unless the theme sets --spacing. Nil when the theme
  # removes it or sets it unreadably: no exact step can be named then.
  defp spacing_of(%__MODULE__{file: nil}), do: 4.0

  defp spacing_of(theme) do
    raw =
      Enum.reduce(theme.declarations, TailwindTheme.spacing(), fn
        %{theme: false}, raw ->
          raw

        %{name: "*", value: value}, raw ->
          if String.trim(value) == "initial", do: nil, else: raw

        %{name: "spacing", value: value}, _raw ->
          if String.trim(value) == "initial", do: nil, else: value

        _, raw ->
          raw
      end)

    px =
      with raw when raw != nil <- raw,
           resolved when resolved != nil <- resolve_variables(raw, theme.values) do
        Lengths.px(resolved)
      end

    if px && px > 0, do: px, else: nil
  end

  ## Stylesheet resolution

  # A port of the `resolveFile` @shadcn/lint's theme read calls with `[".css"]`.
  # Tailwind's build resolves differently, with a `style` condition first, so a
  # kit's tokens can come from another file than the one it builds. Both linters
  # share that, and it is what keeps their findings the same. `priv/tailwind_oracle.mjs`
  # has both ways, and its targets stay inside the package the same way. Containment
  # reads the path as written: a link the package itself holds is followed, as in Node.

  @preferred_conditions ["import", "default", "require", "node", "types"]

  # Real exports nest conditions a few levels deep. Past this a manifest has no
  # target.
  @max_condition_depth 32

  # nodenext and bundler resolution import "./button.js" for button.ts.
  @source_for_js %{
    ".js" => [".ts", ".tsx"],
    ".jsx" => [".tsx"],
    ".mjs" => [".mts", ".ts"],
    ".cjs" => [".cts", ".ts"]
  }

  @doc """
  Resolves an `@import` the way @shadcn/lint's theme read does: a path, an
  `imports` map entry (`#tokens`), or a package under `node_modules` through its
  `exports` and then its own files. The package's `style` and `main` fields count
  only when that finds nothing, which @shadcn/lint does not do. The answer is the
  file's real path, symlinks resolved.
  """
  @spec resolve_stylesheet(String.t(), String.t()) :: String.t() | nil
  def resolve_stylesheet(base, "tailwindcss"),
    do: resolve_stylesheet(base, "tailwindcss/index.css")

  def resolve_stylesheet(base, id) do
    base = Path.expand(base)
    root = package_root(base) || base

    within = [root, base]

    target =
      cond do
        Regex.match?(~r/^(?:https?:|data:)/, id) or stray_unc?(id, within) ->
          nil

        path_import?(id) ->
          first_stylesheet([Path.expand(id, base)], within)

        String.starts_with?(id, "#") ->
          first_stylesheet(imports_candidates(id, root), within)

        true ->
          first_stylesheet(package_candidates(id, root, base), within) ||
            package_field_stylesheet(id, root, base)
      end

    target && real_path(target)
  end

  defp first_stylesheet(candidates, within) do
    candidates |> Enum.reject(&stray_unc?(&1, within)) |> Enum.find_value(&stylesheet_for/1)
  end

  @doc false
  # A UNC path reaches the network on Windows: stat one and the OS sends the user's
  # credentials to whatever host it names. A project that lives on a share still
  # reaches its own files.
  def stray_unc?(file, within) do
    String.starts_with?(file, ["//", "\\\\", "/\\", "\\/"]) and
      not Enum.any?(within, &inside?(Path.expand(&1), Path.expand(file)))
  end

  defp path_import?(id) do
    id in [".", ".."] or String.starts_with?(id, ["./", "../"]) or Path.type(id) == :absolute
  end

  defp imports_candidates(id, root) do
    case read_package_json(root)["imports"] do
      {:object, _} = imports ->
        mapped =
          Enum.flat_map(map_subpath(imports, id, root, true), fn
            {:file, file} -> [file]
            # A package target resolves as a package, never as a path.
            {:spec, spec} -> package_candidates(spec, root, root)
          end)

        mapped ++ directory_aliases(imports, id, root)

      _ ->
        []
    end
  end

  defp package_candidates(id, root, from) do
    with {name, subpath} <- split_package_specifier(id),
         dir when dir != nil <- find_package(name, root, from) do
      key = if subpath == "", do: ".", else: "./" <> subpath

      mapped =
        case read_package_json(dir)["exports"] do
          {:object, _} = exports ->
            files = for {:file, file} <- map_subpath(exports, key, dir), do: file
            files ++ directory_aliases(exports, key, dir)

          _ ->
            []
        end

      # The package's own files, never a path that walks out of it.
      own = [Path.join(dir, subpath), Path.join([dir, "src", subpath])]
      mapped ++ (own |> Enum.map(&Path.expand/1) |> Enum.filter(&inside?(dir, &1)))
    else
      _ -> []
    end
  end

  # A directory alias against a wildcard key ("./components/*").
  defp directory_aliases(map, key, dir) do
    for {:file, file} <- map_subpath(map, key <> "/*", dir), do: Path.dirname(file)
  end

  # Not in @shadcn/lint: Tailwind reads a package's `style` field, so a kit that
  # only names its stylesheet there still contributes what it declares.
  defp package_field_stylesheet(id, root, from) do
    with {name, ""} <- split_package_specifier(id),
         dir when dir != nil <- find_package(name, root, from) do
      manifest = read_package_json(dir)

      Enum.find_value(["style", "main"], fn field ->
        with target when is_binary(target) <- manifest[field],
             file = Path.expand(Path.join(dir, target)),
             true <- inside?(dir, file) do
          existing_file(file)
        else
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp split_package_specifier(id) do
    parts = String.split(id, "/")
    name_length = if String.starts_with?(id, "@"), do: 2, else: 1

    if length(parts) >= name_length do
      {name, rest} = Enum.split(parts, name_length)
      {Enum.join(name, "/"), Enum.join(rest, "/")}
    end
  end

  # A package naming itself comes first: from its real path, a workspace package
  # may have no node_modules above it that links it back. `root` is the nearest
  # package.json above the import, so `from` has the same one.
  defp find_package(name, root, from) do
    self_package_directory(name, root) || package_directory(name, root) ||
      package_directory(name, from)
  end

  defp self_package_directory(name, root) do
    if read_package_json(root)["name"] == name, do: real_path(root)
  end

  # By the directory alone: a package with no package.json still has files.
  defp package_directory(name, from) do
    found = find_up(from, Path.join("node_modules", name))
    found && real_path(found)
  end

  defp package_root(from) do
    manifest = find_up(from, "package.json")
    manifest && Path.dirname(manifest)
  end

  defp find_up(from, name), do: find_up(from, name, 32)

  defp find_up(_dir, _name, 0), do: nil

  defp find_up(dir, name, depth) do
    candidate = Path.join(dir, name)
    parent = Path.dirname(dir)

    cond do
      File.exists?(candidate) -> candidate
      parent == dir -> nil
      true -> find_up(parent, name, depth - 1)
    end
  end

  # Objects keep their order, since the first matching condition or key wins:
  # `{:object, pairs}`, with a repeated key where it first appeared and with its
  # last value, as `JSON.parse` has it. The top level is a plain map.
  defp read_package_json(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "package.json")),
         {{:object, pairs}, :ok, ""} <- decode_ordered(text) do
      Map.new(pairs)
    else
      _ -> %{}
    end
  end

  defp decode_ordered(text) do
    JSON.decode(text, :ok,
      object_start: fn _acc -> [] end,
      object_push: fn key, value, pairs -> [{key, value} | pairs] end,
      object_finish: fn pairs, acc -> {{:object, in_written_order(pairs)}, acc} end
    )
  end

  defp in_written_order(newest_first) do
    pairs = Enum.reverse(newest_first)
    last = Map.new(pairs)
    pairs |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(fn {key, _} -> {key, last[key]} end)
  end

  # Through an exports or imports map, longest key first, as files inside `dir`
  # or, with `bare`, as package specifiers an imports map points at.
  defp map_subpath({:object, pairs}, subpath, dir, bare \\ false) do
    pairs
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, [".", "#"]) end)
    |> Enum.sort_by(fn {key, _} -> -String.length(key) end)
    |> Enum.flat_map(fn {key, value} ->
      captured = match_pattern(key, subpath)

      with true <- captured != nil and safe_segments?(captured),
           target when target != nil <- pick_target(value, &valid_target?(&1, bare), 0) do
        map_target(target, captured, dir)
      else
        _ -> []
      end
    end)
  end

  defp map_target("./" <> _ = target, captured, dir) do
    case package_target(dir, target, captured) do
      nil -> []
      file -> [{:file, file}]
    end
  end

  defp map_target(target, captured, _dir), do: [{:spec, expand_target(target, captured)}]

  defp valid_target?(target, bare), do: package_target?(target) or (bare and bare_target?(target))

  # The first target `valid?` accepts, so an invalid one falls through to the next
  # fallback. Each condition is tried once.
  defp pick_target(value, valid?, _depth) when is_binary(value),
    do: if(valid?.(value), do: value)

  defp pick_target(_value, _valid?, depth) when depth >= @max_condition_depth, do: nil

  defp pick_target(value, valid?, depth) when is_list(value),
    do: Enum.find_value(value, &pick_target(&1, valid?, depth + 1))

  defp pick_target({:object, pairs}, valid?, depth) do
    preferred =
      for key <- @preferred_conditions, pair = List.keyfind(pairs, key, 0), do: pair

    rest =
      Enum.reject(pairs, fn {key, _} ->
        String.starts_with?(key, ".") or key in @preferred_conditions
      end)

    Enum.find_value(preferred ++ rest, fn {_key, value} ->
      pick_target(value, valid?, depth + 1)
    end)
  end

  defp pick_target(_value, _valid?, _depth), do: nil

  # The text `*` captured, "" for an exact match, or nil.
  defp match_pattern(pattern, value) do
    case String.split(pattern, "*", parts: 2) do
      [^value] ->
        ""

      [prefix, suffix] ->
        taken = byte_size(prefix) + byte_size(suffix)

        if byte_size(value) >= taken and String.starts_with?(value, prefix) and
             String.ends_with?(value, suffix) do
          binary_part(value, byte_size(prefix), byte_size(value) - taken)
        end

      _ ->
        nil
    end
  end

  defp expand_target(target, captured), do: String.replace(target, "*", captured, global: false)

  # What Node refuses in a target or a `*` capture: walking up, reaching into
  # node_modules, and percent-encoded separators.
  defp safe_segments?(text) do
    not Regex.match?(~r/%2f|%5c/i, text) and
      not (text
           |> String.split(["/", "\\"])
           |> Enum.any?(&Regex.match?(~r/^(?:\.|%2e){1,2}\z|^node_modules\z/i, &1)))
  end

  defp package_target?("./" <> rest), do: safe_segments?(rest)
  defp package_target?(_target), do: false

  # An imports target may also name a package, never a path or a URL.
  defp bare_target?(target), do: Regex.match?(~r/^[^.\/\\#][^:\\]*\z/, target)

  # The file a target names, or nil when it would leave the package.
  defp package_target(dir, target, captured) do
    if package_target?(target) and safe_segments?(captured) do
      file = Path.expand(expand_target(target, captured), dir)
      if inside?(dir, file), do: file
    end
  end

  defp inside?(dir, file),
    do: file == dir or String.starts_with?(file, String.trim_trailing(dir, "/") <> "/")

  defp stylesheet_for(candidate) do
    existing_file(candidate) || source_for_js(candidate) ||
      existing_file(candidate <> ".css") || existing_file(Path.join(candidate, "index.css"))
  end

  defp source_for_js(candidate) do
    extension = Path.extname(candidate)

    @source_for_js
    |> Map.get(extension, [])
    |> Enum.find_value(&existing_file(String.replace_suffix(candidate, extension, &1)))
  end

  defp existing_file(path), do: if(File.regular?(path), do: path)

  # Elixir has no realpath. The path exists, since `File.regular?/1` followed
  # its links, so the budget only guards against a link changing mid-walk.
  defp real_path(path) do
    [root | segments] = Path.split(path)
    follow(segments, root, 64) || path
  end

  defp follow([], real, _budget), do: real
  defp follow(_segments, _real, 0), do: nil
  defp follow(["." | rest], real, budget), do: follow(rest, real, budget)
  defp follow([".." | rest], real, budget), do: follow(rest, Path.dirname(real), budget)

  defp follow([segment | rest], real, budget) do
    candidate = Path.join(real, segment)

    case File.read_link(candidate) do
      {:ok, link} ->
        if Path.type(link) == :absolute do
          [root | segments] = Path.split(link)
          follow(segments ++ rest, root, budget - 1)
        else
          follow(Path.split(link) ++ rest, real, budget - 1)
        end

      {:error, _} ->
        follow(rest, candidate, budget)
    end
  end
end
