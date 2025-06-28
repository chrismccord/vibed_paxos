defmodule PaxosConsensus.Repo do
  use Ecto.Repo,
    otp_app: :paxos_consensus,
    adapter: Ecto.Adapters.SQLite3
end
