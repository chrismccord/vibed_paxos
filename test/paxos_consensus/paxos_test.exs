defmodule PaxosConsensus.PaxosTest do
  use ExUnit.Case, async: false

  alias PaxosConsensus.Paxos.{Proposer, Acceptor, Learner}

  describe "basic paxos consensus" do
    test "single proposer achieves consensus" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      # Start 1 learner
      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # Start 1 proposer
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Propose a value
      {:ok, round_id} = Proposer.propose(proposer, "test_value")

      # Wait for consensus to be reached
      Process.sleep(100)

      # Check that learner learned the value
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id) == "test_value"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "multiple proposers with conflict resolution" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      # Start 1 learner
      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # Start 2 proposers
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)

      # Both proposers propose different values simultaneously
      task1 = Task.async(fn -> Proposer.propose(proposer1, "value_from_p1") end)
      task2 = Task.async(fn -> Proposer.propose(proposer2, "value_from_p2") end)

      {:ok, _round_id1} = Task.await(task1)
      {:ok, _round_id2} = Task.await(task2)

      # Wait for consensus to be reached
      Process.sleep(200)

      # Check that learner learned at least one value
      learned_values = Learner.get_learned_values(learner)

      # At least one of the proposals should succeed
      assert map_size(learned_values) >= 1

      # Check that the learned values are one of the proposed values
      for {_round_id, value} <- learned_values do
        assert value in ["value_from_p1", "value_from_p2"]
      end

      # Cleanup
      GenServer.stop(proposer1)
      GenServer.stop(proposer2)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "majority acceptors required for consensus" do
      # Start 3 acceptors but only allow 2 to participate
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      # Proposer only knows about 2 acceptors (should still work with majority)
      acceptors = [:acceptor1, :acceptor2]

      # Start learner with all 3 acceptors
      {:ok, learner} =
        Learner.start_link(node_id: :learner1, acceptors: [:acceptor1, :acceptor2, :acceptor3])

      # Start proposer with only 2 acceptors
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Propose a value
      {:ok, round_id} = Proposer.propose(proposer, "majority_test")

      # Wait for consensus
      Process.sleep(100)

      # Check that consensus was achieved with majority
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id) == "majority_test"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end
  end

  describe "paxos state management" do
    test "acceptor state is properly maintained" do
      {:ok, acceptor} = Acceptor.start_link(node_id: :test_acceptor)

      # Initial state should have no accepted proposals
      state = Acceptor.get_state(acceptor)
      assert state.highest_proposal_seen == 0
      assert state.accepted_proposal == nil
      assert state.accepted_value == nil

      # Send a prepare message
      send(acceptor, {:prepare, 1, :test_proposer})
      Process.sleep(10)

      # State should update
      state = Acceptor.get_state(acceptor)
      assert state.highest_proposal_seen == 1

      GenServer.stop(acceptor)
    end
  end
end
