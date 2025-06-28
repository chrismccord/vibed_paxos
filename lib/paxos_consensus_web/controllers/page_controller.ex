defmodule PaxosConsensusWeb.PageController do
  use PaxosConsensusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
