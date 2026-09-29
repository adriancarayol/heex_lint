defmodule HeexLint.Project.Source do
  @moduledoc """
  One parsed source file: its modules, function components and templates.
  """

  alias HeexLint.{Code, Template}
  alias HeexLint.Project.{Component, ModuleInfo}

  defstruct [:path, :contents, :ast, lines: {}, modules: [], templates: [], error: nil]

  @type t :: %__MODULE__{
          path: String.t(),
          contents: String.t(),
          ast: Macro.t() | nil,
          lines: tuple(),
          modules: [ModuleInfo.t()],
          templates: [Template.t()],
          error: String.t() | nil
        }

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Parses the file at `path` with `contents`.
  """
  @spec parse(String.t(), String.t()) :: t()
  def parse(path, contents) do
    source = %__MODULE__{
      path: path,
      contents: contents,
      lines: contents |> String.split(~r/\r?\n/) |> List.to_tuple()
    }

    case Path.extname(path) do
      ".heex" ->
        %{source | templates: [%Template{file: path, source: contents}]}

      ext when ext in [".ex", ".exs"] ->
        parse_elixir(source)

      _ ->
        source
    end
  end

  defp parse_elixir(source) do
    case Code.parse(source.contents, file: source.path) do
      {:ok, ast} ->
        modules = modules(ast, nil, source.path, [])
        templates = Enum.flat_map(modules, & &1.templates)
        %{source | ast: ast, modules: modules, templates: templates}

      {:error, {meta, message, token}} ->
        %{source | error: "#{source.path}:#{meta[:line]}: #{format_error(message)}#{token}"}
    end
  end

  defp format_error({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp format_error(message), do: message

  # Every defmodule, nested ones with their full names.
  defp modules({:defmodule, meta, [name_ast, [{_do, body}]]}, parent, path, acc) do
    case Code.alias_name(name_ast) do
      nil ->
        acc

      name ->
        name = if parent, do: "#{parent}.#{name}", else: name
        module = read_module(%ModuleInfo{name: name, file: path, line: meta[:line]}, body)

        body
        |> Code.statements()
        |> Enum.reduce([module | acc], &modules(&1, name, path, &2))
    end
  end

  defp modules({:__block__, _, statements}, parent, path, acc),
    do: Enum.reduce(statements, acc, &modules(&1, parent, path, &2))

  defp modules(_other, _parent, _path, acc), do: acc

  defp read_module(module, body) do
    {module, _pending} =
      body
      |> Code.statements()
      |> Enum.reduce({module, []}, &statement/2)

    %{module | imports: Enum.reverse(module.imports), uses: Enum.reverse(module.uses)}
  end

  # `pending` holds the attr and slot declarations waiting for their def.
  defp statement({:alias, _, [target | rest]}, {module, pending}) do
    {add_aliases(module, target, List.first(rest)), pending}
  end

  defp statement({:import, _, [target | _]}, {module, pending}) do
    case Code.alias_name(target) do
      nil ->
        {module, pending}

      name ->
        {%{module | imports: [ModuleInfo.expand_alias(module, name) | module.imports]}, pending}
    end
  end

  defp statement({:use, _, [target | rest]}, {module, pending}) do
    case Code.alias_name(target) do
      nil ->
        {module, pending}

      name ->
        arg =
          case rest do
            [atom | _] when is_atom(atom) and atom not in [nil, true, false] ->
              Atom.to_string(atom)

            _ ->
              nil
          end

        {%{module | uses: [{ModuleInfo.expand_alias(module, name), arg} | module.uses]}, pending}
    end
  end

  defp statement({:@, _, [{name, _, [value]}]}, {module, pending}) when is_atom(name) do
    attributes = Map.update(module.attributes, Atom.to_string(name), [value], &(&1 ++ [value]))
    {%{module | attributes: attributes}, pending}
  end

  defp statement({:attr, meta, [name | rest]}, {module, pending}) do
    case attr(name, rest, meta) do
      nil -> {module, pending}
      attr -> {module, pending ++ [{:attr, attr}]}
    end
  end

  defp statement({:slot, _meta, [name | rest]}, {module, pending}) do
    slot_attrs =
      rest
      |> Enum.flat_map(&Code.keyword/1)
      |> Keyword.get(:do)
      |> Code.statements()
      |> Enum.flat_map(fn
        {:attr, meta, [attr_name | attr_rest]} -> List.wrap(attr(attr_name, attr_rest, meta))
        _ -> []
      end)

    case Code.name(name) do
      nil -> {module, pending}
      slot_name -> {module, pending ++ [{:slot, %{name: slot_name, attrs: slot_attrs}}]}
    end
  end

  defp statement({:embed_templates, _, [pattern | _]}, {module, pending}) do
    case Code.string(pattern) do
      nil -> {module, pending}
      text -> {%{module | embed_templates: module.embed_templates ++ [text]}, []}
    end
  end

  defp statement({kind, meta, [head | rest]}, {module, pending}) when kind in @def_kinds do
    {call, guard} =
      case head do
        {:when, _, [call, guard]} -> {call, guard}
        call -> {call, nil}
      end

    case call do
      {name, _, args} when is_atom(name) ->
        args = if is_list(args), do: args, else: []
        body = rest |> Enum.flat_map(&Code.keyword/1) |> Keyword.get(:do)
        name = Atom.to_string(name)
        clause = %{kind: kind, args: args, guard: guard, body: body, line: meta[:line]}
        key = {name, length(args)}
        functions = Map.update(module.functions, key, [clause], &(&1 ++ [clause]))
        module = %{module | functions: functions}

        module =
          if kind in [:def, :defp], do: component(module, name, clause, pending), else: module

        {module, []}

      _ ->
        {module, []}
    end
  end

  defp statement(_other, acc), do: acc

  defp add_aliases(module, {{:., _, [base, :{}]}, _, children}, _opts) do
    case Code.alias_name(base) do
      nil ->
        module

      base ->
        base = ModuleInfo.expand_alias(module, base)

        Enum.reduce(children, module, fn child, acc ->
          case Code.alias_name(child) do
            nil -> acc
            name -> put_alias(acc, "#{base}.#{name}", nil)
          end
        end)
    end
  end

  defp add_aliases(module, target, opts) do
    case Code.alias_name(target) do
      nil ->
        module

      name ->
        as = opts |> Code.keyword() |> Keyword.get(:as) |> Code.alias_name()
        put_alias(module, ModuleInfo.expand_alias(module, name), as)
    end
  end

  defp put_alias(module, full, as) do
    short = as || full |> String.split(".") |> List.last()
    %{module | aliases: Map.put(module.aliases, short, full)}
  end

  defp attr(name, rest, meta) do
    with name when is_binary(name) <- Code.name(name) do
      {type, opts} =
        case rest do
          [type, opts | _] -> {type, Code.keyword(opts)}
          [type] -> {type, []}
          [] -> {nil, []}
        end

      %{
        name: name,
        type: type,
        values: opts |> Keyword.get(:values) |> Code.string_list(),
        default: Keyword.get(opts, :default, :none),
        global: type == :global,
        line: meta[:line]
      }
    end
  end

  # A def is a function component when attrs or slots precede it or its
  # body renders ~H. Every ~H in its body becomes a template.
  defp component(module, name, clause, pending) do
    arity = length(clause.args)
    templates = if clause.body, do: sigils(clause.body, module, name, clause), else: []

    existing = Map.get(module.components, name)

    if arity == 1 and (pending != [] or templates != [] or existing != nil) do
      component =
        existing ||
          %Component{module: module.name, name: name, file: module.file, line: clause.line}

      component = %{
        component
        | attrs: component.attrs ++ for({:attr, attr} <- pending, do: attr),
          slots: component.slots ++ for({:slot, slot} <- pending, do: slot),
          templates: component.templates ++ templates
      }

      %{
        module
        | components: Map.put(module.components, name, component),
          templates: module.templates ++ templates
      }
    else
      %{module | templates: module.templates ++ templates}
    end
  end

  defp sigils(body, module, name, clause) do
    {_, templates} =
      Macro.prewalk(body, [], fn
        {:sigil_H, meta, [{:<<>>, string_meta, [text]}, _modifiers]} = node, acc
        when is_binary(text) ->
          template = %{
            Template.from_sigil(module.file, text, meta, string_meta)
            | module: module.name,
              function: name,
              clause: clause
          }

          {node, [template | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(templates)
  end

  @doc "The text of line `n` (1-based), or an empty string."
  @spec line(t(), pos_integer()) :: String.t()
  def line(%__MODULE__{lines: lines}, n) when n >= 1 and n <= tuple_size(lines),
    do: elem(lines, n - 1)

  def line(_source, _n), do: ""
end
