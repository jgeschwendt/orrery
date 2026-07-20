defmodule OrreryWeb.Layouts do
  @moduledoc """
  Layouts for the dashboard. Only the root layout is used — every LiveView
  renders its own full-screen chrome (see `OrreryWeb.UI`).
  """
  use OrreryWeb, :html

  embed_templates "layouts/*"
end
