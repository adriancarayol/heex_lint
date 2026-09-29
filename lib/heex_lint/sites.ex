defmodule HeexLint.Sites do
  @moduledoc """
  Finds every place a class or style enters a file and resolves each to
  the component it belongs to.

  A site is one attribute value (or one piece of Elixir code, such as a
  merge-function call or an `attr :class` default) with the strings it can
  produce, the parts that cannot be read, and the design-system component
  wearing the classes, directly or through a wrapper.
  """

  alias HeexLint.{Collector, Element, Project, Template}
  alias HeexLint.Project.{Component, Source}

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
    strings: [],
    unresolved: [],
    parents: []
  ]

  @type t :: %__MODULE__{}

  # class, className, input_class, classes, class:list...
  @class_attribute ~r/^(class:list|[^:]*class(name)?s?)$/i

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
      sites: template_sites ++ code_sites(project, source, opts),
      elements: parsed,
      errors: errors
    }
  end

  defp element_sites(project, source, template, element, by_index, opts) do
    resolved = resolution(project, template, element, by_index)
    component = component_of(project, template, element)
    parents = parents(element, by_index)

    context = %{
      project: project,
      source: source,
      template: template,
      component: owner_component(project, template)
    }

    element.attributes
    |> Enum.flat_map(fn
      # {%{class: ..., style: ...}}: a readable map spread onto the element.
      %{name: :root, value: value} ->
        for {key, kind} <- [{"class", :class}, {"style", :style}],
            collected = Collector.root(value, key, context, Keyword.put(opts, :mode, kind)),
            collected != nil,
            do: {key, kind, collected}

      attribute ->
        kind =
          cond do
            attribute.name == "style" -> :style
            class_attribute?(attribute.name) -> :class
            true -> nil
          end

        if kind,
          do: [
            {attribute.name, kind,
             Collector.attribute(attribute.value, context, Keyword.put(opts, :mode, kind))}
          ],
          else: []
    end)
    |> Enum.map(fn {name, kind, collected} ->
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
        strings: collected.strings,
        unresolved: collected.unresolved,
        parents: Enum.map(parents, &{&1, resolution(project, template, &1, by_index)})
      }
    end)
  end

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
  # classes, directly or through a wrapper. Classes on a slot belong to the
  # component the slot is passed to.
  @doc false
  def resolution(project, template, element, by_index) do
    element =
      if element.type == :slot,
        do: slot_owner(element, by_index),
        else: element

    with %Element{} <- element,
         %Component{} = component <- component_of(project, template, element) do
      cond do
        Project.design_system?(project, component) ->
          %{name: component.name, component: component, wrapper: nil}

        target = Project.wrapped(project, component) ->
          %{name: target.name, component: target, wrapper: component.name}

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

  # Merge-function calls in function bodies and class attr defaults.
  defp code_sites(project, source, opts) do
    merge = MapSet.new(Keyword.get(opts, :merge_functions, []))
    variant = MapSet.new(Keyword.get(opts, :variant_functions, []))
    helpers = MapSet.union(merge, variant)

    Enum.flat_map(source.modules, fn module ->
      calls =
        for {_key, clauses} <- module.functions,
            clause <- clauses,
            clause.body != nil,
            call <- helper_calls(clause.body, helpers),
            do: {clause, call}

      call_sites =
        Enum.map(calls, fn {clause, call} ->
          context = %{project: project, source: source, module: module.name, clause: clause}
          code_site(source, Collector.expression(call, context, opts))
        end)

      default_sites =
        for {_name, component} <- module.components,
            attr <- component.attrs,
            class_attribute?(attr.name),
            attr.default not in [:none, nil],
            do:
              code_site(
                source,
                Collector.expression(
                  attr.default,
                  %{project: project, source: source, module: module.name},
                  opts
                )
              )

      call_sites ++ default_sites
    end)
  end

  defp code_site(source, collected) do
    %__MODULE__{
      file: source.path,
      kind: :class,
      strings: collected.strings,
      unresolved: [],
      written: ""
    }
  end

  defp helper_calls(body, helpers) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {:sigil_H, _, _} = _node, acc ->
          # Templates are read through their elements.
          {nil, acc}

        {callee, _, args} = node, acc when is_list(args) ->
          if helper_name(callee) in helpers, do: {node, acc ++ [node]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp helper_name(callee) when is_atom(callee), do: Atom.to_string(callee)

  defp helper_name({:., _, [{:__aliases__, _, parts}, fun]}) when is_atom(fun),
    do: Enum.map_join(parts, ".", &to_string/1) <> "." <> Atom.to_string(fun)

  defp helper_name(_), do: nil
end
