defmodule HeexLint.Diagnostic do
  @moduledoc """
  A rule violation at a position in a file. `suggestions` are fixes a
  reader (or an agent) can apply: each names its replacement and, when the
  class sits in a literal that can be rewritten safely, the edit.
  """

  defstruct [:rule, :severity, :file, :line, :column, :message, suggestions: []]

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          rule: atom(),
          severity: severity(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          message: String.t(),
          suggestions: [HeexLint.Rule.suggestion()]
        }
end
