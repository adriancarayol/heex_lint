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
    * in a template, `@name` follows `assign(assigns, :name, ...)` in the
      rendering function; in a function component, the received `class`
      is the component's own input: accepted, with its authored default read
    * in function bodies, variables, module attributes, `assigns.name`,
      same-module functions, map lookups (`Map.fetch!(%{...}, key)`), and
      the configured merge and variant functions
  """

  alias HeexLint.Code
  alias HeexLint.Project
  alias HeexLint.Project.{Component, ModuleInfo}

  defstruct strings: [], unresolved: []

  @type item ::
          {:char, String.t(), {pos_integer(), pos_integer()}}
          | {:interp, {pos_integer(), pos_integer()}}

  @typedoc """
  A string the value can produce. `literal` locates its text in the file,
  for suggestions that rewrite it: nil when its source text differs from
  its value (escapes, heredocs, interpolation).
  """
  @type string_value :: %{
          value: String.t(),
          items: [item()],
          literal:
            %{file: String.t(), from: {pos_integer(), pos_integer()}, raw: String.t()} | nil
        }

  @type t :: %__MODULE__{strings: [string_value()], unresolved: [{pos_integer(), pos_integer()}]}

  @max_depth 4

  @doc """
  Collects from an element attribute value.

  Options:

    * `:mode` - `:class` (default) or `:style`
    * `:merge_functions` / `:variant_functions` - helper names
  """
  @spec attribute(HeexLint.Element.value(), map(), keyword()) :: t()
  def attribute(value, context, opts \\ [])

  def attribute(nil, _context, _opts), do: %__MODULE__{}

  def attribute({:string, text, position}, context, _opts) do
    items = chars(text, position, context.template.indentation)
    literal = %{file: context.template.file, from: position, raw: text}
    %__MODULE__{strings: [%{value: text, items: items, literal: literal}]}
  end

  def attribute({:expr, code, position}, context, opts) do
    case Code.parse(code) do
      {:ok, ast} ->
        text = %{
          lines: code |> String.split("\n") |> List.to_tuple(),
          locate: locator(position, context.template.indentation),
          file: context.template.file
        }

        state = state(context, opts, text, :template)
        state |> visit(ast) |> result()

      {:error, _} ->
        %__MODULE__{unresolved: [position]}
    end
  end

  @doc """
  Collects from Elixir code in the file itself, such as a merge-function
  call or an attr default. `clause` is the enclosing function clause, if any.
  """
  @spec expression(Macro.t(), map(), keyword()) :: t()
  def expression(ast, context, opts \\ []) do
    state = state(context, opts, file_text(context), :body)
    state |> visit(ast) |> result()
  end

  defp file_text(context) do
    %{
      lines: context.source.lines,
      locate: fn line, column -> {line, column} end,
      file: context.source.path
    }
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
      strings: [],
      unresolved: []
    }
  end

  defp result(state) do
    %__MODULE__{
      strings: Enum.reverse(state.strings),
      unresolved: Enum.uniq(Enum.reverse(state.unresolved))
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
  defp visit(state, {:cond, _, [[do: clauses]]}), do: visit_clauses(state, clauses)

  defp visit(state, {:with, _, args}) when is_list(args) do
    opts = args |> List.last() |> Code.keyword()
    state = visit(state, Keyword.get(opts, :do))
    visit_clauses(state, Keyword.get(opts, :else, []))
  end

  defp visit(state, {:__block__, _, [_ | _] = exprs}), do: visit(state, List.last(exprs))

  defp visit(state, {:|>, _meta, [left, {call, meta, args}]}) when is_list(args),
    do: visit(state, {call, meta, [left | args]})

  # @name: an assign in a template, a module attribute in code.
  defp visit(%{mode: :template} = state, {:@, meta, [{name, _, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: assign(state, Atom.to_string(name), meta)

  defp visit(%{mode: :body} = state, {:@, meta, [{name, _, ctx}]})
       when is_atom(name) and is_atom(ctx),
       do: module_attribute(state, Atom.to_string(name), meta)

  # assigns.name, assigns[:name]
  defp visit(state, {{:., _, [{:assigns, _, ctx}, name]}, meta, []})
       when is_atom(ctx) and is_atom(name),
       do: received(state, Atom.to_string(name), meta)

  defp visit(state, {{:., _, [Access, :get]}, meta, [{:assigns, _, ctx}, name]})
       when is_atom(ctx) and is_atom(name),
       do: received(state, Atom.to_string(name), meta)

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
    state = received(state, Atom.to_string(key), meta)
    if rest != [], do: visit(state, hd(rest)), else: state
  end

  defp visit(state, {{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, [map, key | rest]})
       when {mod, fun} in [{:Map, :get}, {:Map, :fetch!}, {:Keyword, :get}, {:Keyword, :fetch!}],
       do: lookup(state, map, key, List.first(rest), meta)

  defp visit(state, {_, _, args} = node) when is_list(args), do: call(state, node)

  defp visit(state, node), do: unresolved(state, meta_of(node))

  defp visit_clauses(state, clauses) when is_list(clauses) do
    Enum.reduce(clauses, state, fn
      {:->, _, [_patterns, body]}, acc -> visit(acc, body)
      _, acc -> acc
    end)
  end

  defp visit_clauses(state, _), do: state

  ## Strings

  defp literal(state, text, meta) do
    case meta[:delimiter] do
      "\"" ->
        {items, _end} = scan(state.text, meta[:line], meta[:column] + 1)
        {line, column} = locate(state, meta)
        # Escapes move classes between source and value; such a string
        # gets no suggestion rather than a wrong one.
        source_line = text_line(state.text, meta[:line])
        escaped = String.contains?(String.slice(source_line, meta[:column]..-1//1), "\\")
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
  defp template(%{kind: :style} = state, items, _exprs, _meta) do
    push(state, raw_text(items), items, nil)
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

  defp push(state, value, items, literal) do
    %{state | strings: [%{value: value, items: items, literal: literal} | state.strings]}
  end

  defp unresolved(state, meta) do
    position = if meta, do: locate(state, meta), else: nil
    if position, do: %{state | unresolved: [position | state.unresolved]}, else: state
  end

  ## Names

  defp assign(state, name, meta) do
    key = {:assign, name}

    with false <- MapSet.member?(state.seen, key),
         [_ | _] = values <- assigned_values(state.clause, name) do
      hop(state, key, fn state ->
        state = %{state | mode: :body, text: file_text(state.context)}
        Enum.reduce(values, state, &visit(&2, &1))
      end)
    else
      true -> state
      _ -> received(state, name, meta)
    end
  end

  # A prop the component received from its caller.
  defp received(state, name, meta) do
    template = state.context[:template]

    cond do
      template && template.kind == :render ->
        unresolved(state, meta)

      forwarded?(state, name) ->
        # The incoming prop stays opaque; its default is authored here.
        case component_default(state, name) do
          nil ->
            state

          default ->
            hop(
              state,
              {:default, name},
              &visit(%{&1 | mode: :body, text: file_text(&1.context)}, default)
            )
        end

      true ->
        unresolved(state, meta)
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
    key = {:var, name}

    cond do
      MapSet.member?(state.seen, key) ->
        unresolved(state, meta)

      prop = head_binding(state.clause, name) ->
        received(state, prop, meta)

      values = bound_values(state.clause, name) ->
        hop(state, key, fn state -> Enum.reduce(values, state, &visit(&2, &1)) end)

      true ->
        unresolved(state, meta)
    end
  end

  defp module_attribute(state, name, meta) do
    key = {:attribute, name}

    with false <- MapSet.member?(state.seen, key),
         %ModuleInfo{attributes: attributes} <- current_module(state),
         [_ | _] = values <- Map.get(attributes, name) do
      hop(state, key, fn state -> Enum.reduce(values, state, &visit(&2, &1)) end)
    else
      _ -> unresolved(state, meta)
    end
  end

  defp hop(state, key, fun) do
    if state.depth >= @max_depth do
      state
    else
      saved = Map.take(state, [:mode, :text, :clause, :seen, :depth])
      state = %{state | seen: MapSet.put(state.seen, key), depth: state.depth + 1}
      state = fun.(state)
      Map.merge(state, saved)
    end
  end

  defp current_module(state) do
    module = state.context[:module] || (state.context[:template] && state.context.template.module)
    Project.module(state.context.project, module)
  end

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
        Enum.reduce(args, state, &visit_values(&2, &1))

      is_binary(name) and MapSet.member?(state.merge, name) ->
        Enum.reduce(args, state, &visit(&2, &1))

      is_atom(callee) and local_function?(state, Atom.to_string(callee), arity) ->
        local_call(state, Atom.to_string(callee), arity, meta)

      true ->
        unresolved(state, meta_of(node))
    end
  end

  defp callee_name(callee) when is_atom(callee), do: Atom.to_string(callee)

  defp callee_name({:., _, [{:__aliases__, _, parts}, fun]}) when is_atom(fun),
    do: Enum.map_join(parts, ".", &to_string/1) <> "." <> Atom.to_string(fun)

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
      unresolved(state, meta)
    else
      clauses = current_module(state).functions[{name, arity}]

      hop(state, key, fn state ->
        state = %{state | mode: :body, text: file_text(state.context)}

        Enum.reduce(clauses, state, fn
          %{body: nil}, acc -> acc
          clause, acc -> visit(%{acc | clause: clause}, clause.body)
        end)
      end)
    end
  end

  # Variant configs carry classes as values: %{primary: "...", ghost: "..."}.
  defp visit_values(state, {:%{}, _, pairs}),
    do: Enum.reduce(pairs, state, fn {_k, v}, acc -> visit_values(acc, v) end)

  defp visit_values(state, list) when is_list(list) do
    if Keyword.keyword?(list),
      do: Enum.reduce(list, state, fn {_k, v}, acc -> visit_values(acc, v) end),
      else: Enum.reduce(list, state, &visit_values(&2, &1))
  end

  defp visit_values(state, node), do: visit(state, node)

  # A lookup reads the entry named by a literal key, or every entry when the
  # key is only known at runtime: the table is the set of classes it can pick.
  defp lookup(state, map, key, default, meta) do
    case table(state, map) do
      nil ->
        unresolved(state, meta)

      pairs ->
        key = literal_key(key)

        values =
          case key && List.keyfind(pairs, key, 0) do
            {_, value} -> [value]
            _ -> Enum.map(pairs, &elem(&1, 1))
          end

        state = Enum.reduce(values, state, &visit(&2, &1))
        if default, do: visit(state, default), else: state
    end
  end

  defp table(_state, {:%{}, _, pairs}), do: literal_pairs(pairs)

  defp table(_state, list) when is_list(list) do
    if Keyword.keyword?(list), do: literal_pairs(list), else: nil
  end

  defp table(state, {name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    case bound_values(state.clause, name) do
      [value] -> table(state, value)
      _ -> nil
    end
  end

  defp table(%{mode: :body} = state, {:@, _, [{name, _, ctx}]})
       when is_atom(name) and is_atom(ctx) do
    with %ModuleInfo{attributes: attributes} <- current_module(state),
         [value] <- Map.get(attributes, Atom.to_string(name)) do
      table(state, value)
    else
      _ -> nil
    end
  end

  defp table(_state, _other), do: nil

  defp literal_pairs(pairs) do
    Enum.map(pairs, fn
      {key, value} -> {literal_key(key), value}
      _ -> {nil, nil}
    end)
  end

  defp literal_key(key) when is_atom(key), do: key
  defp literal_key({:__block__, _, [text]}) when is_binary(text), do: text
  defp literal_key(_), do: nil

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

  # `name = value` anywhere in the clause body, every one of them.
  defp bound_values(nil, _name), do: nil

  defp bound_values(%{body: body}, name) do
    {_, values} =
      Macro.prewalk(body, [], fn
        {:=, _, [{^name, _, ctx}, value]} = node, acc when is_atom(ctx) -> {node, acc ++ [value]}
        node, acc -> {node, acc}
      end)

    if values == [], do: nil, else: values
  end

  # The values `assign(assigns, :name, value)` and friends give an assign.
  defp assigned_values(nil, _name), do: []

  defp assigned_values(%{body: body}, name) do
    atom = String.to_atom(name)

    {_, values} =
      Macro.prewalk(body, [], fn node, acc ->
        {node, acc ++ assignment(node, atom)}
      end)

    values
  end

  defp assignment({:|>, _, [_left, {fun, meta, args}]}, name) when is_list(args),
    do: assignment({fun, meta, [:piped | args]}, name)

  defp assignment({fun, _, [_assigns, key, value]}, name)
       when fun in [:assign, :assign_new, :update] do
    cond do
      key != name -> []
      fun == :assign -> [value]
      true -> fn_bodies(value)
    end
  end

  defp assignment({:assign, _, [_assigns, pairs]}, name) do
    case pairs do
      {:%{}, _, kv} -> kv |> Code.keyword() |> Keyword.get_values(name)
      kv when is_list(kv) -> kv |> Code.keyword() |> Keyword.get_values(name)
      _ -> []
    end
  end

  defp assignment(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [{:assigns, _, _}, name, value]},
         name
       ),
       do: [value]

  defp assignment(_node, _name), do: []

  defp fn_bodies({:fn, _, clauses}), do: for({:->, _, [_args, body]} <- clauses, do: body)
  defp fn_bodies(_other), do: []

  defp concat_operands({:<>, _, [left, right]}),
    do: concat_operands(left) ++ concat_operands(right)

  defp concat_operands(other), do: [other]

  ## Positions

  defp meta_of({_, meta, _}) when is_list(meta), do: if(meta[:line], do: meta)
  defp meta_of(_), do: nil

  defp locate(state, meta), do: state.text.locate.(meta[:line] || 1, meta[:column] || 1)

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
  defp scan(text, line, column) do
    stream =
      Stream.unfold({line, column}, fn {l, c} ->
        source = text_line(text, l)

        cond do
          l > tuple_size(text.lines) -> nil
          c > String.length(source) -> {{"\n", text.locate.(l, c)}, {l + 1, 1}}
          true -> {{String.at(source, c - 1), text.locate.(l, c)}, {l, c + 1}}
        end
      end)

    scan_string(stream, [])
  end

  defp text_line(%{lines: lines}, n) when n >= 1 and n <= tuple_size(lines),
    do: elem(lines, n - 1)

  defp text_line(_text, _n), do: ""

  defp scan_string(stream, acc) do
    case Enum.take(stream, 2) do
      [] ->
        {Enum.reverse(acc), nil}

      [{"\"", position} | _] ->
        {Enum.reverse(acc), position}

      [{"\\", _}, {char, position}] ->
        scan_string(Stream.drop(stream, 2), [{:char, unescape(char), position} | acc])

      [{"#", position}, {"{", _}] ->
        rest = skip_interpolation(Stream.drop(stream, 2), 1)
        scan_string(rest, [{:interp, position} | acc])

      [{char, position} | _] ->
        scan_string(Stream.drop(stream, 1), [{:char, char, position} | acc])
    end
  end

  defp skip_interpolation(stream, 0), do: stream

  defp skip_interpolation(stream, depth) do
    case Enum.take(stream, 1) do
      [] -> stream
      [{"{", _}] -> skip_interpolation(Stream.drop(stream, 1), depth + 1)
      [{"}", _}] -> skip_interpolation(Stream.drop(stream, 1), depth - 1)
      [{"\"", _}] -> stream |> Stream.drop(1) |> skip_quoted() |> skip_interpolation(depth)
      _ -> skip_interpolation(Stream.drop(stream, 1), depth)
    end
  end

  defp skip_quoted(stream) do
    case Enum.take(stream, 2) do
      [] -> stream
      [{"\\", _}, _] -> skip_quoted(Stream.drop(stream, 2))
      [{"\"", _} | _] -> Stream.drop(stream, 1)
      _ -> skip_quoted(Stream.drop(stream, 1))
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
