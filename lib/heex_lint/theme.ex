defmodule HeexLint.Theme do
  @moduledoc """
  What a project's Tailwind stylesheet declares: the `--color-*` tokens in
  `@theme`, the scales, and the classes its CSS defines.

  Ported from @shadcn/lint's `src/project/theme.ts` (MIT). Imports are
  followed; files under `node_modules` contribute `@utility` names, class
  selectors and `--animate-*` theme names but not tokens, since Tailwind's
  own palette is not the project's vocabulary. Dark-mode blocks are skipped,
  so values are the light theme's.
  """

  alias HeexLint.Grammar.{Classes, Colors, Lengths, TailwindTheme}

  defstruct file: nil,
            tailwind: false,
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
            spacing: nil

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
          spacing: float() | nil
        }

  # The namespaces Tailwind reads a color utility from before --color-*,
  # verified against Tailwind 4.3.3 by @shadcn/lint.
  @color_namespaces ~w(
    background-color text-color border-color divide-color ring-color outline-color
    accent-color caret-color placeholder-color text-decoration-color
    text-shadow-color drop-shadow-color fill stroke
  )

  @dark_prelude ~r/\.dark(?![\w-])|prefers-color-scheme\s*:\s*dark|data-(?:theme|mode)=["']?dark|@variant\s+dark\b/

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
  """
  @spec load(String.t() | nil) :: t()
  def load(nil), do: %__MODULE__{}

  def load(file) do
    file = Path.expand(file)

    {read, _seen} = read(file, MapSet.new(), %__MODULE__{file: file}, false)

    finalize(read)
  end

  @doc """
  Finds the stylesheet that imports Tailwind under `root`, the way the
  shadcn CLI does: when several do, the one declaring the most color tokens
  wins, then the one nearest the root.
  """
  @spec discover(String.t()) :: String.t() | nil
  def discover(root) do
    root = Path.expand(root)

    root
    |> css_files(0, [])
    |> Enum.sort()
    |> Enum.reduce(nil, fn file, best ->
      theme = load(file)

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

  @doc "The radius or text scale in pixels, Tailwind's defaults with the theme's declarations over them."
  @spec scale(t(), :radius | :text) :: scale()
  def scale(%__MODULE__{scales: scales}, kind), do: Map.get(scales, kind) || default_scale(kind)

  ## Reading

  # `seen` comes back out because it spans the whole walk: a stylesheet two
  # imports reach is read at the first, and reading it again at the second
  # would put its declarations over the ones read between them.
  defp read(file, seen, acc, from_package) do
    if MapSet.member?(seen, file) or MapSet.size(seen) > 64 do
      {acc, seen}
    else
      seen = MapSet.put(seen, file)
      acc = %{acc | files: acc.files ++ [file]}

      case File.read(file) do
        {:ok, css} -> read_css(css, file, seen, acc, from_package)
        {:error, _} -> {acc, seen}
      end
    end
  end

  defp read_css(css, file, seen, acc, from_package) do
    utilities = parse_utilities(css)

    acc = %{
      acc
      | utilities: MapSet.union(acc.utilities, MapSet.new(utilities, &elem(&1, 0))),
        utility_properties: merge_utilities(acc.utility_properties, utilities),
        classes: MapSet.union(acc.classes, parse_class_selectors(css))
    }

    dir = Path.dirname(file)

    # Imports come first in the cascade.
    {acc, seen} =
      Enum.reduce(parse_imports(css), {acc, seen}, fn spec, {acc, seen} ->
        acc =
          if spec == "tailwindcss" or String.starts_with?(spec, "tailwindcss/"),
            do: %{acc | tailwind: true},
            else: acc

        case resolve_stylesheet(dir, spec) do
          nil ->
            {%{acc | missing_imports: acc.missing_imports ++ [spec]}, seen}

          target ->
            read(target, seen, acc, from_package or package_file?(target))
        end
      end)

    # Every declaration anywhere, dark mode included, for variable checks.
    acc = %{acc | variables: MapSet.union(acc.variables, all_variable_names(css))}

    if from_package do
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
    Enum.reduce(new, utilities, fn {name, _properties} = utility, utilities ->
      if List.keymember?(utilities, name, 0),
        do: List.keyreplace(utilities, name, 0, utility),
        else: utilities ++ [utility]
    end)
  end

  defp finalize(%__MODULE__{} = theme) do
    {tokens, scoped} = apply_token_declarations(theme.declarations, MapSet.new(), %{})
    theme = %{theme | tokens: tokens, scoped: scoped}

    %{
      theme
      | colors: colors_of(theme),
        scales: %{radius: build_scale(theme, :radius), text: build_scale(theme, :text)},
        spacing: spacing_of(theme)
    }
  end

  defp package_file?(file), do: String.contains?(file, "/node_modules/")

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

  defp strip(<<c::utf8, rest::binary>>, quote, acc), do: strip(rest, quote, [<<c::utf8>> | acc])

  defp take_string("", _q, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_string(<<?\\, c::utf8, rest::binary>>, q, acc),
    do: take_string(rest, q, [<<c::utf8>>, "\\" | acc])

  defp take_string(<<q, rest::binary>>, q, acc),
    do: {[q | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string(<<c::utf8, rest::binary>>, q, acc),
    do: take_string(rest, q, [<<c::utf8>> | acc])

  @doc false
  def parse_imports(css) do
    ~r/@import\s+(?:url\(\s*)?["']([^"']+)["']\s*\)?[^;]*;/
    |> Regex.scan(strip_comments(css), capture: :all_but_first)
    |> List.flatten()
  end

  @doc false
  # Each @utility in source order, with the properties its body sets.
  def parse_utilities(css) do
    stripped = strip_comments(css)

    utilities =
      ~r/@utility\s+([\w-]+\*?)\s*\{/
      |> Regex.scan(stripped, return: :index)
      |> Enum.map(fn [{start, length}, {name_start, name_length}] ->
        {binary_part(stripped, name_start, name_length),
         declared_properties(stripped, start + length)}
      end)

    merge_utilities([], utilities)
  end

  # The properties an @utility body sets, from just inside its brace to the
  # matching close, nesting included: a declaration follows a brace or a
  # semicolon, which neither a selector like &:hover nor an at-rule prelude
  # does. Custom properties stay in: a body that sets --tw-shadow-color is
  # as much a color as one that sets box-shadow.
  defp declared_properties(css, start) do
    rest = binary_part(css, start, byte_size(css) - start)

    ~r/(?:^|[;{}])\s*(-{0,2}[a-zA-Z][\w-]*)\s*:/
    |> Regex.scan(utility_body(rest, 1, 0), capture: :all_but_first)
    |> Enum.map(fn [name] -> String.downcase(name) end)
    |> Enum.uniq()
  end

  # An unclosed body runs to the end of the file.
  defp utility_body(css, depth, length) when depth == 0 or length == byte_size(css) do
    binary_part(css, 0, if(depth == 0, do: length - 1, else: length))
  end

  defp utility_body(css, depth, length) do
    case :binary.at(css, length) do
      ?{ -> utility_body(css, depth + 1, length + 1)
      ?} -> utility_body(css, depth - 1, length + 1)
      _ -> utility_body(css, depth, length + 1)
    end
  end

  @doc false
  # A class that exists in CSS (.legacy-card) is not an unknown class. A
  # "dist/*.js" in a string is a glob, not a .js selector.
  def parse_class_selectors(css) do
    stripped =
      css
      |> strip_comments()
      |> String.replace(~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, ~s(""))

    ~r/\.(-?[_a-zA-Z][\w-]*)/
    |> Regex.scan(stripped, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

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
            case Regex.run(~r/^\s*--((?:[\w-]+\*?)|\*)\s*:\s*([\s\S]+?)\s*$/, statement) do
              [_, name, value] when scope == nil or not scope.dark ->
                theme = scope != nil and scope.theme

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

  @doc false
  # Resolves var() references against `values`; nil when a variable has no
  # value and no fallback.
  def resolve_variables(value, values, depth \\ 0) do
    cond do
      not String.contains?(value, "var(") ->
        value

      depth > 6 ->
        nil

      true ->
        pattern = ~r/var\(\s*--([\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\)[^()]*)*))?\)/

        {out, failed} =
          pattern
          |> Regex.scan(value, return: :index)
          |> Enum.reverse()
          |> Enum.reduce({value, false}, fn [{start, len} | groups], {text, failed} ->
            [name | rest] =
              Enum.map(groups, fn {s, l} -> if s >= 0, do: binary_part(value, s, l) end)

            fallback = List.first(rest)
            inner = Map.get(values, name, fallback)

            {replacement, failed} =
              case inner do
                nil ->
                  {"", true}

                inner ->
                  case resolve_variables(String.trim(inner), values, depth + 1) do
                    nil -> {"", true}
                    resolved -> {resolved, failed}
                  end
              end

            {binary_part(text, 0, start) <>
               replacement <> binary_part(text, start + len, byte_size(text) - start - len),
             failed}
          end)

        if failed, do: nil, else: out
    end
  end

  defp colors_of(theme) do
    for token <- theme.tokens,
        raw = Map.get(theme.values, "color-" <> token),
        raw != nil,
        resolved = resolve_variables(raw, theme.values),
        resolved != nil,
        lab = Colors.parse(resolved),
        lab != nil,
        into: %{},
        do: {token, lab}
  end

  defp default_scale(kind) do
    defaults = if kind == :radius, do: TailwindTheme.radii(), else: TailwindTheme.font_sizes()

    # Tailwind declares its defaults smallest first.
    for({name, value} <- defaults, px = Lengths.px(value), px != nil, do: {name, px})
    |> List.keysort(1)
  end

  @doc false
  def default_scales, do: %{radius: default_scale(:radius), text: default_scale(:text)}

  # The theme's own --radius-* / --text-* declarations over Tailwind's
  # defaults, in cascade order, the way Tailwind reads them.
  defp build_scale(theme, kind) do
    prefix = "#{kind}-"

    Enum.reduce(theme.declarations, default_scale(kind), fn
      %{theme: false}, scale ->
        scale

      %{name: "*", value: value}, scale ->
        if String.trim(value) == "initial", do: [], else: scale

      %{name: name, value: value}, scale ->
        if String.starts_with?(name, prefix) and not String.contains?(name, "--") do
          step = String.slice(name, String.length(prefix)..-1//1)
          reset = String.trim(value) == "initial"

          cond do
            step == "*" -> if reset, do: [], else: scale
            reset -> List.keydelete(scale, step, 0)
            true -> scale_step(scale, step, value, theme.values)
          end
        else
          scale
        end
    end)
  end

  defp scale_step(scale, step, value, values) do
    px =
      case resolve_variables(value, values) do
        nil -> nil
        resolved -> Lengths.px(resolved)
      end

    cond do
      px == nil -> List.keydelete(scale, step, 0)
      List.keymember?(scale, step, 0) -> List.keyreplace(scale, step, 0, {step, px})
      true -> scale ++ [{step, px}]
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

  @doc """
  Resolves an `@import` the way Tailwind's bundler does: relative paths,
  then packages under `node_modules` through their `style` export.
  """
  @spec resolve_stylesheet(String.t(), String.t()) :: String.t() | nil
  def resolve_stylesheet(base, "tailwindcss"),
    do: resolve_stylesheet(base, "tailwindcss/index.css")

  def resolve_stylesheet(base, id) do
    cond do
      Regex.match?(~r/^(?:https?:|data:)/, id) ->
        nil

      String.starts_with?(id, ".") or Path.type(id) == :absolute ->
        full = Path.expand(id, base)
        stylesheet_at(Path.dirname(full), Path.basename(full))

      true ->
        resolve_package(base, id)
    end
  end

  defp resolve_package(base, id) do
    with [_, name | subpath] <- Regex.run(~r/^(@[^\/]+\/[^\/]+|[^\/]+)(?:\/(.*))?$/, id),
         dir when dir != nil <- package_directory(base, name) do
      pkg = read_package_json(dir)
      exports = Map.get(pkg, "exports")
      subpath = List.first(subpath)

      if subpath not in [nil, ""] do
        case is_map(exports) && exported_style(exports, subpath) do
          target when is_binary(target) ->
            existing_file(Path.join(dir, target))

          _ ->
            full = Path.join(dir, subpath)
            stylesheet_at(Path.dirname(full), Path.basename(full))
        end
      else
        root =
          cond do
            is_binary(exports) -> exports
            is_map(exports) -> style_target(Map.get(exports, ".", exports))
            true -> nil
          end

        Enum.find_value([root, pkg["style"], pkg["main"]], fn
          target when is_binary(target) -> existing_file(Path.join(dir, target))
          _ -> nil
        end) || stylesheet_at(dir, "index")
      end
    else
      _ -> nil
    end
  end

  defp package_directory(base, name) do
    base
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take(32)
    |> Enum.uniq()
    |> Enum.find_value(fn dir ->
      candidate = Path.join([dir, "node_modules", name])
      if File.regular?(Path.join(candidate, "package.json")), do: candidate
    end)
  end

  defp read_package_json(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "package.json")),
         {:ok, json} when is_map(json) <- JSON.decode(text) do
      json
    else
      _ -> %{}
    end
  end

  defp style_target(entry) when is_binary(entry), do: entry

  defp style_target(entry) when is_map(entry),
    do: Enum.find_value(["style", "default"], &style_target(Map.get(entry, &1)))

  defp style_target(_), do: nil

  defp exported_style(exports, subpath) do
    case style_target(Map.get(exports, "./" <> subpath)) do
      nil ->
        exports
        |> Map.keys()
        |> Enum.filter(&(String.starts_with?(&1, "./") and String.contains?(&1, "*")))
        |> Enum.sort_by(&(-String.length(&1)))
        |> Enum.find_value(fn key ->
          [prefix, suffix] = key |> String.slice(2..-1//1) |> String.split("*", parts: 2)

          if String.length(subpath) >= String.length(prefix) + String.length(suffix) and
               String.starts_with?(subpath, prefix) and String.ends_with?(subpath, suffix) do
            case style_target(Map.get(exports, key)) do
              nil ->
                nil

              target ->
                captured =
                  String.slice(
                    subpath,
                    String.length(prefix),
                    String.length(subpath) - String.length(prefix) - String.length(suffix)
                  )

                String.replace(target, "*", captured, global: false)
            end
          end
        end)

      target ->
        target
    end
  end

  defp stylesheet_at(dir, name) do
    base = Path.join(dir, name)

    existing_file(base) || existing_file(base <> ".css") ||
      existing_file(Path.join(base, "index.css"))
  end

  defp existing_file(path), do: if(File.regular?(path), do: path)
end
