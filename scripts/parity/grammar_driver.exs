# Classifies the names grammar_driver.ts wrote, the way it does.
# Run from the repository root: MIX_ENV=test mix run scripts/parity/grammar_driver.exs

alias HeexLint.Grammar.{Categories, Classifier}

here = Path.expand(".", __DIR__)

out =
  here
  |> Path.join("ref_out.tsv")
  |> File.stream!()
  |> Task.async_stream(fn line ->
    [name | _] = String.split(line, "\t")
    group = Classifier.group_of(name)
    category = group && Categories.category_of(group)
    "#{name}\t#{group || "-"}\t#{category || "-"}\n"
  end)
  |> Enum.map(fn {:ok, line} -> line end)

File.write!(Path.join(here, "ours_out.tsv"), out)
IO.puts("#{length(out)} names")
