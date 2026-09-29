defmodule HeexLint.Rules.InlineStyleValuesTest do
  # Expected results come from @shadcn/lint's own splitDeclarations and
  # hasRawColor, run on the same CSS text.
  use ExUnit.Case, async: true

  alias HeexLint.Collector
  alias HeexLint.Rules.NoInlineStyles

  @cases [
    {~S|color: red; margin-top: 4px|, "color", true},
    {~S|color: red; margin-top: 4px|, "margin-top", false},
    {~S|--x: #fff|, "--x", true},
    {~S|--x: var(--y)|, "--x", false},
    {~S|--x: url(data:image/png;base64,aaa;bbb) no-repeat|, "--x", false},
    {~S|--shadow: 0 0 4px rgb(0 0 0 / .5)|, "--shadow", true},
    {~S|--g: linear-gradient(red, blue)|, "--g", true},
    {~S|--c: 'red'|, "--c", false},
    {~S|--c: /* red */ var(--x)|, "--c", false},
    {~S|--c: color-mix(in srgb, var(--a) 50%, white)|, "--c", true},
    {~S|--size: 12px|, "--size", false},
    {~S|--x: transparent|, "--x", false},
    {~S|--x: currentColor|, "--x", false},
    {~S|--x: light-dark(#fff, #000)|, "--x", true},
    {~S|background: url(x.png) red|, "background", true},
    {~S|--a: var(--b, #333)|, "--a", true},
    {~S|--a: var(--b, blue)|, "--a", false},
    {~S|--label: "a; b"; color: blue|, "--label", false},
    {~S|--label: "a; b"; color: blue|, "color", true},
    {~S|--w: calc(100% - 2px); --h: 4px|, "--w", false},
    {~S|--w: calc(100% - 2px); --h: 4px|, "--h", false},
    {~S|--x: hsl(var(--h) 50% 50%)|, "--x", true},
    {~S|--x: rebeccapurple|, "--x", true},
    {~S|--x: #zzz|, "--x", false},
    {~S|--x: 1px solid black|, "--x", true},
    {~S|--x: url("red.png")|, "--x", false},
    {~S|--x: foo\;bar|, "--x", false}
  ]

  test "declarations and raw colors match the reference" do
    for {css, property, raw} <- @cases do
      found =
        for {prop, value, _filled, _position} <-
              NoInlineStyles.__declarations__(%{
                items: Collector.chars(css, {1, 1}, 0),
                holes: %{}
              }),
            prop == property,
            do: NoInlineStyles.raw_color?(value)

      assert raw in found, "#{css} / #{property}"
    end
  end
end
