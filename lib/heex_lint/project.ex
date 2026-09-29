defmodule HeexLint.Project do
  @moduledoc """
  Everything the rules read about a project: its sources, modules and
  function components, which components belong to the design system, and
  its Tailwind theme.

  A design-system component is a function component defined in one of the
  project's component modules: the modules under a `components` directory
  (Phoenix puts `CoreComponents` in `lib/my_app_web/components`), plus those
  the `ui` and `component_imports` settings name, minus those
  `ignore_imports` excludes.
  """

  alias HeexLint.{Code, Template, Theme}
  alias HeexLint.Project.{Component, ModuleInfo, Source}

  defstruct root: nil,
            settings: %{},
            theme: nil,
            theme_file: nil,
            entry: nil,
            sources: %{},
            modules: %{},
            imports: %{},
            ds: %{},
            wrappers: %{},
            oracle: nil,
            themes: %{},
            warnings: []

  @type t :: %__MODULE__{}

  # Phoenix.Component's own components, which are not the project's.
  @phoenix_components ~w(
    link live_component live_title live_file_input focus_wrap dynamic_tag form
    inputs_for intersperse async_result live_img_preview portal
  )

  @doc """
  Loads the project at `root` from the given source `files`.

  Settings (all optional):

    * `:theme` - the theme stylesheet; discovered when not set
    * `:ui` - module name prefixes of the design system, such as `"MyAppWeb.CoreComponents"`
    * `:component_imports` - regexes on module names that are also the design system
    * `:ignore_imports` - regexes on module names that never are
  """
  @spec load(String.t(), [String.t()], map() | keyword()) :: t()
  def load(root, files, settings \\ %{}) do
    root = Path.expand(root)
    settings = Map.new(settings)

    sources =
      files
      |> Task.async_stream(fn file -> {file, Source.parse(file, File.read!(file))} end,
        timeout: :infinity,
        ordered: true
      )
      |> Map.new(fn {:ok, pair} -> pair end)

    load_sources(root, sources, settings)
  end

  @doc false
  # Builds a project from already parsed sources (used by tests and editors).
  def load_sources(root, sources, settings) do
    modules =
      sources
      |> Map.values()
      |> Enum.flat_map(& &1.modules)
      |> Enum.reduce(%{}, fn module, acc -> Map.put_new(acc, module.name, module) end)

    modules = dependency_modules(root, modules)

    project = %__MODULE__{root: root, settings: settings, sources: sources, modules: modules}
    project = attach_heex(project)
    project = mark_render_templates(project)
    project = parse_templates(project)

    project = %{
      project
      | imports: Map.new(project.modules, fn {name, m} -> {name, effective(project, m)} end)
    }

    project = load_theme(project)
    recognize(project, settings)
  end

  @doc """
  The project with the design system recognized under `recognition`
  (`:ui`, `:component_imports`, `:ignore_imports`), for a rule whose own
  options differ from the shared settings.
  """
  @spec recognize(t(), map()) :: t()
  def recognize(project, recognition) do
    settings =
      Map.merge(
        project.settings,
        Map.take(Map.new(recognition), [:ui, :component_imports, :ignore_imports])
      )

    project = %{project | settings: settings}

    project = %{
      project
      | ds: Map.new(project.modules, fn {name, m} -> {name, ds_module?(project, m)} end)
    }

    %{project | wrappers: wrappers(project)}
  end

  ## Dependencies

  # Components you don't own: modules the project imports, uses or aliases
  # from its dependencies (SaladUI, PetalComponents...), read from deps/ so
  # their components and attrs resolve. Followed a few levels, since
  # `use SaladUI` imports more modules through its quote block.
  defp dependency_modules(root, modules) do
    deps = dependency_dirs(root)

    if deps == [] do
      modules
    else
      Enum.reduce_while(1..3, {modules, MapSet.new()}, fn _round, {modules, tried} ->
        missing =
          modules
          |> Map.values()
          |> Enum.flat_map(&referenced_modules/1)
          |> Enum.uniq()
          |> Enum.reject(&(Map.has_key?(modules, &1) or MapSet.member?(tried, &1)))

        found =
          missing
          |> Enum.flat_map(&dependency_file(deps, &1))
          |> Enum.uniq()
          |> Enum.flat_map(fn file -> Source.parse(file, File.read!(file)).modules end)

        modules =
          Enum.reduce(found, modules, fn module, acc -> Map.put_new(acc, module.name, module) end)

        tried = MapSet.union(tried, MapSet.new(missing))

        if found == [], do: {:halt, {modules, tried}}, else: {:cont, {modules, tried}}
      end)
      |> elem(0)
    end
  end

  defp dependency_dirs(root) do
    [Path.join(root, "deps"), Path.join([root, "..", "..", "deps"])]
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  defp referenced_modules(module) do
    quoted =
      for {_key, clauses} <- module.functions,
          clause <- clauses,
          clause.body != nil,
          {_, found} = Macro.prewalk(clause.body, [], &collect_reference/2),
          name <- found,
          do: ModuleInfo.expand_alias(module, name)

    module.imports ++ Enum.map(module.uses, &elem(&1, 0)) ++ Map.values(module.aliases) ++ quoted
  end

  defp collect_reference({kind, _, [target | _]} = node, acc)
       when kind in [:import, :use, :alias] do
    case Code.alias_name(target) do
      nil -> {node, acc}
      name -> {node, [name | acc]}
    end
  end

  defp collect_reference(node, acc), do: {node, acc}

  # SaladUI.Button lives in deps/salad_ui/lib/salad_ui/button.ex.
  defp dependency_file(deps, module_name) do
    relative = Macro.underscore(module_name) <> ".ex"

    deps
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "*", "lib", relative])))
    |> Enum.take(1)
  end

  @doc "Whether `module` comes from a dependency rather than the project."
  @spec dependency?(ModuleInfo.t()) :: boolean()
  def dependency?(%ModuleInfo{file: file}), do: String.contains?(file, "/deps/")

  ## Theme

  # Each Mix project (an umbrella's apps included) has its own theme, the
  # way each package of a JavaScript monorepo does. A configured theme
  # applies everywhere.
  defp load_theme(project) do
    roots =
      project.sources
      |> Map.keys()
      |> Enum.map(&app_root(project.root, &1))
      |> then(&[project.root | &1])
      |> Enum.uniq()

    {themes, warnings} =
      case project.settings[:theme] do
        nil ->
          {Map.new(roots, &{&1, discovered_theme(&1)}), []}

        configured ->
          {info, warnings} = configured_theme(project.root, configured)
          {Map.new(roots, &{&1, info}), warnings}
      end

    %{project | themes: themes, warnings: project.warnings ++ warnings}
    |> with_theme_info(Map.fetch!(themes, project.root))
  end

  defp configured_theme(root, configured) do
    path = Path.expand(configured, root)

    if File.regular?(path) do
      {theme_info(path, root), []}
    else
      discovered = Theme.discover(root)

      message =
        "The theme is set to #{configured}, which does not exist. " <>
          if(discovered,
            do: "Using #{Path.relative_to(discovered, root)} until the path is fixed.",
            else:
              "No stylesheet importing Tailwind was found, so declared tokens cannot be checked until the path is fixed."
          )

      {theme_info(discovered, root), [message]}
    end
  end

  defp discovered_theme(root), do: theme_info(Theme.discover(root), root)

  defp theme_info(file, root) do
    theme = Theme.load(file)

    # The stylesheet Tailwind builds: a theme partial that does not import
    # Tailwind knows no base utilities.
    entry =
      cond do
        file == nil -> nil
        theme.tailwind -> file
        true -> Theme.discover(root)
      end

    %{file: file, theme: theme, entry: entry}
  end

  defp with_theme_info(project, info),
    do: %{project | theme: info.theme, theme_file: info.file, entry: info.entry}

  @doc """
  The project as the file at `path` sees it: with the theme of its Mix
  project (in an umbrella, its app).
  """
  @spec for_file(t(), String.t()) :: t()
  def for_file(project, path) do
    case Map.get(project.themes, app_root(project.root, path)) do
      nil -> project
      info -> with_theme_info(project, info)
    end
  end

  @doc """
  The directory of the Mix project `path` belongs to: the nearest
  directory with a `mix.exs`, up to `root`.
  """
  @spec app_root(String.t(), String.t()) :: String.t()
  def app_root(root, path) do
    root = Path.expand(root)

    path
    |> Path.expand()
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(root, fn dir, acc ->
      cond do
        not String.starts_with?(dir, root) -> {:halt, acc}
        dir != root and File.regular?(Path.join(dir, "mix.exs")) -> {:halt, dir}
        dir == root -> {:halt, root}
        true -> {:cont, acc}
      end
    end)
  end

  ## Templates and owners

  # .heex files belong to the module that embeds them, or to the LiveView
  # next to them.
  defp attach_heex(project) do
    owners =
      Enum.reduce(project.modules, %{}, fn {_name, module}, acc ->
        dir = Path.dirname(module.file)

        embedded =
          for pattern <- module.embed_templates,
              file <-
                Path.wildcard(Path.join(dir, pattern) <> ".html.heex") ++
                  Path.wildcard(Path.join(dir, pattern) <> ".heex"),
              into: %{},
              do:
                {Path.expand(file),
                 {module.name, file |> Path.basename() |> String.split(".") |> hd()}}

        colocated = String.replace_suffix(module.file, ".ex", ".html.heex")

        acc
        |> Map.merge(embedded)
        |> Map.put_new(Path.expand(colocated), {module.name, "render"})
      end)

    sources =
      Map.new(project.sources, fn {path, source} ->
        case {Path.extname(path), Map.get(owners, Path.expand(path))} do
          {".heex", {module, function}} ->
            templates = Enum.map(source.templates, &%{&1 | module: module, function: function})
            {path, %{source | templates: templates}}

          _ ->
            {path, source}
        end
      end)

    # Embedded templates render as components of their module.
    modules =
      Enum.reduce(sources, project.modules, fn {_path, source}, modules ->
        Enum.reduce(source.templates, modules, fn
          %Template{module: nil}, acc ->
            acc

          %Template{module: module_name, function: function} = template, acc ->
            if Path.extname(template.file) == ".heex" and Map.has_key?(acc, module_name) do
              Map.update!(acc, module_name, fn module ->
                component =
                  Map.get(module.components, function) ||
                    %Component{module: module.name, name: function, file: template.file, line: 1}

                component = %{component | templates: component.templates ++ [template]}
                %{module | components: Map.put(module.components, function, component)}
              end)
            else
              acc
            end
        end)
      end)

    %{project | sources: sources, modules: modules}
  end

  defp mark_render_templates(project) do
    sources =
      Map.new(project.sources, fn {path, source} ->
        templates =
          Enum.map(source.templates, fn template ->
            module = template.module && Map.get(project.modules, template.module)

            if module && template.function == "render" && ModuleInfo.live?(module),
              do: %{template | kind: :render},
              else: template
          end)

        {path, %{source | templates: templates}}
      end)

    %{project | sources: sources}
  end

  # Every template is tokenized once; sources and component entries share
  # the parsed elements.
  defp parse_templates(project) do
    parsed =
      project.sources
      |> Map.values()
      |> Enum.flat_map(& &1.templates)
      |> Task.async_stream(&{template_key(&1), Template.parse(&1)},
        timeout: :infinity,
        ordered: false
      )
      |> Map.new(fn {:ok, pair} -> pair end)

    replace = fn template -> Map.get(parsed, template_key(template), template) end

    sources =
      Map.new(project.sources, fn {path, source} ->
        {path, %{source | templates: Enum.map(source.templates, replace)}}
      end)

    modules =
      Map.new(project.modules, fn {name, module} ->
        components =
          Map.new(module.components, fn {cname, component} ->
            {cname, %{component | templates: Enum.map(component.templates, replace)}}
          end)

        {name, %{module | components: components, templates: Enum.map(module.templates, replace)}}
      end)

    %{project | sources: sources, modules: modules}
  end

  defp template_key(template), do: {template.file, template.line, template.column}

  ## Imports

  # The modules a module imports and the aliases it sees, including what
  # `use MyAppWeb, :html` brings in through the web module's quote blocks.
  defp effective(project, module) do
    {imports, aliases} =
      Enum.reduce(module.uses, {[], %{}}, fn {name, arg}, acc ->
        case Map.get(project.modules, name) do
          nil ->
            acc

          used ->
            merge_quoted(acc, quoted_imports(project, used, arg || "__using__", MapSet.new()))
        end
      end)

    %{imports: module.imports ++ imports, aliases: Map.merge(aliases, module.aliases)}
  end

  defp merge_quoted({imports, aliases}, {more_imports, more_aliases}),
    do: {imports ++ more_imports, Map.merge(aliases, more_aliases)}

  defp quoted_imports(project, module, function, seen) do
    key = {module.name, function}

    if MapSet.member?(seen, key) do
      {[], %{}}
    else
      seen = MapSet.put(seen, key)

      clauses =
        Map.get(module.functions, {function, 0}, []) ++
          Map.get(module.functions, {function, 1}, [])

      Enum.reduce(clauses, {[], %{}}, fn clause, acc ->
        {_, found} =
          Macro.prewalk(clause.body, acc, fn
            {:import, _, [target | _]} = node, {imports, aliases} ->
              case Code.alias_name(target) do
                nil -> {node, {imports, aliases}}
                name -> {node, {imports ++ [ModuleInfo.expand_alias(module, name)], aliases}}
              end

            {:alias, _, [target | _]} = node, {imports, aliases} ->
              case Code.alias_name(target) do
                nil ->
                  {node, {imports, aliases}}

                name ->
                  full = ModuleInfo.expand_alias(module, name)

                  {node,
                   {imports, Map.put(aliases, full |> String.split(".") |> List.last(), full)}}
              end

            {:unquote, _, [{fun, _, args}]} = node, acc when is_atom(fun) and is_list(args) ->
              {node,
               merge_quoted(acc, quoted_imports(project, module, Atom.to_string(fun), seen))}

            {:use, _, [target | rest]} = node, acc ->
              with name when is_binary(name) <- Code.alias_name(target),
                   %ModuleInfo{} = used <-
                     Map.get(project.modules, ModuleInfo.expand_alias(module, name)) do
                arg =
                  with [atom | _] when is_atom(atom) <- rest,
                       do: Atom.to_string(atom),
                       else: (_ -> "__using__")

                {node, merge_quoted(acc, quoted_imports(project, used, arg, seen))}
              else
                _ -> {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        found
      end)
    end
  end

  @doc "The module named `name`, or nil."
  @spec module(t(), String.t() | nil) :: ModuleInfo.t() | nil
  def module(_project, nil), do: nil
  def module(project, name), do: Map.get(project.modules, name)

  @doc "Expands an alias as `module` sees it, including aliases from `use`."
  @spec expand_alias(t(), String.t(), String.t()) :: String.t()
  def expand_alias(project, module_name, name) do
    aliases =
      case Map.get(project.imports, module_name) do
        %{aliases: aliases} -> aliases
        nil -> %{}
      end

    [first | rest] = String.split(name, ".")

    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join([full | rest], ".")
      :error -> name
    end
  end

  ## Component resolution

  @doc """
  The component a tag names from inside `module_name`: `.button` for a local
  or imported function component, `Mod.button` for a remote one. Nil for
  plain elements and components outside the project.
  """
  @spec resolve(
          t(),
          String.t() | nil,
          :tag | :local_component | :remote_component | :slot,
          String.t()
        ) ::
          Component.t() | nil
  def resolve(project, module_name, :local_component, name) do
    module = module(project, module_name)
    imports = get_in(project.imports, [module_name, :imports]) || []

    cond do
      module && Map.has_key?(module.components, name) ->
        module.components[name]

      found = Enum.find_value(imports, &component_in(project, &1, name)) ->
        found

      name in @phoenix_components ->
        nil

      true ->
        # Name matching is a fallback for when imports cannot be read.
        fallback(project, name)
    end
  end

  def resolve(project, module_name, :remote_component, name) do
    case String.split(name, ".") |> Enum.split(-1) do
      {[_ | _] = parts, [function]} ->
        target = expand_alias(project, module_name || "", Enum.join(parts, "."))
        component_in(project, target, function)

      _ ->
        nil
    end
  end

  def resolve(_project, _module_name, _type, _name), do: nil

  defp component_in(project, module_name, name) do
    case Map.get(project.modules, module_name) do
      nil -> nil
      module -> Map.get(module.components, name)
    end
  end

  defp fallback(project, name) do
    candidates =
      project.modules
      |> Map.values()
      |> Enum.sort_by(&{not project.ds[&1.name], &1.name})
      |> Enum.flat_map(fn module -> List.wrap(Map.get(module.components, name)) end)

    List.first(candidates)
  end

  @doc "Whether `component` belongs to the design system."
  @spec design_system?(t(), Component.t() | nil) :: boolean()
  def design_system?(_project, nil), do: false
  def design_system?(project, %Component{module: module}), do: Map.get(project.ds, module, false)

  defp ds_module?(project, %ModuleInfo{name: name, file: file}) do
    settings = project.settings
    ui = List.wrap(settings[:ui])
    imports = List.wrap(settings[:component_imports]) |> Enum.map(&regex/1)
    ignores = List.wrap(settings[:ignore_imports]) |> Enum.map(&regex/1)

    cond do
      Enum.any?(ignores, &Regex.match?(&1, name)) ->
        false

      Enum.any?(ui, &(name == &1 or String.starts_with?(name, &1 <> "."))) ->
        true

      Enum.any?(imports, &Regex.match?(&1, name)) ->
        true

      String.contains?(file, "/deps/") ->
        # A dependency's components are the design system only when the
        # settings name them.
        false

      true ->
        # Phoenix's convention, and the design system's home whatever else
        # the settings add: CoreComponents and friends live in components/.
        file |> Path.relative_to(project.root) |> Path.split() |> Enum.member?("components")
    end
  end

  defp regex(%Regex{} = regex), do: regex
  defp regex(text) when is_binary(text), do: Regex.compile!(text)

  ## Wrappers

  @doc """
  The design-system component `component` forwards its `class` to, when it
  is a wrapper: a component outside the design system whose template passes
  its received `class` (or its global attributes) on to one.
  """
  @spec wrapped(t(), Component.t() | nil) :: Component.t() | nil
  def wrapped(_project, nil), do: nil

  def wrapped(project, %Component{module: module, name: name}),
    do: Map.get(project.wrappers, {module, name})

  defp wrappers(project) do
    components =
      for {_name, module} <- project.modules,
          not Map.get(project.ds, module.name, false),
          {_cname, component} <- module.components,
          do: component

    # Chains resolve by iterating to a fixed point, a few hops deep.
    Enum.reduce(1..4, %{}, fn _round, known ->
      Enum.reduce(components, known, fn component, acc ->
        case forward_target(project, component, acc) do
          nil -> acc
          target -> Map.put_new(acc, {component.module, component.name}, target)
        end
      end)
    end)
  end

  defp forward_target(project, component, known) do
    Enum.find_value(component.templates, fn template ->
      case Template.elements(template) do
        {:ok, elements} ->
          Enum.find_value(elements, fn element ->
            target = resolve(project, template.module, element.type, element.name)

            resolved =
              cond do
                target == nil -> nil
                design_system?(project, target) -> target
                true -> Map.get(known, {target.module, target.name})
              end

            if resolved && forwards_class?(element, component), do: resolved
          end)

        {:error, _} ->
          nil
      end
    end)
  end

  # `class={@class}`, `class={[..., @class]}` or `{@rest}` with global attrs.
  defp forwards_class?(element, component) do
    Enum.any?(element.attributes, fn
      %{name: :root, value: {:expr, code, _}} ->
        Component.global?(component) and Regex.match?(~r/^\s*@(\w+)\s*$/, code) and
          (fn [_, name] -> match?(%{global: true}, Component.attr(component, name)) end).(
            Regex.run(~r/^\s*@(\w+)\s*$/, code)
          )

      %{name: name, value: {:expr, code, _}} when is_binary(name) ->
        HeexLint.Sites.class_attribute?(name) and
          Regex.match?(~r/@(\w*class\w*)\b|assigns\.(\w*class\w*)\b/, code)

      _ ->
        false
    end)
  end
end
