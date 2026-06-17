defmodule TragarAiWeb.PageController do
  use TragarAiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
