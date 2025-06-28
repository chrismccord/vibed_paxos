defmodule PaxosConsensus.PaxosRecoveryTest do
  use ExUnit.Case, async: false

  alias PaxosConsensus.Paxos.{Proposer, Acceptor, Learner}

  describe "concurrent proposal handling" do
    test "multiple rapid proposals achieve consensus in order" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Submit proposals sequentially with small delays to ensure ordering
      {:ok, round1} = Proposer.propose(proposer, "value_1")
      Process.sleep(10)
      {:ok, round2} = Proposer.propose(proposer, "value_2")
      Process.sleep(10)
      {:ok, round3} = Proposer.propose(proposer, "value_3")

      # Wait for all consensus
      Process.sleep(200)

      # Check results
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 3
      assert Map.get(learned_values, round1) == "value_1"
      assert Map.get(learned_values, round2) == "value_2"
      assert Map.get(learned_values, round3) == "value_3"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "proposer recovery with existing acceptor state" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # First proposer starts a round and completes prepare phase
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, round_id1} = Proposer.propose(proposer1, "crashed_value")

      # Wait for prepare phase to complete
      Process.sleep(50)

      # Check acceptor state to see if they have promises
      state1 = Acceptor.get_state(acceptor1)
      state2 = Acceptor.get_state(acceptor2)
      state3 = Acceptor.get_state(acceptor3)

      # Acceptors should have updated their highest_proposal_seen
      assert state1.highest_proposal_seen > 0
      assert state2.highest_proposal_seen > 0
      assert state3.highest_proposal_seen > 0

      # Crash the first proposer before accept phase
      GenServer.stop(proposer1)

      # Wait a bit to ensure no lingering messages
      Process.sleep(50)

      # New proposer with different value
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)
      {:ok, round_id2} = Proposer.propose(proposer2, "recovery_value")

      # Wait for consensus
      Process.sleep(150)

      # Check what was learned
      learned_values = Learner.get_learned_values(learner)

      # Either the crashed value or recovery value should be learned, but not both for same round
      if Map.has_key?(learned_values, round_id1) do
        # First round completed before crash
        assert Map.get(learned_values, round_id1) == "crashed_value"
        # Second round should also complete
        assert Map.get(learned_values, round_id2) == "recovery_value"
      else
        # First round didn't complete, second round should succeed
        assert Map.get(learned_values, round_id2) == "recovery_value"
      end

      # Cleanup
      GenServer.stop(proposer2)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "concurrent proposals from different proposers" do
      # Start 5 acceptors for more robust majority
      acceptor_pids =
        for i <- 1..5 do
          acceptor_id = :"acceptor_#{i}"
          {:ok, pid} = Acceptor.start_link(node_id: acceptor_id)
          {acceptor_id, pid}
        end

      acceptors = Enum.map(acceptor_pids, fn {id, _pid} -> id end)

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # Start 2 proposers
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)

      # Both propose at exactly the same time
      task1 = Task.async(fn -> Proposer.propose(proposer1, "concurrent_1") end)
      task2 = Task.async(fn -> Proposer.propose(proposer2, "concurrent_2") end)

      {:ok, round1} = Task.await(task1)
      {:ok, round2} = Task.await(task2)

      # Wait for consensus
      Process.sleep(300)

      # Check results - both should succeed but with different round IDs
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 2

      # Verify that each round has its own value
      assert Map.has_key?(learned_values, round1)
      assert Map.has_key?(learned_values, round2)

      # The values should be from the proposals (Paxos may choose either)
      values = Map.values(learned_values)
      assert "concurrent_1" in values or "concurrent_2" in values

      # Cleanup
      GenServer.stop(proposer1)
      GenServer.stop(proposer2)
      GenServer.stop(learner)
      for {_id, pid} <- acceptor_pids, do: GenServer.stop(pid)
    end
  end

  describe "timing and message ordering" do
    test "slow acceptor doesn't prevent consensus" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Propose a value
      {:ok, round_id} = Proposer.propose(proposer, "timing_test")

      # Simulate slow acceptor by stopping one temporarily
      GenServer.stop(acceptor3)

      # Should still achieve consensus with 2/3 majority
      Process.sleep(150)

      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id) == "timing_test"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(learner)
    end
  end
end
