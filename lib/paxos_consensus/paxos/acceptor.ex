defmodule PaxosConsensus.Paxos.Acceptor do
  @moduledoc """
  Implements the Acceptor role in the Paxos consensus algorithm.

  The Acceptor:
  1. Responds to PREPARE messages with PROMISE (if proposal number is higher)
  2. Responds to ACCEPT messages with ACCEPTED (if proposal number matches promise)
  """

  use GenServer

  alias PaxosConsensus.Paxos.{Proposal, Promise, Accepted}

  defstruct [
    :node_id,
    :highest_proposal_seen,
    :accepted_proposal,
    :accepted_value
  ]

  @type state :: %__MODULE__{
          node_id: atom(),
          highest_proposal_seen: non_neg_integer(),
          accepted_proposal: non_neg_integer() | nil,
          accepted_value: any() | nil
        }

  ## Client API

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    GenServer.start_link(__MODULE__, node_id, name: node_id)
  end

  def get_state(acceptor) do
    GenServer.call(acceptor, :get_state)
  end

  ## Server Callbacks

  @impl true
  def init(node_id) do
    state = %__MODULE__{
      node_id: node_id,
      highest_proposal_seen: 0,
      accepted_proposal: nil,
      accepted_value: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:prepare, proposal_number, from}, state) do
    if proposal_number > state.highest_proposal_seen do
      # Send PROMISE with any previously accepted proposal
      accepted_proposal =
        if state.accepted_proposal do
          %Proposal{number: state.accepted_proposal, value: state.accepted_value}
        else
          nil
        end

      promise = %Promise{
        proposal_number: proposal_number,
        accepted_proposal: accepted_proposal,
        from: state.node_id
      }

      # Send promise back to proposer - handle both PID and atom names
      cond do
        is_pid(from) ->
          send(from, {:promise, promise})

        is_atom(from) ->
          case Process.whereis(from) do
            nil ->
              # If proposer process not found, skip sending
              :ok

            pid ->
              send(pid, {:promise, promise})
          end

        true ->
          # Unknown from type, skip
          :ok
      end

      # Broadcast to dashboard
      Phoenix.PubSub.broadcast(
        PaxosConsensus.PubSub,
        "paxos_updates",
        {:promise_sent, state.node_id, proposal_number, from}
      )

      new_state = %{state | highest_proposal_seen: proposal_number}
      {:noreply, new_state}
    else
      # Ignore proposals with lower numbers
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:accept, proposal_number, value, from}, state) do
    if proposal_number >= state.highest_proposal_seen do
      # Accept the proposal
      accepted = %Accepted{
        proposal_number: proposal_number,
        value: value,
        from: state.node_id
      }

      # Send accepted back to proposer
      # Also notify any learners listening
      Phoenix.PubSub.broadcast(
        PaxosConsensus.PubSub,
        "learner_updates",
        {:accepted, accepted}
      )

      # Send to proposer - handle both PID and atom names  
      cond do
        is_pid(from) ->
          send(from, {:accepted, accepted})

        is_atom(from) ->
          case Process.whereis(from) do
            nil ->
              # If proposer process not found, skip sending
              :ok

            pid ->
              send(pid, {:accepted, accepted})
          end

        true ->
          # Unknown from type, skip
          :ok
      end

      # Broadcast to dashboard
      Phoenix.PubSub.broadcast(
        PaxosConsensus.PubSub,
        "paxos_updates",
        {:accepted_sent, state.node_id, proposal_number, value, from}
      )

      new_state = %{
        state
        | highest_proposal_seen: proposal_number,
          accepted_proposal: proposal_number,
          accepted_value: value
      }

      {:noreply, new_state}
    else
      # Reject proposals with lower numbers
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end
end
