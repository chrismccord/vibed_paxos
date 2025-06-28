defmodule PaxosConsensus.Paxos.Learner do
  @moduledoc """
  Implements the Learner role in the Paxos consensus algorithm.

  The Learner:
  1. Receives ACCEPTED messages from acceptors
  2. Determines when consensus has been reached
  3. Maintains the log of agreed-upon values
  """

  use GenServer

  alias PaxosConsensus.Paxos.Accepted

  defstruct [
    :node_id,
    :acceptors,
    :learned_values,
    :pending_accepts
  ]

  @type state :: %__MODULE__{
          node_id: atom(),
          acceptors: [atom()],
          learned_values: %{non_neg_integer() => any()},
          pending_accepts: %{non_neg_integer() => [Accepted.t()]}
        }

  ## Client API

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    acceptors = Keyword.fetch!(opts, :acceptors)
    GenServer.start_link(__MODULE__, {node_id, acceptors}, name: node_id)
  end

  def receive_accepted(learner, accepted) do
    GenServer.cast(learner, {:accepted, accepted})
  end

  def get_learned_values(learner) do
    GenServer.call(learner, :get_learned_values)
  end

  def get_state(learner) do
    GenServer.call(learner, :get_state)
  end

  ## Server Callbacks

  @impl true
  def init({node_id, acceptors}) do
    state = %__MODULE__{
      node_id: node_id,
      acceptors: acceptors,
      learned_values: %{},
      pending_accepts: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_learned_values, _from, state) do
    {:reply, state.learned_values, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:accepted, accepted}, state) do
    proposal_number = accepted.proposal_number

    # Add this accepted message to pending accepts for this proposal
    current_accepts = Map.get(state.pending_accepts, proposal_number, [])
    updated_accepts = [accepted | current_accepts]

    majority = div(length(state.acceptors), 2) + 1

    if length(updated_accepts) >= majority do
      # We have consensus! Learn the value
      new_learned_values = Map.put(state.learned_values, proposal_number, accepted.value)

      # Broadcast that we've learned a new value
      Phoenix.PubSub.broadcast(
        PaxosConsensus.PubSub,
        "paxos_updates",
        {:value_learned, state.node_id, proposal_number, accepted.value}
      )

      # Remove from pending accepts since we've learned it
      new_pending_accepts = Map.delete(state.pending_accepts, proposal_number)

      new_state = %{
        state
        | learned_values: new_learned_values,
          pending_accepts: new_pending_accepts
      }

      {:noreply, new_state}
    else
      # Still waiting for more accepts
      new_pending_accepts = Map.put(state.pending_accepts, proposal_number, updated_accepts)

      new_state = %{state | pending_accepts: new_pending_accepts}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end
end
