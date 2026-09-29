defmodule HeexLint.TemplateTest do
  use ExUnit.Case, async: true

  alias HeexLint.{Element, Template}

  defp class_positions(file, contents) do
    {:ok, templates} = Template.from_file(file, contents)

    for template <- templates,
        {:ok, elements} = Element.from_template(template),
        element <- elements,
        %{name: "class", value: {_, value, position}} <- element.attributes,
        do: {value, position}
  end

  test "finds heredoc sigils with real positions" do
    contents = """
    defmodule Sample do
      def render(assigns) do
        ~H\"\"\"
        <div class="p-4">
          <.button class={["px-2", @flag && "py-5"]}>Go</.button>
          <span class = 'mt-1'>x</span>
        </div>
        \"\"\"
      end
    end
    """

    assert class_positions("sample.ex", contents) == [
             {"p-4", {4, 17}},
             {~s(["px-2", @flag && "py-5"]), {5, 23}},
             {"mt-1", {6, 22}}
           ]
  end

  test "finds single-line sigils" do
    contents = ~S"""
    defmodule Sample do
      def tag(assigns), do: ~H"<p class='text-sm'>x</p>"
    end
    """

    assert class_positions("sample.ex", contents) == [{"text-sm", {2, 38}}]
  end

  test "reads .heex files as one template" do
    assert class_positions("page.html.heex", ~s(<div>\n  <p class="m-2">x</p>\n</div>\n)) ==
             [{"m-2", {2, 13}}]
  end

  test "ignores other files" do
    assert Template.from_file("app.js", "~H\"<p/>\"") == {:ok, []}
  end

  test "reports Elixir syntax errors" do
    assert {:error, message} = Template.from_file("broken.ex", "defmodule Broken do")
    assert message =~ "broken.ex:"
  end

  test "reports HEEx syntax errors" do
    {:ok, [template]} = Template.from_file("broken.heex", ~s(<div class="a></div>))
    assert {:error, _message} = Element.from_template(template)
  end
end
