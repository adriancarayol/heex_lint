defmodule HeexLint.Rules.DataAttributesTest do
  # A data-* or aria-* attribute whose name ends in "class" is not a class
  # list: `data-class` is an E2E selector hook, not classes.
  use ExUnit.Case, async: true

  import HeexLint.TestProject

  alias HeexLint.Sites

  @moduletag :tmp_dir

  @rules [
    no_restyle: {:error, allow: ["layout"]},
    no_unknown_classes: :error,
    no_raw_colors: :error,
    no_arbitrary_values: :error
  ]

  defp page(dir, template, rules \\ @rules, extra \\ %{}) do
    lint(dir, Map.merge(%{"lib/app_web/live/page_live.ex" => live(template)}, extra),
      rules: rules
    )
  end

  test "class_attribute? excludes data-* and aria-* names only" do
    for name <- ~w(data-class data-testclass DATA-CLASSNAME aria-class data-classes) do
      refute Sites.class_attribute?(name), name
    end

    for name <- ~w(class className class:list input_class contentClass header-class
                   data_class dataClass metadata-class) do
      assert Sites.class_attribute?(name), name
    end
  end

  test "their string values reach no class rule", %{tmp_dir: dir} do
    assert page(dir, ~s(<div data-class="bg-pink-500 p-[13px] nope-nope" />)) == []
    assert page(dir, ~s(<.button data-class="bg-pink-500 p-[13px]">+</.button>)) == []
    assert page(dir, ~s(<span aria-class="bg-pink-500" />)) == []
  end

  test "their expression values reach no class rule", %{tmp_dir: dir} do
    assert page(dir, ~s(<span data-class={"bg-pink-500"} />)) == []
  end

  test "another class attribute beside them is still read", %{tmp_dir: dir} do
    [finding] =
      page(dir, ~s(<span data-class="x" content_class="bg-pink-500" />), no_raw_colors: :error)

    assert finding.message =~ ~s("bg-pink-500")
  end

  test "a wrapper does not forward its class through data-class", %{tmp_dir: dir} do
    tagged =
      component_module("Tagged", "tagged", "attr :class, :any, default: nil", """
      <.card data-class={@class} />
      """)

    forwarding =
      component_module("Forwarding", "forwarding", "attr :class, :any, default: nil", """
      <.card class={@class} />
      """)

    rules = [no_restyle: {:error, allow: ["layout"]}]

    extra = %{
      "lib/app_web/tagged.ex" => tagged,
      "lib/app_web/forwarding.ex" => forwarding
    }

    assert page(dir, ~s(<AppWeb.Tagged.tagged class="bg-pink-500" />), rules, extra) == []

    # The same wrapper with class={@class} does forward.
    assert [_] = page(dir, ~s(<AppWeb.Forwarding.forwarding class="bg-pink-500" />), rules, extra)
  end

  test "a data-class built at runtime is not a dynamic class", %{tmp_dir: dir} do
    rules = [require_static_classes: :error]

    assert page(dir, ~S|<.button data-class={"item-#{@id}"}>+</.button>|, rules) == []
    assert [_] = page(dir, ~S|<.button class={"item-#{@id}"}>+</.button>|, rules)
  end
end
