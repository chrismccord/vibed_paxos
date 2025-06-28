defmodule PaxosConsensus.Paxos.Proposer do
  @moduledoc """
  Implements the Proposer role in the Paxos consensus algorithm.

  The Proposer initiates consensus rounds by:
  1. Phase 1: Sending PREPARE messages to acceptors
  2. Phase 2: Sending ACCEPT messages if majority promises received
  """

  use GenServer

  alias PaxosConsensus.Paxos.{Proposal, ConsensusRound}

  defstruct [
    :node_id,
    :acceptors,
    :current_proposal_number,
    :active_rounds,
    :completed_rounds
  ]

  @type state :: %__MODULE__{
          node_id: atom(),
          acceptors: [atom()],
          current_proposal_number: non_neg_integer(),
          active_rounds: %{non_neg_integer() => ConsensusRound.t()},
          completed_rounds: [ConsensusRound.t()]
        }

  ## Client API

  def start_link(opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    acceptors = Keyword.fetch!(opts, :acceptors)

    # Generate unique proposal number base from node_id and timestamp
    # Use node_id hash to ensure different proposers have different starting points
    node_hash = :erlang.phash2(node_id) |> rem(100)
    timestamp = System.monotonic_time(:millisecond)
    unique_base = node_hash * 10000 + rem(timestamp, 10000)

    GenServer.start_link(__MODULE__, {node_id, acceptors, unique_base}, name: node_id)
  end

  def propose(proposer, value) do
    GenServer.call(proposer, {:propose, value})
  end

  def receive_promise(proposer, promise) do
    GenServer.cast(proposer, {:promise, promise})
  end

  def receive_accepted(proposer, accepted) do
    GenServer.cast(proposer, {:accepted, accepted})
  end

  def get_state(proposer) do
    GenServer.call(proposer, :get_state)
  end

  ## Server Callbacks

  @impl true
  def init({node_id, acceptors, unique_base}) do
    state = %__MODULE__{
      node_id: node_id,
      acceptors: acceptors,
      current_proposal_number: unique_base,
      active_rounds: %{},
      completed_rounds: []
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:promise, promise}, state) do
    handle_cast({:promise, promise}, state)
  end

  def handle_info({:accepted, accepted}, state) do
    handle_cast({:accepted, accepted}, state)
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:propose, value}, _from, state) do
    # Generate unique proposal number that's guaranteed to be higher
    # Use incremental counter plus unique integer to avoid conflicts
    proposal_number = state.current_proposal_number + 1 + :erlang.unique_integer([:positive])
    round_id = proposal_number

    proposal = %Proposal{
      number: proposal_number,
      value: value
    }

    round = %ConsensusRound{
      round_id: round_id,
      proposal: proposal,
      promises: [],
      accepts: [],
      phase: :prepare,
      result: nil,
      start_time: DateTime.utc_now()
    }

    # Send PREPARE messages to all acceptors
    Enum.each(state.acceptors, fn acceptor ->
      send(acceptor, {:prepare, proposal_number, state.node_id})
    end)

    # Broadcast to dashboard for real-time updates
    Phoenix.PubSub.broadcast(
      PaxosConsensus.PubSub,
      "paxos_updates",
      {:prepare_sent, round_id, proposal_number, value}
    )

    new_state = %{
      state
      | current_proposal_number: proposal_number,
        active_rounds: Map.put(state.active_rounds, round_id, round)
    }

    {:reply, {:ok, round_id}, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:promise, promise}, state) do
    case Map.get(state.active_rounds, promise.proposal_number) do
      nil ->
        # Promise for unknown round, ignore
        {:noreply, state}

      round ->
        # Check if we already have this promise (prevent duplicates)
        existing_promise = Enum.find(round.promises, fn p -> p.from == promise.from end)

        updated_round =
          if existing_promise do
            round
          else
            %{round | promises: [promise | round.promises]}
          end

        majority = div(length(state.acceptors), 2) + 1

        updated_round =
          if length(updated_round.promises) >= majority and updated_round.phase == :prepare do
            # We have majority promises, move to accept phase
            send_accept_messages(updated_round, state)
          else
            updated_round
          end

        new_state = %{
          state
          | active_rounds: Map.put(state.active_rounds, promise.proposal_number, updated_round)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:accepted, accepted}, state) do
    case Map.get(state.active_rounds, accepted.proposal_number) do
      nil ->
        # Accepted for unknown round, ignore
        {:noreply, state}

      round ->
        # Check if we already have this accepted (prevent duplicates)
        existing_accepted = Enum.find(round.accepts, fn a -> a.from == accepted.from end)

        updated_round =
          if existing_accepted do
            round
          else
            %{round | accepts: [accepted | round.accepts]}
          end

        majority = div(length(state.acceptors), 2) + 1

        if length(updated_round.accepts) >= majority do
          # Consensus achieved!
          completed_round = %{updated_round | phase: :completed, result: accepted.value}

          # Broadcast consensus achieved
          Phoenix.PubSub.broadcast(
            PaxosConsensus.PubSub,
            "paxos_updates",
            {:consensus_achieved, completed_round.round_id, accepted.value}
          )

          new_state = %{
            state
            | active_rounds: Map.delete(state.active_rounds, accepted.proposal_number),
              completed_rounds: [completed_round | state.completed_rounds]
          }

          {:noreply, new_state}
        else
          new_state = %{
            state
            | active_rounds: Map.put(state.active_rounds, accepted.proposal_number, updated_round)
          }

          {:noreply, new_state}
        end
    end
  end

  # Private helpers

  defp send_accept_messages(round, state) do
    # CRITICAL: Choose the value from the highest-numbered accepted proposal among promises
    # This is the core safety property of Paxos - if any acceptor has previously accepted
    # a proposal, we MUST use that value, not our own proposed value
    value =
      case find_highest_accepted_proposal(round.promises) do
        nil ->
          # No previous proposals, use our proposed value
          round.proposal.value

        highest_proposal ->
          # Previous proposal exists - we MUST use that value for safety
          highest_proposal.value
      end

    # Send ACCEPT messages to all acceptors
    Enum.each(state.acceptors, fn acceptor ->
      case Process.whereis(acceptor) do
        # Skip dead acceptors
        nil -> :ok
        _pid -> send(acceptor, {:accept, round.proposal.number, value, state.node_id})
      end
    end)

    # Broadcast accept phase started
    Phoenix.PubSub.broadcast(
      PaxosConsensus.PubSub,
      "paxos_updates",
      {:accept_sent, round.round_id, round.proposal.number, value}
    )

    # Update round phase
    %{round | phase: :accept}
  end

  defp find_highest_accepted_proposal(promises) do
    promises
    |> Enum.map(& &1.accepted_proposal)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.number, fn -> nil end)
  end
end
