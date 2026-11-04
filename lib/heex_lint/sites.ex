defmodule HeexLint.Sites do
  @moduledoc """
  Finds every place a class or style enters a file and resolves each to
  the component it belongs to.

  A site is one attribute value, or one merge-function call or `attr :class`
  default read for itself, with the strings it can produce, the parts that
  cannot be read, and the design-system component wearing the classes, directly
  or through a wrapper. A style's `reads` say what those were called, for
  `HeexLint.Collector.outside_names/2`.
  """

  alias HeexLint.{Code, Collector, Element, Project, Template}
  alias HeexLint.Project.{Component, Source}

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  defstruct [
    :file,
    :kind,
    :attribute,
    :element,
    :template,
    :component,
    :component_ref,
    :component_file,
    :written,
    :wrapper,
    :prop,
    :reads,
    strings: [],
    unresolved: [],
    calls: [],
    parents: []
  ]

  @type t :: %__MODULE__{}

  # class, className, input_class, classNames, class:list... but a data-* or
  # aria-* attribute is never a class list: `data-class` is a selector hook.
  @class_attribute ~r/^(class:list|(?!data-|aria-)[^:]*class(name)?s?)$/i

  @doc "Whether an attribute name carries classes."
  @spec class_attribute?(String.t()) :: boolean()
  def class_attribute?(name) when is_binary(name), do: Regex.match?(@class_attribute, name)
  def class_attribute?(_), do: false

  @doc """
  The sites of `source`, with elements parsed from its templates. Returns
  `{sites, elements_by_template, errors}`.
  """
  @spec collect(Project.t(), Source.t(), keyword()) :: %{
          sites: [t()],
          elements: [{Template.t(), [Element.t()]}],
          errors: [String.t()]
        }
  def collect(project, %Source{} = source, opts \\ []) do
    {parsed, errors} =
      Enum.reduce(source.templates, {[], []}, fn template, {parsed, errors} ->
        case Template.elements(template) do
          {:ok, elements} -> {parsed ++ [{template, elements}], errors}
          {:error, message} -> {parsed, errors ++ [message]}
        end
      end)

    template_sites =
      Enum.flat_map(parsed, fn {template, elements} ->
        by_index = elements |> Enum.map(&{&1.index, &1}) |> Map.new()
        Enum.flat_map(elements, &element_sites(project, source, template, &1, by_index, opts))
      end)

    %{
      sites:
        template_sites ++
          template_call_sites(project, source, parsed, template_sites, opts) ++
          code_sites(project, source, opts),
      elements: parsed,
      errors: errors
    }
  end

  defp element_sites(project, source, template, element, by_index, opts) do
    component = component_of(project, template, element)
    parents = parents(element, by_index)

    context = template_context(project, source, template)

    element.attributes
    |> Enum.flat_map(fn
      # {%{class: ..., style: ...}}: a readable map spread onto the element.
      %{name: :root, value: value} ->
        for key <- Collector.root_keys(value),
            kind = attribute_kind(key),
            collected = Collector.root(value, key, context, Keyword.put(opts, :mode, kind)),
            collected != nil,
            do: {key, kind, collected}

      attribute ->
        kind = attribute_kind(attribute.name)

        if kind,
          do: [
            {attribute.name, kind,
             Collector.attribute(attribute.value, context, Keyword.put(opts, :mode, kind))}
          ],
          else: []
    end)
    |> Enum.map(fn {name, kind, collected} ->
      resolved = resolution(project, template, element, by_index, name)

      %__MODULE__{
        file: source.path,
        kind: kind,
        attribute: name,
        element: element,
        template: template,
        component: resolved && resolved.name,
        component_ref: resolved && resolved.component,
        component_file: resolved && resolved.component.file,
        written: written_name(element, component),
        wrapper: resolved && resolved.wrapper,
        prop: resolved && resolved.prop,
        strings: collected.strings,
        unresolved: collected.unresolved,
        reads: collected.reads,
        calls: collected.calls,
        parents: Enum.map(parents, &{&1, resolution(project, template, &1, by_index)})
      }
    end)
  end

  defp template_context(project, source, template) do
    %{
      project: project,
      source: source,
      template: template,
      component: owner_component(project, template)
    }
  end

  defp attribute_kind("style"), do: :style
  defp attribute_kind(name), do: if(class_attribute?(name), do: :class)

  # The component that defines the template, whose received props are
  # the template's inputs.
  defp owner_component(project, %Template{module: module, function: function}) do
    case Project.module(project, module) do
      nil -> nil
      info -> Map.get(info.components, function)
    end
  end

  defp component_of(project, template, element) do
    Project.resolve(project, template.module, element.type, element.name)
  end

  # The name a contract matches: the design-system component wearing the
  # classes, directly or through a wrapper. A wrapper is followed by the class
  # attribute set on it: its `title_class` goes wherever the wrapper hands that
  # prop, not where `class` goes. Classes on a slot belong to the component the
  # slot is passed to, whose props they are not, so its `class` decides.
  @doc false
  def resolution(project, template, element, by_index, attribute \\ "class") do
    {element, attribute} =
      if element.type == :slot,
        do: {slot_owner(element, by_index), "class"},
        else: {element, attribute}

    with %Element{} <- element,
         %Component{} = component <- component_of(project, template, element) do
      cond do
        Project.design_system?(project, component) ->
          %{name: component.name, component: component, wrapper: nil, prop: attribute}

        target = Project.wrapped(project, component, attribute) ->
          %{name: target.name, component: target, wrapper: component.name, prop: attribute}

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp slot_owner(element, by_index) do
    element
    |> parents(by_index)
    |> Enum.find(&(&1.type in [:local_component, :remote_component]))
  end

  defp parents(%Element{parent: nil}, _by_index), do: []

  defp parents(%Element{parent: index}, by_index) do
    case Map.get(by_index, index) do
      nil -> []
      parent -> [parent | parents(parent, by_index)]
    end
  end

  # As written: `button` for <.button>, `Layouts.app` for <Layouts.app>.
  defp written_name(%Element{type: :local_component, name: name}, _component), do: name
  defp written_name(%Element{type: :remote_component, name: name}, _component), do: name
  defp written_name(_element, _component), do: ""

  ## Code sites

  # A merge-function call in a template that no class site has read is a site of
  # its own, on no component: in another attribute, in text, in a condition, or
  # inside a call nothing follows. What a class site did read stays that site's.
  defp template_call_sites(project, source, parsed, template_sites, opts) do
    helpers = helpers(opts)
    names = Enum.map(helpers, &(&1 |> String.split(".") |> List.last()))

    read =
      for site <- template_sites,
          site.kind == :class,
          call <- site.calls,
          into: MapSet.new(),
          do: call

    for {template, _elements} <- parsed,
        # Finding the expressions tokenizes the template again.
        String.contains?(template.source, names),
        context = template_context(project, source, template),
        {:expr, code, _position} = expression <- Element.expressions(template),
        {:ok, ast} <- [Code.parse(code)],
        calls = helper_calls(ast, helpers),
        collected <- Collector.template_calls(calls, expression, read, context, opts),
        do: code_site(source, collected)
  end

  # Merge-function calls in Elixir code, wherever the file has them, and class attr
  # defaults. A call in a function can read that function's variables.
  defp code_sites(project, source, opts) do
    helpers = helpers(opts)
    site = fn call, context -> code_site(source, Collector.expression(call, context, opts)) end
    file = %{project: project, source: source}

    modules =
      source.modules
      |> Enum.zip(Source.module_bodies(source.ast))
      |> Enum.flat_map(fn {module, body} ->
        context = Map.put(file, :module, module.name)

        function_sites =
          for {_key, clauses} <- module.functions,
              clause <- clauses,
              clause.body != nil,
              call <- helper_calls(clause.body, helpers),
              do: site.(call, Map.put(context, :clause, clause))

        outside_sites =
          for call <- helpers_outside(body, module, helpers),
              do: site.(call, context)

        default_sites =
          for {_name, component} <- module.components,
              attr <- component.attrs,
              class_attribute?(attr.name),
              attr.default not in [:none, nil],
              do: site.(attr.default, context)

        function_sites ++ outside_sites ++ default_sites
      end)

    outside_modules =
      for call <- helper_calls(outside_functions(source.ast, %{}), helpers),
          do: site.(call, file)

    modules ++ outside_modules
  end

  defp helpers_outside(body, module, helpers),
    do: body |> outside_functions(module.functions) |> helper_calls(helpers)

  defp helpers(opts) do
    merge = MapSet.new(Keyword.get(opts, :merge_functions, []))
    variant = MapSet.new(Keyword.get(opts, :variant_functions, []))
    MapSet.union(merge, variant)
  end

  # Code without what is read on its own: the `do` of `functions`, and the modules
  # and implementations in it. What is left is a module attribute, a default argument, a module's or a
  # script's body, a function's `rescue` and the like, and a function a block
  # defines. A head is a pattern, as in `def cn(value)`, and no call, but for its
  # defaults.
  defp outside_functions(ast, functions) do
    read =
      for clauses <- Map.values(functions),
          clause <- clauses,
          into: MapSet.new(),
          do: {clause.line, clause.column}

    ast
    |> Code.statements()
    |> Enum.reject(&match?({kind, _, _} when kind in [:defmodule, :defimpl], &1))
    |> Macro.prewalk(fn
      {kind, meta, [head | body]} when kind in @def_kinds ->
        body = if {meta[:line], meta[:column]} in read, do: other_sections(body), else: body
        {kind, meta, [head_defaults(head) | body]}

      node ->
        node
    end)
  end

  # A clause's body is its `do`. Its `rescue`, `catch`, `else` and `after` are not.
  defp other_sections(body) do
    for sections <- body, is_list(sections) do
      Enum.reject(sections, &match?({:do, _}, &1))
    end
  end

  @doc false
  # The default arguments of a function head, which are code where the rest is a pattern.
  def head_defaults({:when, _, [head | _guard]}), do: head_defaults(head)

  def head_defaults({_name, _, args}) when is_list(args),
    do: for({:\\, _, [_pattern, default]} <- args, do: default)

  def head_defaults(_head), do: []

  defp code_site(source, collected) do
    %__MODULE__{
      file: source.path,
      kind: :class,
      strings: collected.strings,
      unresolved: [],
      written: ""
    }
  end

  defp helper_calls(ast, helpers) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:sigil_H, _, _} = _node, acc ->
          # Templates are read through their elements.
          {nil, acc}

        # "a" |> cn() is cn("a").
        {:|>, _, [left, {callee, meta, args}]}, acc when is_list(args) ->
          helper_call({callee, meta, [left | args]}, helpers, acc)

        # `@cn "a"` sets an attribute of that name, and what it holds can be a call.
        {:@, meta, [{name, _, args}]}, acc when is_atom(name) and is_list(args) ->
          {{:__block__, meta, args}, acc}

        {_callee, _, args} = node, acc when is_list(args) ->
          helper_call(node, helpers, acc)

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp helper_call({callee, _, _} = node, helpers, acc),
    do: {node, if(helper_name(callee) in helpers, do: [node | acc], else: acc)}

  @doc false
  # The name a call matches merge and variant functions by.
  def helper_name(callee) when is_atom(callee), do: Atom.to_string(callee)

  def helper_name({:., _, [{:__aliases__, _, _} = mod, fun]}) when is_atom(fun) do
    if name = Code.alias_name(mod), do: name <> "." <> Atom.to_string(fun)
  end

  def helper_name(_), do: nil
end
