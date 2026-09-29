defmodule HeexLint.Rules.NoRestyle do
  @moduledoc """
  Use component variants for appearance and `class` for the changes your
  policy allows. The error lists the component's variants or sizes and the
  file that defines them.

  Start with layout allowed: `no_restyle: {:error, allow: ["layout"]}`, and
  turn the rule off inside your component directory (an override) so
  components can style themselves.

      <.button class="mt-4 w-full">Save</.button>          allowed
      <.button class="p-4 bg-pink-500 rounded-full">Save</.button>
      "bg-pink-500" is not allowed on <.button>: <.button> owns its color. Use a variant: primary, secondary, danger...

  Variants and sizes come from the component's declarations:
  `attr :variant, values: ~w(primary secondary)` and `attr :size, values: ...`.
  Wrappers that forward `class` (or global attributes) to a design-system
  component get that component's contract and suggestions.

  ## Options

    * `:allow`, `:deny`, `:contracts` - what components accept. Contract
      patterns match the component's function name: `"^card_title$"`.
    * `:message` - a string, or a map of category keys (`layout`, `color`,
      `typography`, `spacing`, `shape`, `effects`, `motion`, `default`).
      Also `{{category}}`, `{{variants}}`, `{{sizes}}`, `{{wrapper}}`,
      `{{around}}` and `{{entries}}`.
  """

  @behaviour HeexLint.Rule

  alias HeexLint.{Policy, Rule, Theme}
  alias HeexLint.Policy.ConfigError
  alias HeexLint.Project.Component

  @not_allowed ~s|"{{className}}" is not allowed on <{{component}}>:|
  @owns "<{{component}}> owns its {{category}}."
  @owns_via_wrapper "<{{wrapper}}> forwards class to <{{component}}>, which owns its {{category}}."
  @new_variant_guard "only if the design explicitly calls for a treatment none of these provides."
  @spacing_sizes "Use a size ({{sizes}}), or {{around}} for space around it."
  @spacing_around "For space around it, use {{around}}."
  @spacing_new_size "Add a size in {{file}} only if the design explicitly calls for one."

  @messages %{
    appearance_class:
      "#{@not_allowed} #{@owns} Use one of its variants. Add a new variant only if the design explicitly calls for a treatment none of them provides.",
    appearance_class_with_variants:
      "#{@not_allowed} #{@owns} Use a variant: {{variants}}. Add a new variant in {{file}} #{@new_variant_guard}",
    appearance_class_no_variants:
      "#{@not_allowed} #{@owns} Add a variant in {{file}} only if the design explicitly calls for this treatment.",
    appearance_class_via_wrapper:
      ~s|"{{className}}" is not allowed on <{{wrapper}}>: #{@owns_via_wrapper} Use a variant{{variantsSuffix}}. Add a new variant {{where}} #{@new_variant_guard}|,
    denied_class: "#{@not_allowed} its contract denies {{entries}}.",
    layout_class:
      "#{@not_allowed} its contract allows {{entries}}. Use one of those, or put layout classes on a parent element.",
    layout_class_closed:
      "#{@not_allowed} its contract allows no classes. Put layout classes on a parent element instead.",
    unclassified_class:
      "#{@not_allowed} the grammar does not recognize it. Fix the spelling, or use a class Tailwind generates.",
    declared_class:
      "#{@not_allowed} your CSS declares it, and the grammar cannot tell what it changes. Use a variant, or put it on a parent element.",
    spacing_class_with_sizes: "#{@not_allowed} #{@owns} #{@spacing_sizes} #{@spacing_new_size}",
    spacing_class_no_sizes: "#{@not_allowed} #{@owns} #{@spacing_around}",
    spacing_class_via_wrapper_with_sizes:
      ~s|"{{className}}" is not allowed on <{{wrapper}}>: #{@owns_via_wrapper} #{@spacing_sizes} #{@spacing_new_size}|,
    spacing_class_via_wrapper_no_sizes:
      ~s|"{{className}}" is not allowed on <{{wrapper}}>: #{@owns_via_wrapper} #{@spacing_around}|
  }

  @impl true
  def name, do: :no_restyle

  @impl true
  def prepare(options, project) do
    {policy, warnings} = Policy.compile(options, project.theme, "no_restyle")
    {:ok, policy, warnings}
  rescue
    error in ConfigError -> {:error, error.message}
  end

  @impl true
  def check(file, policy, options) do
    project = file.project

    for site <- file.sites,
        site.kind == :class,
        site.component != nil,
        string <- site.strings,
        {token, position} <- Rule.tokens(string),
        (verdict = Policy.decide(policy, site.component, token)) != :ok do
      finding(site, token, position, verdict, policy, project, options, file)
    end
  end

  defp finding(
         site,
         token,
         position,
         {kind, entries, category, words},
         policy,
         project,
         options,
         file
       ) do
    component = site.component_ref
    where = Path.relative_to(component.file, project.root)
    variants = Component.variants(component)
    variant_names = if variants, do: Enum.join(variants, ", "), else: ""

    # Every finding carries the same slots, whatever the category, so a
    # contract's own words can interpolate any of them.
    data = %{
      "className" => token,
      "component" => Rule.display(site.component),
      "entries" => Enum.join(entries, " "),
      "category" => category,
      "variants" => variant_names,
      "wrapper" => Rule.display(site.wrapper),
      "file" => where
    }

    {id, data} =
      cond do
        kind == :denied ->
          {:denied_class, data}

        category == "unclassified" ->
          {if(Theme.declares_class?(project.theme, token),
             do: :declared_class,
             else: :unclassified_class
           ), data}

        category == "layout" ->
          {if(entries == [], do: :layout_class_closed, else: :layout_class), data}

        category == "spacing" ->
          sizes = Component.sizes(component)
          around = around(site, policy, project, token)

          id =
            case {site.wrapper != nil, sizes != nil} do
              {true, true} -> :spacing_class_via_wrapper_with_sizes
              {true, false} -> :spacing_class_via_wrapper_no_sizes
              {false, true} -> :spacing_class_with_sizes
              {false, false} -> :spacing_class_no_sizes
            end

          {id, Map.merge(data, %{"sizes" => Enum.join(sizes || [], ", "), "around" => around})}

        true ->
          id =
            cond do
              site.wrapper -> :appearance_class_via_wrapper
              variants -> :appearance_class_with_variants
              true -> :appearance_class_no_variants
            end

          suffix = if variant_names != "", do: ": " <> variant_names, else: ""
          {id, Map.merge(data, %{"variantsSuffix" => suffix, "where" => "in #{where}"})}
      end

    %{position: position, message: Rule.message(@messages[id], data, words, options, file)}
  end

  # Where space around a component goes, as a noun phrase, built only from
  # what this project's contracts actually allow.
  defp around(site, policy, project, token) do
    accepts = fn name -> Policy.decide(policy, name, token) == :ok end
    places = if Policy.decide(policy, site.component, "m-4") == :ok, do: ["margin here"], else: []
    container = enclosing_container(site, accepts)

    places =
      if container == nil or not container.direct do
        places ++
          [
            if(closed_parent(site, accepts),
              do: "gap on a plain wrapper around it",
              else: "gap on the parent"
            )
          ]
      else
        places
      end

    places = if container, do: places ++ ["spacing on <#{container.display}>"], else: places
    except = if container, do: [site.component, container.name], else: [site.component]
    primitives = Policy.primitives_for(policy, token, except, design_system_names(project))

    places =
      if primitives != [],
        do: places ++ [list_of(Enum.map(primitives, &"<#{Rule.display(&1)}>"))],
        else: places

    {rest, [last]} = Enum.split(places, -1)

    case rest do
      [] -> last
      [one] -> "#{one} or #{last}"
      many -> "#{Enum.join(many, ", ")}, or #{last}"
    end
  end

  defp enclosing_container(site, accepts) do
    site.parents
    |> Enum.with_index()
    |> Enum.find_value(fn {{element, resolution}, index} ->
      if resolution && accepts.(resolution.name) do
        %{
          name: resolution.name,
          display: HeexLint.Element.display_name(element),
          direct: index == 0
        }
      end
    end)
  end

  # A direct parent that does not accept the class: never send spacing there.
  defp closed_parent(site, accepts) do
    case site.parents do
      [{_element, resolution} | _] when resolution != nil -> not accepts.(resolution.name)
      _ -> false
    end
  end

  defp design_system_names(project) do
    for {name, module} <- project.modules,
        Map.get(project.ds, name, false),
        {component_name, _} <- module.components,
        uniq: true,
        do: component_name
  end

  # "row", "row and stack", "row, stack and box".
  defp list_of(names) when length(names) < 3, do: Enum.join(names, " and ")
  defp list_of(names), do: "#{Enum.join(Enum.drop(names, -1), ", ")} and #{List.last(names)}"
end
