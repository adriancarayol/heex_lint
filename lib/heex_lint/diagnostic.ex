defmodule HeexLint.Diagnostic do
  @moduledoc """
  A rule violation at a position in a file.
  """

  defstruct [:rule, :severity, :file, :line, :column, :message]

  @type severity :: :error | :warning

  @type t :: %__MODULE__{
          rule: atom(),
          severity: severity(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          message: String.t()
        }
end
