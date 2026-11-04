defmodule HeexLint.Collector do
  @moduledoc """
  Reads the class (or style) strings an attribute value can produce, and
  the parts it cannot read.

  Tailwind only generates CSS for class text present in source, so text
  plus a short hop covers every class that can render; what the hop cannot
  read is reported as unresolved, never treated as empty. Ported in spirit
  from @shadcn/lint's `collectClassStrings` (MIT), for Elixir:

    * strings, `~w(...)`, lists, `&&`/`||`, `if`/`unless`/`case`/`cond`
    * interpolation and `<>`, where text glued to a runtime value is no
      class of its own and the value is unresolved
    * in a template, `@name` and `assigns.name` follow `assign(assigns, :name, ...)`
      in the rendering function, and so does a lookup on them; in a function
      component, the received `class` is the component's own input: accepted, with
      its authored default read
    * in function bodies, variables, module attributes, `assigns.name` as it came
      in, same-module functions, map lookups (`Map.fetch!(%{...}, key)`), and the
      configured merge and variant functions

  A route to a class follows 64 bindings; the next one is unresolved at the place
  that reads it. Each binding is read once per site, so a class reached through
  both branches of `if on, do: a, else: a` is one class and a chain of such
  branches stays linear. A read that stopped on its route is remembered with that
  route, since it could read more from another one, and what is read again is pushed
  once. A style has no such limit: its
  value is read however far away it is, and what a hole in it can hold is looked
  at for raw colors the same way.

  A style also keeps what its reads were called (`reads`), since which names count
  as a library's computed styles is a rule option, and sites are collected for
  every rule. `outside_names/2` is how the rule asks.

  `calls` says where the merge and variant functions it read with no hop are:
  those are this read's, and a call nothing read is a site of its own.
  """

  alias HeexLint.Code
  alias HeexLint.Project
  alias HeexLint.Project.{Component, ModuleInfo, Source}

  @no_reads %{within: %{}, at: %{}}

  # Past any real expression in a template, in bytes.
  @long_expression 4_096

  defstruct strings: [], unresolved: [], reads: @no_reads, calls: []

  @type item ::
          {:char, String.t(), {pos_integer(), pos_integer()}}
          | {:interp, {pos_integer(), pos_integer()}}

  @typedoc """
  A string the value can produce. `literal` locates its text in the file,
  for suggestions that rewrite it: nil when its source text differs from
  its value (escapes, heredocs, interpolation). A string of a style also
  says which read reached it (`read`).
  """
  @type string_value :: %{
          required(:value) => String.t(),
          required(:items) => [item()],
          required(:holes) => %{{pos_integer(), pos_integer()} => [String.t()]},
          required(:literal) =>
            %{file: String.t(), from: {pos_integer(), pos_integer()}, raw: String.t()} | nil,
          optional(:read) => term()
        }

  @typedoc """
  How a style value's reads hang together, as `outside_names/2` needs them: what
  each read went on to read and what it called that (`within`, from the value itself,
  `:value`, with nil where no name can exempt it, and one entry per spelling, as
  `@x` and `assigns.x` are one read), and which read reached each unresolved position
  under what name (`at`). Empty for a class.
  """
  @type reads :: %{
          within: %{term() => MapSet.t({term(), String.t() | nil})},
          at: %{{pos_integer(), pos_integer()} => MapSet.t({term(), String.t() | nil})}
        }

  @type t :: %__MODULE__{
          strings: [string_value()],
          unresolved: [{pos_integer(), pos_integer()}],
          reads: reads(),
          calls: [{pos_integer(), pos_integer()}]
        }

  # How many bindings a route to a class follows before the next one is
  # unreadable, the way a dynamic value is. No written chain of aliases is this
  # deep. A style has no limit, as @shadcn/lint's `check` and `carriesRawColor`
  # keep no route: only what is on the route stops it.
  @max_route 64

  # How many times a site may read a binding it has already read. Only reads
  # that stopped on their route are read again, and bindings that all read each
  # other can do that on every route there is. First reads do not count. A read cut
  # at the limit has a count of its own, as reading it again can find a class, so a
  # site's cycles do not cost it one; past its own count, one can still be lost.
  @max_rereads 4096

  @doc """
  Collects from an element attribute value.

  Options:

    * `:mode` - `:class` (default) or `:style`
    * `:merge_functions` / `:variant_functions` - helper names
    * `:bound` - the names the template binds there, from `bound_names/2`
  """
  @spec attribute(HeexLint.Element.value(), map(), keyword()) :: t()
  def attribute(value, context, opts \\ [])

  def attribute(nil, _context, _opts), do: %__MODULE__{}

  def attribute({:string, text, position}, context, _opts) do
    items = chars(text, position, context.template.indentation)
    literal = %{file: context.template.file, from: position, raw: text}
    %__MODULE__{strings: [%{value: text, items: items, literal: literal, holes: %{}}]}
  end

  def attribute({:expr, code, position}, context, opts) do
    case Code.parse(code) do
      {:ok, ast} ->
        context
        |> state(opts, expression_text(code, position, context), :template)
        |> visit(bound(ast, Keyword.get(opts, :bound, [])))
        |> result()

      {:error, _} ->
        %__MODULE__{unresolved: [position]}
    end
  end

  @doc """
  What a style value is left with when the reads called one of `names` are exempt,
  for `allow_dynamic_identifiers`. As in @shadcn/lint, such a read says nothing,
  and neither does what it went on to read, unless another route reaches that too.
  A read whose value is written out where it is bound has no name to be exempted by,
  so what it says still counts.
  """
  @spec outside_names(
          %{
            :strings => [string_value()],
            :unresolved => [{pos_integer(), pos_integer()}],
            :reads => reads(),
            optional(atom()) => term()
          },
          MapSet.t(String.t())
        ) :: {[string_value()], [{pos_integer(), pos_integer()}]}
  def outside_names(%{strings: strings, unresolved: unresolved, reads: reads}, names) do
    if MapSet.size(names) == 0 do
      {strings, unresolved}
    else
      live = live_reads([:value], MapSet.new([:value]), reads, names)

      {Enum.filter(strings, &MapSet.member?(live, Map.get(&1, :read, :value))),
       Enum.filter(unresolved, &position_live?(&1, reads, live, names))}
    end
  end

  defp live_reads([], live, _reads, _names), do: live

  defp live_reads([read | rest], live, reads, names) do
    next =
      for {inner, name} <- Map.get(reads.within, read, []),
          not MapSet.member?(live, inner),
          not MapSet.member?(names, name),
          do: inner

    live_reads(next ++ rest, Enum.into(next, live), reads, names)
  end

  # A position with no read behind it could not be parsed, so nothing names it.
  defp position_live?(position, reads, live, names) do
    case Map.get(reads.at, position) do
      nil ->
        true

      reached ->
        Enum.any?(reached, fn {read, name} ->
          MapSet.member?(live, read) and not MapSet.member?(names, name)
        end)
    end
  end

  @doc """
  The names the template binds at `element`: its own `:for`, and the `:for` and `:let`
  of `parents`. An element's own `:let` is for what is inside it.
  """
  @spec bound_names(HeexLint.Element.t(), [HeexLint.Element.t()]) :: [atom()]
  def bound_names(element, parents) do
    Enum.flat_map(element.attributes, &binder_names(&1, [":for"])) ++
      Enum.flat_map(parents, fn parent ->
        Enum.flat_map(parent.attributes, &binder_names(&1, [":for", ":let"]))
      end)
  end

  defp binder_names(%{name: name, value: {:expr, code, _position}}, names) do
    # A `:for` can have several generators, which only a list holds.
    with true <- name in names,
         {:ok, ast} <- Code.parse("[" <> code <> "]") do
      Enum.flat_map(ast, fn
        {:<-, _, [pattern, _from]} -> pattern_names(pattern)
        pattern -> if name == ":let", do: pattern_names(pattern), else: []
      end)
    else
      _ -> []
    end
  end

  defp binder_names(_attribute, _names), do: []

  @doc """
  The keys a root attribute sets when it spreads a readable map or keyword list
  onto the element: `{%{class: "p-4"}}`. Empty when it is not one.
  """
  @spec root_keys(HeexLint.Element.value()) :: [String.t()]
  def root_keys({:expr, code, _position}) do
    with {:ok, ast} <- Code.parse(code),
         pairs when is_list(pairs) <- root_pairs(ast) do
      for {key, _value} <- pairs, name = Code.name(key), uniq: true, do: name
    else
      _ -> []
    end
  end

  def root_keys(_value), do: []

  @doc """
  Collects `key` from a root attribute that spreads a readable map or keyword
  list onto the element: `{%{class: "p-4"}}`. Nil when the root is not one, or
  does not set `key`.
  """
  @spec root(HeexLint.Element.value(), String.t(), map(), keyword()) :: t() | nil
  def root({:expr, code, position}, key, context, opts) do
    with {:ok, ast} <- Code.parse(code),
         pairs when is_list(pairs) <- root_pairs(ast),
         {_key, value} <- Enum.find(pairs, fn {k, _v} -> Code.name(k) == key end) do
      context
      |> state(opts, expression_text(code, position, context), :template)
      |> visit(bound(value, Keyword.get(opts, :bound, [])))
      |> result()
    else
      _ -> nil
    end
  end

  def root(_value, _key, _context, _opts), do: nil

  defp root_pairs({:%{}, _, pairs}), do: pairs
  defp root_pairs(list) when is_list(list), do: if(Keyword.keyword?(list), do: list)
  defp root_pairs(_), do: nil

  @doc """
  Collects from Elixir code in the file itself, such as a merge-function
  call or an attr default. `clause` is the enclosing function clause, if any.
  """
  @spec expression(Macro.t(), map(), keyword()) :: t()
  def expression(ast, context, opts \\ []) do
    state = state(context, opts, file_text(context), :body)
    state |> visit(ast) |> result()
  end

  @doc """
  The string keys of the maps a merge-function call in Elixir code reads, as
  in `cn(["p-1", %{"bg-red-500" => on}])`. It follows the same branches,
  variables and hops as `expression/3`. Only `scan_all_strings` asks for them:
  no class site reads map keys yet.
  """
  @spec map_keys(Macro.t(), map(), keyword()) :: [string_value()]
  def map_keys(ast, context, opts \\ []) do
    state = %{state(context, opts, file_text(context), :body) | map_keys: []}
    Enum.reverse(visit(state, ast).map_keys)
  end

  @doc """
  The same keys for a merge-function call in a template expression. Only what
  the call reads from Elixir code counts, with an assign followed through
  every function of the template's module, as `mount/3` sets what `render/1`
  reads: the keys are reported where the code writes them. A map written in
  the template itself stays unread, as does what a function returns.
  """
  @spec template_map_keys(Macro.t(), HeexLint.Element.value(), map(), keyword()) ::
          [string_value()]
  def template_map_keys(call, {:expr, code, position}, context, opts \\ []) do
    text = expression_text(code, position, context)
    state = %{state(context, opts, text, :template) | map_keys: []}
    Enum.reverse(visit(state, call).map_keys)
  end

  @doc """
  Where the value of a quoted literal in a template expression starts, past its quote.
  """
  @spec template_literal_start(keyword(), HeexLint.Element.value(), map()) ::
          {pos_integer(), pos_integer()}
  def template_literal_start(meta, {:expr, _code, position}, context) do
    {line, column} =
      locator(position, context.template.indentation).(meta[:line], meta[:column])

    {line, column + 1}
  end

  @doc """
  Collects from a piece of a template expression, such as one literal the caller
  found by walking it, at its place in the template.
  """
  @spec template_expression(Macro.t(), HeexLint.Element.value(), map(), keyword()) :: t()
  def template_expression(ast, {:expr, code, position}, context, opts \\ []) do
    context
    |> state(opts, expression_text(code, position, context), :template)
    |> visit(ast)
    |> result()
  end

  @doc """
  Collects from the merge-function calls of a template expression, in source order,
  at their place in the template. A call in `read`, the places of those a site has
  read already, is skipped, and so is one a call before it read.
  """
  @spec template_calls([Macro.t()], HeexLint.Element.value(), MapSet.t(), map(), keyword()) ::
          [t()]
  def template_calls(calls, {:expr, code, position}, read, context, opts \\ []) do
    text = expression_text(code, position, context)

    {collected, _read} =
      Enum.flat_map_reduce(calls, read, fn {_callee, meta, _args} = call, read ->
        if MapSet.member?(read, text.locate.(meta[:line], meta[:column])) do
          {[], read}
        else
          collected = context |> state(opts, text, :template) |> visit(call) |> result()
          {[collected], Enum.into(collected.calls, read)}
        end
      end)

    collected
  end

  # Positions inside a `{...}` expression, as they are in the template's file.
  defp expression_text(code, position, context) when byte_size(code) < @long_expression,
    do: new_expression_text(code, position, context)

  # A caller reads an expression once per literal, and one this long is worth keeping.
  defp expression_text(code, position, context) do
    key = {__MODULE__, :expression_text, context.template.file, position}

    case Process.get(key) do
      nil ->
        text = new_expression_text(code, position, context)
        Process.put(key, text)
        text

      text ->
        text
    end
  end

  defp new_expression_text(code, position, context) do
    lines = code |> String.split("\n") |> List.to_tuple()

    %{
      lines: lines,
      non_ascii: Source.non_ascii_lines(lines),
      locate: locator(position, context.template.indentation),
      file: context.template.file
    }
  end

  # A hop into a function body reads the module's file. For an embedded .heex
  # template that is another file, so what it finds is reported at the call;
  # `origin` keeps the real positions for fixes, which name their own file.
  defp body_text(state, meta) do
    text = file_text(state.context)

    if text.file == state.context.source.path do
      text
    else
      call = locate(state, meta)
      Map.merge(text, %{locate: fn _line, _column -> call end, origin: text.locate})
    end
  end

  defp file_text(context) do
    source = module_source(context) || context.source

    %{
      lines: source.lines,
      non_ascii: source.non_ascii || Source.non_ascii_lines(source.lines),
      locate: fn line, column -> {line, column} end,
      file: source.path
    }
  end

  defp module_source(context) do
    case current_module(%{context: context}) do
      %ModuleInfo{file: file} -> Map.get(context.project.sources, file)
      nil -> nil
    end
  end

  defp state(context, opts, text, mode) do
    %{
      context: context,
      text: text,
      mode: mode,
      kind: Keyword.get(opts, :mode, :class),
      merge: MapSet.new(Keyword.get(opts, :merge_functions, [])),
      variant: MapSet.new(Keyword.get(opts, :variant_functions, [])),
      clause: context[:clause] || (context[:template] && context.template.clause),
      seen: MapSet.new(),
      depth: 0,
      visited: %{},
      stops: 0,
      cuts: 0,
      rereads: 0,
      recuts: 0,
      cut_reads: %{},
      touched: MapSet.new(),
      pushed: MapSet.new(),
      strings: [],
      unresolved: [],
      map_keys: nil,
      read: :value,
      reads: @no_reads,
      calls: [],
      naming: nil
    }
  end

  defp result(state) do
    %__MODULE__{
      strings: Enum.reverse(state.strings),
      unresolved: Enum.uniq(Enum.reverse(state.unresolved)),
      reads: state.reads,
      calls: state.calls
    }
  end

  ## Visiting

  defp visit(state, {:__block__, meta, [text]}) when is_binary(text),
    do: literal(state, text, meta)

  defp visit(state, {:<<>>, meta, parts}) when is_list(parts) do
    exprs = for {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]} <- parts, do: expr

    if meta[:delimiter] == "\"" do
      {items, _end} = scan(state.text, meta[:line], meta[:column] + 1)
      template(state, items, exprs, meta)
    else
      # Heredocs and sigils: static text at the string's position.
      text = parts |> Enum.filter(&is_binary/1) |> Enum.join()
      state = if exprs != [] and state.kind == :class, do: unresolved(state, meta), else: state
      push(state, text, chars(text, locate(state, meta), 0), nil)
    end
  end

  defp visit(state, {:sigil_w, meta, [{:<<>>, _, parts}, _modifiers]}) do
    text = parts |> Enum.filter(&is_binary/1) |> Enum.join(" ")
    {line, column} = locate(state, meta)
    push(state, text, chars(text, {line, column + 3}, 0), nil)
  end

  defp visit(state, {sigil, meta, [{:<<>>, _, parts}, _modifiers]})
       when sigil in [:sigil_s, :sigil_S] do
    text = parts |> Enum.filter(&is_binary/1) |> Enum.join()
    {line, column} = locate(state, meta)
    push(state, text, chars(text, {line, column + 3}, 0), nil)
  end

  defp visit(state, list) when is_list(list), do: Enum.reduce(list, state, &visit(&2, &1))

  defp visit(state, literal) when is_atom(literal) or is_number(literal), do: state

  defp visit(state, {op, _, [_condition, right]}) when op in [:&&, :and], do: visit(state, right)

  defp visit(state, {op, _, [left, right]}) when op in [:||, :or],
    do: state |> visit(left) |> visit(right)

  defp visit(state, {:<>, meta, [_left, _right]} = node) do
    operands = concat_operands(node)

    {items, exprs} =
      Enum.reduce(operands, {[], []}, fn
        {:__block__, lmeta, [text]}, {items, exprs} when is_binary(text) ->
          {items ++ string_items(state, text, lmeta), exprs}

        expr, {items, exprs} ->
          {items ++ [{:interp, locate(state, meta_of(expr) || meta)}], exprs ++ [expr]}
      end)

    template(state, items, exprs, meta)
  end

  defp visit(state, {op, _, [_condition, branches]})
       when op in [:if, :unless] and is_list(branches) do
    branches
    |> Code.keyword()
    |> Keyword.take([:do, :else])
    |> Keyword.values()
    |> then(&visit(state, &1))
  end

  defp visit(state, {:case, _, [_subject, [do: clauses]]}), do: visit_clauses(state, clauses)

  # The left of a `cond` clause is a condition, which binds nothing.
  defp visit(state, {:cond, _, [[do: clauses]]}) do
    Enum.reduce(List.wrap(clauses), state, fn
      {:->, _, [_condition, body]}, acc -> visit(acc, body)
      _, acc -> acc
    end)
  end

  defp visit(state, {:with, _, args}) when is_list(args) do
    opts = args |> List.last() |> Code.keyword()
    generators = for {:<-, _, [pattern, _from]} <- args, do: pattern
    state = visit(state, scoped(generators, Keyword.get(opts, :do)))
    visit_clauses(state, Keyword.get(opts, :else, []))
  end

  defp visit(state, {:__block__, _, [_ | _] = exprs}), do: visit(state, List.last(exprs))

  defp visit(state, {:|>, _meta, [left, {call, meta, args}]}) when is_list(args),
    do: visit(state, {call, meta, [left | args]})

  # @name: an assign in a template, a module attribute in code.
  defp visit(%{mode: :template} = state, {:@, meta, [{name, _, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: assign(state, Atom.to_string(name), meta, "@#{name}")

  defp visit(%{mode: :body} = state, {:@, meta, [{name, _, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: module_attribute(state, Atom.to_string(name), meta)

  # assigns.name, assigns[:name]
  defp visit(state, {{:., _, [{:assigns, _, ctx}, name]}, meta, []})
       when is_atom(ctx) and is_atom(name),
       do: assigns_read(state, Atom.to_string(name), meta)

  defp visit(state, {{:., _, [Access, :get]}, meta, [{:assigns, _, ctx}, name]})
       when is_atom(ctx) and is_atom(name),
       do: assigns_read(state, Atom.to_string(name), meta)

  # A name a loop or a clause binds holds what is only known at runtime.
  defp visit(state, {name, meta, :bound}) when is_atom(name),
    do: unresolved(state, meta, Atom.to_string(name))

  # A variable.
  defp visit(state, {name, meta, ctx}) when is_atom(name) and is_atom(ctx),
    do: variable(state, name, meta)

  # map[key], map.key
  defp visit(state, {{:., _, [Access, :get]}, meta, [map, key]}),
    do: lookup(state, map, key, nil, meta)

  defp visit(state, {{:., _, [map, key]}, meta, []} = node) when is_atom(key) do
    if match?({:__aliases__, _, _}, map),
      do: call(state, node),
      else: lookup(state, map, key, nil, meta)
  end

  defp visit(
         state,
         {{:., _, [{:__aliases__, _, [:Map]}, fun]}, meta, [{:assigns, _, ctx}, key | rest]}
       )
       when fun in [:get, :fetch!] and is_atom(ctx) and is_atom(key) do
    state = assigns_read(state, Atom.to_string(key), meta)
    if rest != [], do: visit(state, hd(rest)), else: state
  end

  defp visit(state, {{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, [map, key | rest]})
       when {mod, fun} in [{:Map, :get}, {:Map, :fetch!}, {:Keyword, :get}, {:Keyword, :fetch!}],
       do: lookup(state, map, key, List.first(rest), meta)

  defp visit(%{map_keys: keys, mode: :template} = state, {:%{}, _, _}) when is_list(keys),
    do: state

  defp visit(%{map_keys: keys} = state, {:%{}, _, entries}) when is_list(keys),
    do: map_entries(state, entries)

  defp visit(%{map_keys: keys} = state, {{:., _, [{:__aliases__, _, [:Map]}, :merge]}, _, args})
       when is_list(keys) and is_list(args),
       do: Enum.reduce(args, state, &visit(&2, &1))

  # `Map.put` keeps the map's keys and adds its own, which a template leaves unread,
  # as it does a map written there.
  defp visit(
         %{map_keys: keys} = state,
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [map, key, _value]}
       )
       when is_list(keys) do
    state = visit(state, map)
    if state.mode == :template, do: state, else: map_entries(state, [{key, nil}])
  end

  defp visit(state, {_, _, args} = node) when is_list(args), do: call(state, node)

  defp visit(state, node), do: unresolved(state, meta_of(node))

  defp visit_clauses(state, clauses) when is_list(clauses) do
    Enum.reduce(clauses, state, fn
      {:->, _, [patterns, body]}, acc -> visit(acc, scoped(patterns, body))
      _, acc -> acc
    end)
  end

  defp visit_clauses(state, _), do: state

  # `body` with the names `patterns` bind marked, so that they are not looked up in the
  # enclosing function. One the body binds again is the function's to answer for.
  defp scoped(patterns, body) do
    case pattern_names(patterns) do
      [] -> body
      names -> bound(body, names -- Map.keys(bindings(body)))
    end
  end

  defp pattern_names(patterns) do
    {_, names} =
      Macro.prewalk(patterns, [], fn
        {op, _, _}, acc when op in [:^, :@] -> {nil, acc}
        {:when, meta, args}, acc -> {{:__block__, meta, Enum.drop(args, -1)}, acc}
        {:_, _, ctx} = node, acc when is_atom(ctx) -> {node, acc}
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) -> {node, [name | acc]}
        node, acc -> {node, acc}
      end)

    names
  end

  defp bound(ast, []), do: ast
  defp bound({:@, _, _} = node, _names), do: node

  defp bound({name, meta, ctx} = node, names) when is_atom(name) and is_atom(ctx),
    do: if(name in names, do: {name, meta, :bound}, else: node)

  defp bound({form, meta, args}, names),
    do: {bound(form, names), meta, bound(args, names)}

  defp bound({left, right}, names), do: {bound(left, names), bound(right, names)}
  defp bound(list, names) when is_list(list), do: Enum.map(list, &bound(&1, names))
  defp bound(other, _names), do: other

  defp map_entries(state, [{:|, _, [map, entries]}]),
    do: state |> visit(map) |> map_entries(entries)

  defp map_entries(state, entries) do
    Enum.reduce(entries, state, fn
      {{:__block__, meta, [key]}, _value}, acc when is_binary(key) ->
        case literal(%{acc | strings: []}, key, meta) do
          %{strings: [string], pushed: pushed} ->
            %{acc | map_keys: [string | acc.map_keys], pushed: pushed}

          _pushed_already ->
            acc
        end

      _entry, acc ->
        acc
    end)
  end

  ## Strings

  defp literal(state, text, meta) do
    case meta[:delimiter] do
      "\"" ->
        {items, _end} = scan(state.text, meta[:line], meta[:column] + 1)
        {line, column} = origin(state, meta)
        # Escapes move classes between source and value; such a string
        # gets no suggestion rather than a wrong one.
        escaped = state.text |> line_from(meta[:line], meta[:column] + 1) |> escaped?()
        fixable = raw_text(items) == text and not String.contains?(text, "\n") and not escaped
        literal = if fixable, do: %{file: state.text.file, from: {line, column + 1}, raw: text}
        push(state, text, strip_interp(items), literal)

      _ ->
        push(state, text, chars(text, locate(state, meta), 0), nil)
    end
  end

  defp string_items(state, text, meta) do
    if meta[:delimiter] == "\"" do
      {items, _end} = scan(state.text, meta[:line], meta[:column] + 1)
      items
    else
      chars(text, locate(state, meta), 0)
    end
  end

  # A string with runtime parts: text glued to a runtime value is no class
  # of its own and leaves the value unresolved; a value standing alone is
  # read on its own. In a style, holes stay holes in the CSS text.
  # In a style, a hole is not unreadable: the CSS text around it still
  # names its properties. What the hole can hold is kept, so a raw color
  # laundered through a variable or lookup table is still seen, at any length,
  # as @shadcn/lint's `carriesRawColor` keeps no route. Every hole is filled on
  # its own, as what it reads belongs to it even when another hole read it first:
  # only how those reads ended goes back to the route, not what they visited.
  defp template(%{kind: :style} = state, items, exprs, _meta) do
    positions = for {:interp, position} <- items, do: position

    {holes, state} =
      positions
      |> Enum.zip(exprs)
      |> Enum.map_reduce(state, fn {position, expr}, acc ->
        inner =
          visit(%{acc | strings: [], unresolved: [], pushed: MapSet.new(), kind: :hole}, expr)

        {{position, Enum.map(inner.strings, & &1.value)},
         %{acc | stops: inner.stops, cuts: inner.cuts}}
      end)

    push(state, raw_text(items), items, nil, Map.new(holes))
  end

  defp template(state, items, exprs, meta) do
    tokens = items |> Enum.chunk_by(&whitespace?/1) |> Enum.reject(&whitespace?(hd(&1)))

    {state, _index, kept} =
      Enum.reduce(tokens, {state, 0, []}, fn token, {state, index, kept} ->
        interps = Enum.count(token, &match?({:interp, _}, &1))

        cond do
          interps == 0 ->
            {state, index, kept ++ [token]}

          interps == 1 and length(token) == 1 ->
            {nested(state, Enum.at(exprs, index)), index + 1, kept}

          true ->
            {unresolved(state, meta), index + interps, kept}
        end
      end)

    Enum.reduce(kept, state, fn token, acc -> push(acc, raw_text(token), token, nil) end)
  end

  defp nested(state, nil), do: state
  defp nested(state, expr), do: visit(state, expr)

  defp push(state, value, items, literal, holes \\ %{}) do
    string = %{value: value, items: items, literal: literal, holes: holes}
    string = if state.kind == :style, do: Map.put(string, :read, state.read), else: string

    # What a site reads again says the same thing again, as @shadcn/lint's `push` has it.
    if MapSet.member?(state.pushed, string),
      do: state,
      else: %{state | strings: [string | state.strings], pushed: MapSet.put(state.pushed, string)}
  end

  # `written` is what the code calls the unreadable value, if it names it.
  defp unresolved(state, meta, written \\ nil) do
    position = if meta, do: locate(state, meta), else: nil

    if position,
      do: reached(%{state | unresolved: [position | state.unresolved]}, position, written),
      else: state
  end

  ## What reads are called

  defp reached(%{kind: :style, reads: reads} = state, position, written) do
    entry = {state.read, written}
    at = Map.update(reads.at, position, MapSet.new([entry]), &MapSet.put(&1, entry))
    %{state | reads: %{reads | at: at}}
  end

  defp reached(state, _position, _written), do: state

  # What the next read is called, as `allow_dynamic_identifiers` spells it. A value
  # written out where it is bound can still be read, so no name exempts it, as
  # @shadcn/lint still checks an object literal.
  defp named(%{kind: :style} = state, written, values) do
    %{state | naming: if(not written_out?(values), do: written)}
  end

  defp named(state, _written, _values), do: state

  defp written_out?([{:__block__, _, [text]}]) when is_binary(text), do: true
  defp written_out?([{:<<>>, _, parts}]) when is_list(parts), do: true
  defp written_out?([{:<>, _, [_, _]}]), do: true
  defp written_out?([{:%{}, _, entries}]) when is_list(entries), do: true
  defp written_out?([{sigil, _, _}]) when sigil in [:sigil_s, :sigil_S, :sigil_w], do: true
  defp written_out?([list]) when is_list(list), do: true
  defp written_out?(_values), do: false

  defp link(%{kind: :style, reads: reads} = state, read) do
    route = {read, state.naming}
    within = Map.update(reads.within, state.read, MapSet.new([route]), &MapSet.put(&1, route))
    %{state | reads: %{reads | within: within}, naming: nil}
  end

  defp link(state, _read), do: state

  # `styles.popper`, which `styles[:popper]` and `Map.get(styles, :popper)` also
  # read. A path starts at a variable or `@name`, not at what a call returns.
  defp path_name(map, key) when is_atom(key) and key not in [nil, true, false] do
    if root = root_name(map), do: root <> "." <> Atom.to_string(key)
  end

  defp path_name(_map, _key), do: nil

  defp root_name({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: "@" <> Atom.to_string(name)

  defp root_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: Atom.to_string(name)
  defp root_name({{:., _, [map, key]}, _, []}), do: path_name(map, key)
  defp root_name({{:., _, [Access, :get]}, _, [map, key]}), do: path_name(map, key)

  # With a default it could be either, so a path through it has no name.
  defp root_name({{:., _, [{:__aliases__, _, [mod]}, fun]}, _, [map, key]})
       when {mod, fun} in [{:Map, :get}, {:Map, :fetch!}, {:Keyword, :get}, {:Keyword, :fetch!}],
       do: path_name(map, key)

  defp root_name(_other), do: nil

  # A function by its module as written. A local or imported call has no such name.
  defp function_name(callee) when is_atom(callee), do: nil
  defp function_name(callee), do: callee_name(callee)

  ## Names

  defp assign(%{map_keys: keys} = state, name, meta, _written) when is_list(keys),
    do: assign_in_module(state, name, meta)

  defp assign(state, name, meta, written) do
    key = {:assign, name}

    with false <- MapSet.member?(state.seen, key),
         [_ | _] = values <- assigned_values(state.clause, name) do
      state
      |> named(written, values)
      |> hop(key, meta, fn state ->
        state = %{state | mode: :body, text: body_text(state, meta)}
        Enum.reduce(values, state, &visit(&2, &1))
      end)
    else
      true -> stop(state)
      _ -> received(state, name, meta, written)
    end
  end

  # `@name` by another spelling in a template. In code it is what came in, as code
  # reads it to work out a new value: `assign(assigns, :class, [assigns.class, "p-2"])`.
  defp assigns_read(%{mode: :template} = state, name, meta),
    do: assign(state, name, meta, "assigns." <> name)

  defp assigns_read(state, name, meta), do: received(state, name, meta, "assigns." <> name)

  # What any function of the module assigns to `name`, each value read in its
  # own clause, and the defaults its components declare for it.
  defp assign_in_module(state, name, meta) do
    key = {:assign, name}

    with false <- MapSet.member?(state.seen, key),
         %ModuleInfo{} = module <- current_module(state) do
      assigned = Map.get(module_assigns(module), name, [])

      hop(state, key, meta, fn state ->
        state = %{state | mode: :body, text: body_text(state, meta)}

        Enum.reduce(assigned, state, fn {clause, value}, acc ->
          visit(%{acc | clause: clause}, value)
        end)
      end)
    else
      true -> stop(state)
      nil -> state
    end
  end

  # A prop the component received from its caller.
  defp received(%{map_keys: keys} = state, name, meta, _written) when is_list(keys),
    do: assign_in_module(state, name, meta)

  defp received(state, name, meta, written) do
    template = state.context[:template]

    cond do
      template && template.kind == :render ->
        unresolved(state, meta, written)

      forwarded?(state, name) ->
        # The incoming prop stays opaque; its default is authored here.
        case component_default(state, name) do
          nil -> state
          default -> read_default(state, name, default, meta)
        end

      true ->
        unresolved(state, meta, written)
    end
  end

  # A default that reads its own prop ends there. As in @shadcn/lint, a class
  # says nothing more about it and a whole style cannot be checked.
  defp read_default(state, name, default, meta) do
    key = {:default, name}

    cond do
      not MapSet.member?(state.seen, key) ->
        hop(state, key, meta, &visit(%{&1 | mode: :body, text: body_text(&1, meta)}, default))

      state.kind == :style ->
        state |> stop() |> unresolved(meta)

      true ->
        stop(state)
    end
  end

  defp forwarded?(%{kind: :style}, name), do: name == "style"
  defp forwarded?(_state, name), do: HeexLint.Sites.class_attribute?(name)

  defp component_default(state, name) do
    with %Component{} = component <- state.context[:component],
         %{default: default} when default not in [:none, nil] <- Component.attr(component, name) do
      default
    else
      _ -> nil
    end
  end

  defp variable(state, name, meta) do
    key = variable_key(state, name)
    written = Atom.to_string(name)

    cond do
      MapSet.member?(state.seen, key) ->
        state |> stop() |> unresolved(meta, written)

      prop = head_binding(state.clause, name) ->
        received(state, prop, meta, written)

      values = bound_values(state.clause, name) ->
        state
        |> named(written, values)
        |> hop(key, meta, fn state ->
          Enum.reduce(values, leave_template(state, meta), &visit(&2, &1))
        end)

      true ->
        unresolved(state, meta, written)
    end
  end

  # Two functions can each have their own `class`.
  defp variable_key(state, name), do: {:var, name, clause_id(state.clause)}

  defp clause_id(nil), do: nil
  defp clause_id(%{line: line, column: column}), do: {line, column}

  # A variable a template reads holds code of the enclosing function: its
  # positions are in the file and `@name` in it is a module attribute.
  defp leave_template(%{mode: :template} = state, meta),
    do: %{state | mode: :body, text: body_text(state, meta)}

  defp leave_template(state, _meta), do: state

  defp module_attribute(state, name, meta) do
    key = {:attribute, name}

    with false <- MapSet.member?(state.seen, key),
         %ModuleInfo{attributes: attributes} <- current_module(state),
         [_ | _] = values <- Map.get(attributes, name) do
      state
      |> named("@" <> name, values)
      |> hop(key, meta, fn state -> Enum.reduce(values, state, &visit(&2, &1)) end)
    else
      true -> state |> stop() |> unresolved(meta, "@" <> name)
      _ -> unresolved(state, meta, "@" <> name)
    end
  end

  # One step along a route: `key` is on it, or the several keys of a lookup
  # that went through aliases. `seen` holds what is on the route, and reaching
  # one of those again is a cycle. `visited` holds how the reads of this site
  # ended, and is another thing: reading `a` from both branches of
  # `if on, do: a, else: a` is no cycle, so the second read just adds nothing.
  #
  # A read that stopped says nothing about the binding's whole value: it was cut
  # at the end of its route (`cuts`) or at a binding on it (`stops`). The same
  # read is skipped only where it would stop the same way: on the same route, or
  # at the same distance from the limit with nothing it read on the route, and
  # skipping it passes that on to what is reading it. Without this, a branching chain
  # that never finishes a read, because it runs past the limit or ends in a cycle,
  # doubles with every link. A hole keeps no positions, and its first reads have read
  # all a later one could, so it never reads again. A prop's default takes no link:
  # it is the prop's own value, which the last link has reached.
  defp hop(state, key, meta, how \\ nil, fun) do
    keys = List.wrap(key)
    this = {keys, how, clause_id(state.clause), state.kind}
    ended = Map.get(state.visited, this, MapSet.new())
    name = state.naming
    state = link(state, this)

    cond do
      past_limit?(state, 0) and not match?({:default, _}, key) ->
        cut(state, meta)

      MapSet.member?(ended, :whole) ->
        state

      touched = same_cut(state, this) ->
        %{state | cuts: state.cuts + 1, touched: MapSet.union(state.touched, touched)}

      MapSet.member?(ended, state.seen) ->
        stop(state)

      MapSet.size(ended) == 0 ->
        read(state, this, keys, fun)

      state.kind == :hole ->
        stop(state)

      true ->
        count = if MapSet.member?(ended, :cut), do: :recuts, else: :rereads

        if Map.fetch!(state, count) >= @max_rereads,
          do: cut(state, meta, name),
          else: read(Map.update!(state, count, &(&1 + 1)), this, keys, fun)
    end
  end

  # What a read cut at this distance from the limit went on to read, if none of it is
  # on this route: it would be cut the same way.
  defp same_cut(state, this) do
    state.cut_reads
    |> Map.get({this, state.depth}, [])
    |> Enum.find(&MapSet.disjoint?(&1, state.seen))
  end

  defp read(state, this, keys, fun) do
    saved = Map.take(state, [:mode, :text, :clause, :seen, :depth, :read])

    inner =
      fun.(%{
        state
        | seen: Enum.into(keys, state.seen),
          depth: state.depth + length(keys),
          read: this,
          touched: if(state.kind == :class, do: MapSet.new(keys), else: state.touched)
      })

    ended =
      cond do
        inner.stops != state.stops -> state.seen
        inner.cuts != state.cuts -> :cut
        true -> :whole
      end

    cut_reads =
      if ended == :cut,
        do:
          Map.update(inner.cut_reads, {this, state.depth}, [inner.touched], &[inner.touched | &1]),
        else: inner.cut_reads

    # A read that finished can have nothing on any route that reaches it, or it would
    # have stopped there, so what is reading it need not keep what it read.
    touched =
      if ended == :whole, do: state.touched, else: MapSet.union(state.touched, inner.touched)

    visited = Map.update(inner.visited, this, MapSet.new([ended]), &MapSet.put(&1, ended))

    Map.merge(
      %{inner | visited: visited, cut_reads: cut_reads, touched: touched},
      saved
    )
  end

  defp past_limit?(%{kind: :class} = state, links), do: state.depth + links >= @max_route
  defp past_limit?(_state, _links), do: false

  defp stop(state), do: %{state | stops: state.stops + 1}

  defp cut(state, meta, written \\ nil),
    do: unresolved(%{state | cuts: state.cuts + 1}, meta, written)

  defp current_module(state) do
    module = state.context[:module] || (state.context[:template] && state.context.template.module)
    own_module(state.context[:source], Project.module(state.context.project, module))
  end

  # A project has one module of a name, so of two files that define it, the other reads
  # its own: its positions, variables and attributes are in that file.
  defp own_module(%Source{path: path, modules: modules}, %ModuleInfo{file: file} = module)
       when file != path,
       do: Enum.find(modules, module, &(&1.name == module.name))

  defp own_module(_source, module), do: module

  ## Calls

  # Standard library calls whose result is made of their list argument's
  # strings: Enum.join(["a", @b], " ") and friends.
  @passthrough %{
    "Enum.join" => 0,
    "Enum.filter" => 0,
    "Enum.reject" => 0,
    "Enum.uniq" => 0,
    "Enum.concat" => :all,
    "List.flatten" => 0,
    "List.wrap" => 0,
    "String.trim" => 0
  }

  defp call(state, {callee, meta, args} = node) do
    name = callee_name(callee)
    arity = length(args)

    cond do
      is_binary(name) and Map.has_key?(@passthrough, name) and args != [] ->
        case @passthrough[name] do
          :all -> Enum.reduce(args, state, &visit(&2, &1))
          index -> visit(state, Enum.at(args, index))
        end

      is_binary(name) and MapSet.member?(state.variant, name) ->
        Enum.reduce(args, read_call(state, meta), &visit_values(&2, &1))

      is_binary(name) and MapSet.member?(state.merge, name) ->
        Enum.reduce(args, read_call(state, meta), &visit(&2, &1))

      is_atom(callee) and local_function?(state, Atom.to_string(callee), arity) ->
        if state.mode == :template and is_list(state.map_keys),
          do: state,
          else: local_call(state, Atom.to_string(callee), arity, meta)

      true ->
        unresolved(state, meta_of(node), function_name(callee))
    end
  end

  # A call reached by a hop stays a site of its own, as in @shadcn/lint.
  defp read_call(%{depth: 0} = state, meta),
    do: %{state | calls: [locate(state, meta) | state.calls]}

  defp read_call(state, _meta), do: state

  defp callee_name(callee) when is_atom(callee), do: Atom.to_string(callee)

  defp callee_name({:., _, [{:__aliases__, _, _} = mod, fun]}) when is_atom(fun) do
    if name = Code.alias_name(mod), do: name <> "." <> Atom.to_string(fun)
  end

  defp callee_name(_), do: nil

  defp local_function?(state, name, arity) do
    case current_module(state) do
      %ModuleInfo{functions: functions} -> Map.has_key?(functions, {name, arity})
      nil -> false
    end
  end

  # One hop into a same-module function: what each clause returns.
  defp local_call(state, name, arity, meta) do
    key = {:fun, name, arity}

    if MapSet.member?(state.seen, key) do
      state |> stop() |> unresolved(meta)
    else
      clauses = current_module(state).functions[{name, arity}]

      hop(state, key, meta, fn state ->
        state = %{state | mode: :body, text: body_text(state, meta)}

        Enum.reduce(clauses, state, fn
          %{body: nil}, acc -> acc
          clause, acc -> visit(%{acc | clause: clause}, clause.body)
        end)
      end)
    end
  end

  # Variant configs carry classes as values: %{primary: "...", ghost: "..."}.
  defp visit_values(state, {:%{}, _, entries}),
    do: Enum.reduce(entries, state, &visit_entry(&2, &1))

  defp visit_values(state, list) when is_list(list) do
    if Keyword.keyword?(list),
      do: Enum.reduce(list, state, fn {_k, v}, acc -> visit_values(acc, v) end),
      else: Enum.reduce(list, state, &visit_values(&2, &1))
  end

  defp visit_values(state, node), do: visit(state, node)

  # %{base | a: "..."} has its entries and what is in its base. An entry that is
  # neither that nor a pair, such as `unquote_splicing(entries)`, is only code.
  defp visit_entry(state, {:|, _, [base, updates]}) do
    updates
    |> List.wrap()
    |> Enum.reduce(visit_values(state, base), &visit_entry(&2, &1))
  end

  defp visit_entry(state, {_key, value}), do: visit_values(state, value)
  defp visit_entry(state, entry), do: visit(state, entry)

  # A lookup reads the entry named by a literal key, or every entry when the
  # key is only known at runtime: the table is the set of classes it can pick.
  # A default is a value of its own, whatever the table is and whatever its path
  # is called, as both sides of `styles.popper ?? other` are in @shadcn/lint.
  defp lookup(state, map, key, default, meta) do
    written = path_name(map, key)
    key = literal_key(key)

    state =
      case table(state, map, []) do
        {:update, pairs, route, _base} when state.kind == :hole ->
          entries(state, Enum.map(pairs, &elem(&1, 1)), route, key, meta)

        {:update, _pairs, _route, _base} = update ->
          case update_entry(update, key) do
            {value, route} ->
              state |> named(written, [value]) |> entries([value], route, key, meta)

            unread ->
              unreadable(state, unread, meta, written)
          end

        # As in @shadcn/lint, a table reached through an assign answers only for a key
        # it writes. A computed key, a missing one, or a computed write after it is
        # unreadable and reads no entry.
        {pairs, [{:assign, _name} | _] = route} when state.kind != :hole ->
          case update_entry({pairs, route}, key) do
            {value, route} ->
              state |> named(written, [value]) |> entries([value], route, key, meta)

            unread ->
              unreadable(state, unread, meta, written)
          end

        # A hole reads every entry, whatever the key, as `carriesRawColor` does.
        {pairs, route} when state.kind == :hole ->
          entries(state, Enum.map(pairs, &elem(&1, 1)), route, key, meta)

        {pairs, route} ->
          entry = written_entry(pairs, key)

          values =
            case entry do
              {_, value} -> [value]
              _ -> Enum.map(pairs, &elem(&1, 1))
            end

          # A key the table does not have reads every entry, none of them its value.
          whole = if entry, do: values, else: []
          state |> named(written, whole) |> entries(values, route, key, meta)

        unread ->
          unreadable(state, unread, meta, written)
      end

    if default, do: visit(state, default), else: state
  end

  # A map keeps a key's last value, and `1` and `1.0` are two keys.
  defp written_entry(_pairs, nil), do: nil

  defp written_entry(pairs, key),
    do: pairs |> Enum.reverse() |> Enum.find(fn {written, _} -> written === key end)

  defp unreadable(state, nil, meta, written), do: unresolved(state, meta, written)

  defp unreadable(state, :stopped, meta, written),
    do: state |> stop() |> unresolved(meta, written)

  defp unreadable(state, :cut, meta, written), do: cut(state, meta, written)

  # `%{base | a: value}` is `{ ...base, a: value }` in @shadcn/lint. A key it writes has
  # that value, whatever the base is. Any other is the base's to answer. When it cannot,
  # because it is not a table or does not have the key, or the key is only known at
  # runtime, the read is unreadable and reads no entry. So it is when a computed key
  # is written after it, which could be the same key. An entry is read on the route to
  # the map that wrote it, so `%{base | b: base.a}` is no cycle. A hole reads as
  # `carriesRawColor` does: all the map itself writes, whatever the key, and no base.
  defp update_entry(_table, nil), do: nil

  defp update_entry({:update, pairs, route, base}, key) do
    case last_write(pairs, key) do
      {nil, _} -> nil
      {_, value} -> {value, route}
      nil -> update_entry(base, key)
    end
  end

  defp update_entry({pairs, route}, key) do
    case last_write(pairs, key) do
      {^key, value} -> {value, route}
      _ -> nil
    end
  end

  defp update_entry(unread, _key), do: unread

  defp last_write(pairs, key),
    do: pairs |> Enum.reverse() |> Enum.find(fn {written, _} -> written in [key, nil] end)

  defp entries(state, values, [], _key, _meta), do: Enum.reduce(values, state, &visit(&2, &1))

  # A table reached through names is on the route while its entries are read,
  # so `t = %{a: t[:a]}` stops, and each entry is one read of its own.
  defp entries(state, values, route, key, meta) do
    hop(state, route, meta, {:entry, key}, fn state ->
      Enum.reduce(values, leave_template(state, meta), &visit(&2, &1))
    end)
  end

  # The entries of a table and the names followed to reach it, nil when it is
  # not one, :stopped at a name already on the route, or :cut past its limit. A map
  # update has its own entries and route, and what its base is by these same answers.
  defp table(state, {:%{}, _, [{:|, _, [base, updates]}]}, route),
    do: {:update, literal_pairs(updates), route, table(state, base, route)}

  defp table(_state, {:%{}, _, pairs}, route), do: {literal_pairs(pairs), route}

  # A keyword list answers with a key's first value, where a map keeps its last.
  defp table(_state, list, route) when is_list(list) do
    if Keyword.keyword?(list),
      do: {list |> Enum.uniq_by(&elem(&1, 0)) |> literal_pairs(), route},
      else: nil
  end

  defp table(_state, {_name, _, :bound}, _route), do: nil

  defp table(state, {name, _, ctx}, route) when is_atom(name) and is_atom(ctx) do
    case bound_values(state.clause, name) do
      [value] -> alias_of(%{state | mode: :body}, variable_key(state, name), value, route)
      _ -> nil
    end
  end

  defp table(%{mode: :body} = state, {:@, _, [{name, _, ctx}]}, route)
       when is_atom(name) and is_atom(ctx) do
    with %ModuleInfo{attributes: attributes} <- current_module(state),
         [value] <- Map.get(attributes, Atom.to_string(name)) do
      alias_of(state, {:attribute, Atom.to_string(name)}, value, route)
    else
      _ -> nil
    end
  end

  # `@styles.popper` and `assigns.styles.popper`. What the assign holds is code of
  # the function that assigns it.
  defp table(%{mode: :template} = state, node, route) do
    with name when is_binary(name) <- assign_read(node),
         [value] <- table_assigned(state, name) do
      alias_of(%{state | mode: :body}, {:assign, name}, value, route)
    else
      _ -> nil
    end
  end

  defp table(_state, _other, _route), do: nil

  # As an assign does, map keys read from every function of the module.
  defp table_assigned(%{map_keys: nil} = state, name), do: assigned_values(state.clause, name)

  defp table_assigned(state, name) do
    case current_module(state) do
      %ModuleInfo{} = module ->
        for {%{}, value} <- Map.get(module_assigns(module), name, []), do: value

      nil ->
        []
    end
  end

  defp assign_read({:@, _, [{name, _, ctx}]}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp assign_read({{:., _, [{:assigns, _, ctx}, name]}, _, []})
       when is_atom(ctx) and is_atom(name),
       do: Atom.to_string(name)

  defp assign_read({{:., _, [Access, :get]}, _, [{:assigns, _, ctx}, name]})
       when is_atom(ctx) and is_atom(name),
       do: Atom.to_string(name)

  defp assign_read({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [{:assigns, _, ctx}, name]})
       when fun in [:get, :fetch!] and is_atom(ctx) and is_atom(name),
       do: Atom.to_string(name)

  defp assign_read(_other), do: nil

  defp alias_of(state, key, value, route) do
    cond do
      key in route or MapSet.member?(state.seen, key) -> :stopped
      past_limit?(state, length(route)) -> :cut
      true -> table(state, value, route ++ [key])
    end
  end

  defp literal_pairs(pairs) do
    Enum.map(pairs, fn
      {key, value} -> {literal_key(key), value}
      _ -> {nil, nil}
    end)
  end

  # What a key names, or nil for one only known at runtime. So `nil` as a key is wrapped,
  # and a key such as `1`, `-1`, `Foo` or `{:x, 1}` is compared without its position.
  defp literal_key(nil), do: {:literal, nil}
  defp literal_key(key) when is_atom(key), do: key
  defp literal_key({:__block__, _, [text]}) when is_binary(text), do: text

  defp literal_key(key) do
    key =
      Macro.postwalk(key, fn
        {:__block__, _, [inner]} -> inner
        {:-, _, [number]} when is_number(number) -> -number
        {:+, _, [number]} when is_number(number) -> number
        node -> Macro.update_meta(node, fn _meta -> [] end)
      end)

    if Macro.quoted_literal?(key), do: {:literal, key}
  end

  ## Bindings in a function clause

  # %{class: class} = assigns in a component's head binds a received prop.
  defp head_binding(nil, _name), do: nil

  defp head_binding(%{args: args}, name) do
    {_, found} =
      Macro.prewalk(args, nil, fn
        {:%{}, _, pairs} = node, nil ->
          found =
            Enum.find_value(pairs, fn
              {key, {^name, _, ctx}} when is_atom(key) and is_atom(ctx) -> Atom.to_string(key)
              _ -> nil
            end)

          {node, found}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # `name = value` anywhere in the clause body, every one of them. A route reads these
  # once per link and a function can be long, so each file's task indexes a clause
  # once. The clause does not keep the index: the project is in :persistent_term, which
  # copies without sharing, so a value there costs its size again, and once more for
  # each `=` around it.
  defp bound_values(nil, _name), do: nil

  defp bound_values(%{id: id, body: body}, name) do
    index = memo({__MODULE__, :bindings, id}, fn -> bindings(body) end)
    Map.get(index, name)
  end

  defp memo(key, fun) do
    case Process.get(key) do
      nil ->
        value = fun.()
        Process.put(key, value)
        value

      value ->
        value
    end
  end

  defp bindings(body) do
    {_, found} =
      Macro.prewalk(body, %{}, fn
        {:=, _, [{name, _, ctx}, value]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, Map.update(acc, name, [value], &[value | &1])}

        node, acc ->
          {node, acc}
      end)

    Map.new(found, fn {name, values} -> {name, Enum.reverse(values)} end)
  end

  # The values `assign(assigns, :name, value)` and friends give an assign. A read of
  # one in a template can come thousands of times in a module, so like the bindings
  # above these are indexed once per task, by clause and by module.
  defp assigned_values(nil, _name), do: []

  defp assigned_values(clause, name), do: Map.get(clause_assigns(clause), name, [])

  defp clause_assigns(%{id: id, body: body}),
    do: memo({__MODULE__, :assigns, id}, fn -> assignments(body) end)

  defp assignments(body) do
    {_, found} =
      Macro.prewalk(body, %{}, fn node, acc ->
        {node,
         node
         |> assignment()
         |> Enum.reduce(acc, fn {name, value}, acc ->
           Map.update(acc, Atom.to_string(name), [value], &[value | &1])
         end)}
      end)

    Map.new(found, fn {name, values} -> {name, Enum.reverse(values)} end)
  end

  # What any function of the module assigns to each name, each value with its clause,
  # and the defaults its components declare, with no clause.
  defp module_assigns(%ModuleInfo{} = module) do
    memo({__MODULE__, :module_assigns, module.id}, fn ->
      assigned =
        for clauses <- Map.values(module.functions),
            clause <- clauses,
            {name, values} <- clause_assigns(clause),
            value <- values,
            do: {name, {clause, value}}

      defaults =
        for component <- Map.values(module.components),
            %{name: name, default: default} <- Enum.uniq_by(component.attrs, & &1.name),
            default not in [:none, nil],
            do: {name, {nil, default}}

      Enum.group_by(assigned ++ defaults, &elem(&1, 0), &elem(&1, 1))
    end)
  end

  defp assignment({:|>, _, [_left, {fun, meta, args}]}) when is_list(args),
    do: assignment({fun, meta, [:piped | args]})

  defp assignment({{:., _, [{:__aliases__, _, [:Phoenix, :Component]}, fun]}, meta, args})
       when is_list(args),
       do: assignment({fun, meta, args})

  defp assignment({fun, _, [_assigns, key, value]})
       when fun in [:assign, :assign_new, :update] and is_atom(key) do
    if fun == :assign,
      do: [{key, value}],
      else: Enum.map(fn_bodies(value), &{key, &1})
  end

  defp assignment({:assign, _, [_assigns, {:%{}, _, pairs}]}), do: Code.keyword(pairs)
  defp assignment({:assign, _, [_assigns, pairs]}) when is_list(pairs), do: Code.keyword(pairs)

  defp assignment({:%{}, _, [{:|, _, [{:assigns, _, ctx}, pairs]}]}) when is_atom(ctx),
    do: Code.keyword(pairs)

  defp assignment({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [{:assigns, _, _}, key, value]})
       when is_atom(key),
       do: [{key, value}]

  defp assignment(_node), do: []

  defp fn_bodies({:fn, _, clauses}),
    do: for({:->, _, [args, body]} <- clauses, do: scoped(args, body))

  defp fn_bodies(_other), do: []

  defp concat_operands({:<>, _, [left, right]}),
    do: concat_operands(left) ++ concat_operands(right)

  defp concat_operands(other), do: [other]

  ## Positions

  defp meta_of({_, meta, _}) when is_list(meta), do: if(meta[:line], do: meta)
  defp meta_of(_), do: nil

  defp locate(state, meta), do: state.text.locate.(meta[:line] || 1, meta[:column] || 1)

  # Where `meta` is in `state.text.file`, even when findings are reported elsewhere.
  defp origin(state, meta),
    do: (state.text[:origin] || state.text.locate).(meta[:line] || 1, meta[:column] || 1)

  # Maps positions inside a `{...}` expression to positions in the file.
  defp locator({base_line, base_column}, indentation) do
    fn line, column ->
      if line == 1,
        do: {base_line, base_column + column - 1},
        else: {base_line + line - 1, column + indentation}
    end
  end

  @doc false
  # Characters of `text` with positions, following line breaks.
  def chars(text, {line, column}, indentation) do
    {items, _} =
      text
      |> String.graphemes()
      |> Enum.map_reduce({line, column}, fn
        "\n", {l, c} -> {{:char, "\n", {l, c}}, {l + 1, indentation + 1}}
        char, {l, c} -> {{:char, char, {l, c}}, {l, c + 1}}
      end)

    items
  end

  # Walks a double-quoted string's source from just after its opening quote,
  # so every character keeps its real position. Returns the items and the
  # position of the closing quote.
  defp scan(text, line, column), do: scan_string(text, cursor(text, line, column), [])

  # Where a walk is: what is left of the line, and its position.
  defp cursor(text, line, column), do: {line_from(text, line, column), line, column}

  # A line from a column on. Columns count graphemes, which on an ASCII line are bytes:
  # a line of a thousand strings is read a thousand times.
  defp line_from(text, line, column) do
    source = text_line(text, line)

    if MapSet.member?(text.non_ascii, line) do
      String.slice(source, (column - 1)..-1//1)
    else
      size = byte_size(source)
      skip = min(column - 1, size)
      binary_part(source, skip, size - skip)
    end
  end

  # Whether a string has an escape, from just after its opening quote.
  defp escaped?(<<"\\", _rest::binary>>), do: true
  defp escaped?(<<"\"", _rest::binary>>), do: false
  defp escaped?(<<_byte, rest::binary>>), do: escaped?(rest)
  defp escaped?(<<>>), do: false

  # The character at a cursor, its position and the cursor after it.
  defp next_char(%{lines: lines}, {_rest, line, _column}) when line > tuple_size(lines), do: nil

  defp next_char(text, {"", line, column}),
    do: {"\n", text.locate.(line, column), cursor(text, line + 1, 1)}

  defp next_char(text, {rest, line, column}) do
    {char, rest} = String.next_grapheme(rest)
    {char, text.locate.(line, column), {rest, line, column + 1}}
  end

  defp text_line(%{lines: lines}, n) when n >= 1 and n <= tuple_size(lines),
    do: elem(lines, n - 1)

  defp text_line(_text, _n), do: ""

  defp scan_string(text, cursor, acc) do
    case next_char(text, cursor) do
      nil ->
        {Enum.reverse(acc), nil}

      {"\"", position, _rest} ->
        {Enum.reverse(acc), position}

      {"\\", position, rest} ->
        case next_char(text, rest) do
          nil ->
            scan_string(text, rest, [{:char, "\\", position} | acc])

          {char, position, rest} ->
            scan_string(text, rest, [{:char, unescape(char), position} | acc])
        end

      {"#", position, rest} ->
        case next_char(text, rest) do
          {"{", _position, rest} ->
            scan_string(text, skip_interpolation(text, rest, 1), [{:interp, position} | acc])

          _ ->
            scan_string(text, rest, [{:char, "#", position} | acc])
        end

      {char, position, rest} ->
        scan_string(text, rest, [{:char, char, position} | acc])
    end
  end

  defp skip_interpolation(_text, cursor, 0), do: cursor

  defp skip_interpolation(text, cursor, depth) do
    case next_char(text, cursor) do
      nil -> cursor
      {"{", _position, rest} -> skip_interpolation(text, rest, depth + 1)
      {"}", _position, rest} -> skip_interpolation(text, rest, depth - 1)
      {"\"", _position, rest} -> skip_interpolation(text, skip_quoted(text, rest), depth)
      {_char, _position, rest} -> skip_interpolation(text, rest, depth)
    end
  end

  defp skip_quoted(text, cursor) do
    case next_char(text, cursor) do
      nil -> cursor
      {"\"", _position, rest} -> rest
      {"\\", _position, rest} -> skip_quoted(text, skip_escaped(text, rest))
      {_char, _position, rest} -> skip_quoted(text, rest)
    end
  end

  defp skip_escaped(text, cursor) do
    case next_char(text, cursor) do
      nil -> cursor
      {_char, _position, rest} -> rest
    end
  end

  defp unescape("n"), do: "\n"
  defp unescape("t"), do: "\t"
  defp unescape(char), do: char

  defp raw_text(items),
    do:
      Enum.map_join(items, fn
        {:char, c, _} -> c
        {:interp, _} -> "￼"
      end)

  defp strip_interp(items), do: Enum.filter(items, &match?({:char, _, _}, &1))

  defp whitespace?({:char, char, _}), do: String.trim(char) == ""
  defp whitespace?(_), do: false

  @doc """
  Splits a collected string into class tokens with their positions.
  """
  @spec tokens(string_value()) :: [{String.t(), {pos_integer(), pos_integer()}}]
  def tokens(%{items: items}) do
    items
    |> Enum.chunk_by(&whitespace?/1)
    |> Enum.reject(&whitespace?(hd(&1)))
    |> Enum.map(fn [{:char, _, position} | _] = token -> {raw_text(token), position} end)
  end
end
