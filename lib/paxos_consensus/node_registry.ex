defmodule PaxosConsensus.NodeRegistry do
  @moduledoc """
  A persistent registry for managing Paxos nodes across LiveView sessions.
  Stores node PIDs globally so they survive LiveView restarts.
  """

  use GenServer

  @registry_name __MODULE__

  defstruct [
    :proposers,
    :acceptors,
    :learners,
    :node_counter
  ]

  @type state :: %__MODULE__{
          proposers: %{atom() => pid()},
          acceptors: %{atom() => pid()},
          learners: %{atom() => pid()},
          node_counter: non_neg_integer()
        }

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(
      __MODULE__,
      %__MODULE__{
        proposers: %{},
        acceptors: %{},
        learners: %{},
        node_counter: 0
      },
      name: @registry_name
    )
  end

  def register_nodes(proposers, acceptors, learners) do
    GenServer.call(@registry_name, {:register_nodes, proposers, acceptors, learners})
  end

  def get_all_nodes() do
    GenServer.call(@registry_name, :get_all_nodes)
  end

  def clear_all_nodes() do
    GenServer.call(@registry_name, :clear_all_nodes)
  end

  def get_random_proposer() do
    GenServer.call(@registry_name, :get_random_proposer)
  end

  def get_stats() do
    GenServer.call(@registry_name, :get_stats)
  end

  ## Server Callbacks

  @impl true
  def init(state) do
    # Monitor all existing processes so we can clean up when they die
    {:ok, state}
  end

  @impl true
  def handle_call({:register_nodes, proposers, acceptors, learners}, _from, state) do
    # Stop any existing nodes first
    stop_all_monitored_nodes(state)

    # Monitor all new nodes
    all_pids = Map.values(proposers) ++ Map.values(acceptors) ++ Map.values(learners)
    Enum.each(all_pids, &Process.monitor/1)

    new_state = %{
      state
      | proposers: proposers,
        acceptors: acceptors,
        learners: learners,
        node_counter: map_size(acceptors)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_all_nodes, _from, state) do
    response = %{
      proposers: state.proposers,
      acceptors: state.acceptors,
      learners: state.learners,
      node_counter: state.node_counter
    }

    {:reply, response, state}
  end

  @impl true
  def handle_call(:clear_all_nodes, _from, state) do
    stop_all_monitored_nodes(state)

    new_state = %{
      state
      | proposers: %{},
        acceptors: %{},
        learners: %{},
        node_counter: 0
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_random_proposer, _from, state) do
    result =
      case Map.to_list(state.proposers) do
        [] -> nil
        proposers -> Enum.random(proposers)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      total_nodes:
        map_size(state.proposers) + map_size(state.acceptors) + map_size(state.learners),
      proposers_count: map_size(state.proposers),
      acceptors_count: map_size(state.acceptors),
      learners_count: map_size(state.learners)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove dead processes from our registry
    new_proposers = Enum.reject(state.proposers, fn {_id, p} -> p == pid end) |> Enum.into(%{})
    new_acceptors = Enum.reject(state.acceptors, fn {_id, p} -> p == pid end) |> Enum.into(%{})
    new_learners = Enum.reject(state.learners, fn {_id, p} -> p == pid end) |> Enum.into(%{})

    new_state = %{
      state
      | proposers: new_proposers,
        acceptors: new_acceptors,
        learners: new_learners
    }

    {:noreply, new_state}
  end

  # Private helpers

  defp stop_all_monitored_nodes(state) do
    all_pids =
      Map.values(state.proposers) ++ Map.values(state.acceptors) ++ Map.values(state.learners)

    Enum.each(all_pids, fn pid ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)
  end
end
