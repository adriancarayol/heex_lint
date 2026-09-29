defmodule HeexLint.Policy.ConfigError do
  @moduledoc """
  An invalid rule policy: a bad contract pattern or an entry that would
  match nothing. The rule reports it at the top of each file and checks
  nothing else there, since enforcing a policy the team did not write would
  be worse than enforcing none.
  """

  defexception [:message]
end
