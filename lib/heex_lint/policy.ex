defmodule HeexLint.Policy do
  @moduledoc """
  The policy engine every class rule shares: `allow`, `deny` and
  `contracts`. Ported from @shadcn/lint's `src/rules/contracts.ts` (MIT).

  Entries are categories (`layout`, `spacing`, `color`...), class groups
  (`p`, `bg-color`, `rounded`) or class patterns (`p-4`, `p-*`,
  `md:p-*`). Entries without `:` match the base class, ignoring variants,
  important markers, negative prefixes and opacity modifiers; entries with
  `:` match the full class.

  | Configuration                 | Policy                                          |
  | ----------------------------- | ----------------------------------------------- |
  | Neither `allow` nor `deny`    | No policy exceptions.                           |
  | `allow: [...]`                | Only matching classes are exempt.               |
  | `allow: []`                   | No policy exceptions.                           |
  | `deny: [...]` without `allow` | Everything except these matches is exempt.      |
  | `deny: []` without `allow`    | Everything is exempt.                           |

  A contract's `pattern` is a regex on the component name. It replaces the
  keys it writes and inherits the rest; when several match, the last wins.
  """

  alias HeexLint.Grammar.{Categories, Classes, Classifier, ProjectClassifier, Similar}
  alias HeexLint.Policy.ConfigError
  alias HeexLint.Theme

  defstruct [:id, :theme, :baseline, contracts: []]

  @type verdict ::
          :ok
          | {:denied, [String.t()], String.t(), String.t() | nil}
          | {:not_allowed, [String.t()], String.t(), String.t() | nil}

  @doc """
  Compiles a rule's policy options. Raises `HeexLint.Policy.ConfigError`
  for an invalid pattern or a misspelled entry; returns warnings for
  entries that may name classes from elsewhere.

  Options: `:allow`, `:deny`, `:contracts`, `:message`, and
  `unchecked_entries: true` for rules whose entries may name external
  classes.
  """
  @spec compile(keyword(), Theme.t() | nil, String.t()) :: {t :: %__MODULE__{}, [String.t()]}
  def compile(options, theme, rule) do
    unchecked = Keyword.get(options, :unchecked_entries, false)
    contracts = options |> Keyword.get(:contracts, []) |> Enum.map(&normalize_contract/1)
    allow = fetch_list(options, :allow)
    deny = fetch_list(options, :deny)

    warnings =
      if unchecked do
        []
      else
        Enum.flat_map(
          [allow, deny | Enum.flat_map(contracts, &[&1.allow, &1.deny])],
          fn entries ->
            check_allow_entries(entries, theme, rule)
            check_entries(entries, theme)
          end
        )
      end

    top_allow = allow_list(%{allow: allow, deny: deny}, nil)
    top_deny = deny || []

    compiled =
      Enum.map(contracts, fn contract ->
        %{
          pattern: compile_pattern(contract.pattern),
          source: contract.pattern,
          allow: compile_entries(allow_list(contract, top_allow), theme),
          deny: compile_entries(contract.deny || top_deny, theme),
          message: message_table(contract.message)
        }
      end)

    baseline = %{
      allow: compile_entries(top_allow, theme),
      deny: compile_entries(top_deny, theme),
      message: message_table(Keyword.get(options, :message))
    }

    policy = %__MODULE__{id: make_ref(), theme: theme, baseline: baseline, contracts: compiled}
    {policy, Enum.uniq(warnings)}
  end

  defp fetch_list(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp normalize_contract(contract) do
    contract = Map.new(contract)
    pattern = Map.get(contract, :pattern)

    if not is_binary(pattern) and not is_struct(pattern, Regex),
      do: raise(ConfigError, "Every contract needs a pattern, got: #{inspect(contract)}")

    %{
      pattern: pattern,
      allow: list_or_nil(Map.get(contract, :allow, :unset)),
      deny: list_or_nil(Map.get(contract, :deny, :unset)),
      message: Map.get(contract, :message)
    }
  end

  defp list_or_nil(:unset), do: nil
  defp list_or_nil(list) when is_list(list), do: list
  defp list_or_nil(_), do: nil

  @doc """
  What a policy allows when it writes no `allow`: its own allow list, the
  inherited one, everything when it only denies, or nothing.
  """
  def allow_list(%{allow: allow}, _inherited) when is_list(allow), do: allow
  def allow_list(_policy, inherited) when is_list(inherited), do: inherited
  def allow_list(%{deny: deny}, _inherited) when is_list(deny), do: ["*"]
  def allow_list(_policy, _inherited), do: []

  defp compile_pattern(%Regex{} = regex), do: regex

  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        regex

      {:error, _} ->
        raise ConfigError, ~s|Contract pattern "#{pattern}" is not a valid regular expression.|
    end
  end

  defp message_table(message) when is_binary(message), do: %{"default" => message}

  defp message_table(message) when is_map(message) or is_list(message) do
    table =
      for {key, value} <- message, is_binary(value), into: %{}, do: {to_string(key), value}

    if map_size(table) > 0, do: table
  end

  defp message_table(_), do: nil

  ## Entries

  defp compile_entries(entries, theme) do
    Enum.reduce(
      entries || [],
      %{
        source: entries || [],
        categories: MapSet.new(),
        layout: false,
        groups: MapSet.new(),
        base: [],
        full: []
      },
      fn
        "layout", set ->
          %{set | layout: true}

        raw, set ->
          cond do
            raw in Categories.categories() ->
              %{set | categories: MapSet.put(set.categories, raw)}

            String.contains?(raw, ":") ->
              %{set | full: set.full ++ [glob(raw)]}

            true ->
              entry = strip_modifier(Classes.normalize(raw), theme)
              group? = entry in Classifier.groups()
              set = if group?, do: %{set | groups: MapSet.put(set.groups, entry)}, else: set

              # "flex" is a group id and a class; such an entry opens both.
              if not group? or ProjectClassifier.group_of(theme, entry),
                do: %{set | base: set.base ++ [glob(entry)]},
                else: set
          end
      end
    )
  end

  defp glob(pattern) do
    escaped =
      pattern
      |> String.replace(~r/[.+?^${}()|\[\]\\]/, "\\\\\\0")
      |> String.replace("*", "[^\\s]+")

    Regex.compile!("^" <> escaped <> "$")
  end

  # An opacity or line height is not part of the utility, but a fraction
  # is the value itself: w-1/2 keeps it, bg-red-500/50 does not.
  defp strip_modifier(base, theme) do
    if Regex.match?(~r/-\d+\/\d+$/, base) and
         ProjectClassifier.category_of(theme, base) != "color",
       do: base,
       else: String.replace(base, ~r/\/[\w.%]+$/, "")
  end

  @doc false
  def matches?(%{source: []}, _token, _theme), do: false

  def matches?(set, token, theme) do
    group = ProjectClassifier.group_of(theme, token)
    category = Categories.category_of(group)
    base = strip_modifier(Classes.normalize(token), theme)

    (group != nil and MapSet.member?(set.groups, group)) or
      (category != nil and MapSet.member?(set.categories, category)) or
      (category == nil and set.layout and (group != nil or Classes.marker?(token))) or
      Enum.any?(set.base, &Regex.match?(&1, base)) or
      Enum.any?(set.full, &Regex.match?(&1, token))
  end

  ## Deciding

  @doc """
  Whether `token` on `component` (nil for no recognized component, which
  takes the top-level policy) passes. The verdict carries the entries that
  decided, the class category and the policy's own message, if any.
  """
  @spec decide(%__MODULE__{}, String.t() | nil, String.t()) :: verdict()
  def decide(%__MODULE__{} = policy, component, token) do
    key = {__MODULE__, policy.id, component, token}

    case Process.get(key) do
      nil ->
        verdict = decide_uncached(policy, component, token)
        Process.put(key, verdict)
        verdict

      verdict ->
        verdict
    end
  end

  defp decide_uncached(policy, component, token) do
    rules = if component == nil, do: policy.baseline, else: policy_for(policy, component)
    group = ProjectClassifier.group_of(policy.theme, token)

    # A marker (group/name, peer) is layout; a name the grammar cannot
    # classify is neither layout nor appearance.
    category =
      if group != nil or Classes.marker?(token),
        do: Categories.category_of(group) || "layout",
        else: "unclassified"

    words = fn
      nil -> nil
      table -> table[category] || table["default"]
    end

    message = words.(rules.message) || words.(policy.baseline.message)

    cond do
      matches?(rules.deny, token, policy.theme) -> {:denied, rules.deny.source, category, message}
      matches?(rules.allow, token, policy.theme) -> :ok
      true -> {:not_allowed, rules.allow.source, category, message}
    end
  end

  defp policy_for(policy, component) do
    policy.contracts
    |> Enum.reverse()
    |> Enum.find(policy.baseline, &Regex.match?(&1.pattern, component))
  end

  @doc """
  Components a contract lets `token` onto, for a spacing message. More than
  four names is a pattern, not a list, so none are returned.
  """
  @spec primitives_for(%__MODULE__{}, String.t(), [String.t()], [String.t()]) :: [String.t()]
  def primitives_for(policy, token, except, indexed) do
    granting = Enum.filter(policy.contracts, &matches?(&1.allow, token, policy.theme))

    if granting == [] do
      []
    else
      names =
        (Enum.flat_map(granting, &literal_names(&1.source)) ++ indexed)
        |> Enum.uniq()
        |> Enum.reject(&(&1 in except))
        |> Enum.filter(fn name -> Enum.any?(granting, &Regex.match?(&1.pattern, name)) end)
        |> Enum.filter(&(decide(policy, &1, token) == :ok))

      if length(names) > 4, do: [], else: names
    end
  end

  # The names ^row$ or ^(row|stack|box)$ spell out; else none.
  defp literal_names(%Regex{source: source}), do: literal_names(source)

  defp literal_names(source) do
    inner =
      source
      |> String.replace(~r/^\^/, "")
      |> String.replace(~r/\$$/, "")
      |> String.replace(~r/^\((?:\?:)?/, "")
      |> String.replace(~r/\)$/, "")

    parts = String.split(inner, "|")
    if Enum.all?(parts, &Regex.match?(~r/^[A-Za-z_$][\w$]*$/, &1)), do: parts, else: []
  end

  ## Validation

  # An entry that matches nothing enforces nothing, silently. A near-miss
  # of a real name (spacig) is an error; any other unknown literal may be
  # a plugin's class (prose, btn), so it warns and matches by name.
  defp check_entries(nil, _theme), do: []

  defp check_entries(entries, theme) do
    Enum.flat_map(entries, fn entry ->
      cond do
        entry == "layout" or String.contains?(entry, "*") or String.contains?(entry, ":") ->
          []

        entry in Categories.categories() ->
          []

        entry in Classifier.groups() ->
          []

        ProjectClassifier.group_of(theme, entry) ->
          []

        theme && (MapSet.member?(theme.utilities, entry) or MapSet.member?(theme.classes, entry)) ->
          []

        true ->
          unknown_entry(entry)
      end
    end)
  end

  defp unknown_entry(entry) do
    names = Enum.join(Categories.categories() ++ ["layout"], ", ")

    hint =
      if Regex.match?(~r/^[A-Za-z][A-Za-z0-9]*$/, entry),
        do:
          Similar.did_you_mean(entry, Categories.categories() ++ ["layout" | Classifier.groups()])

    if hint do
      raise ConfigError,
            ~s|Contract entry "#{entry}" is not a category (#{names}), a class group, or a class, so it would match nothing. Did you mean "#{hint}"?|
    end

    [
      ~s|Contract entry "#{entry}" is not a category (#{names}), a class group, or a class the grammar or your theme knows; it matches only a class named exactly that.|
    ]
  end

  # The mistake a bare `allow` invites: a palette color written without
  # its utility, "blue-500" for "*-blue-500".
  defp check_allow_entries(nil, _theme, _rule), do: :ok

  defp check_allow_entries(entries, theme, rule) do
    Enum.each(entries, fn entry ->
      if Regex.match?(~r/^[a-z]+-\d{2,3}$/, entry) and entry not in Classifier.groups() and
           ProjectClassifier.group_of(theme, entry) == nil do
        raise ConfigError,
              ~s|#{rule}: allow entry "#{entry}" names a color, not a class, so it would match nothing. Did you mean "*-#{entry}" (the color on any utility), or "bg-#{entry}"?|
      end
    end)
  end
end
