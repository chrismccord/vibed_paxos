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

  describe "edge cases and failure modes" do
    test "network partition prevents consensus without majority" do
      # Start 5 acceptors
      acceptor_pids =
        for i <- 1..5 do
          acceptor_id = :"acceptor_#{i}"
          {:ok, pid} = Acceptor.start_link(node_id: acceptor_id)
          {acceptor_id, pid}
        end

      all_acceptors = Enum.map(acceptor_pids, fn {id, _pid} -> id end)

      # Simulate network partition: proposer can only reach 2 out of 5 acceptors
      minority_acceptors = [:acceptor_1, :acceptor_2]

      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: minority_acceptors)
      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: all_acceptors)

      # Propose a value - should not achieve consensus (minority)
      {:ok, _round_id} = Proposer.propose(proposer, "partition_test")

      # Wait longer to ensure no consensus
      Process.sleep(200)

      # Learner should not have learned the value (no majority)
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 0

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(learner)
      for {_id, pid} <- acceptor_pids, do: GenServer.stop(pid)
    end

    test "acceptor failure during consensus round" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Start proposal
      {:ok, round_id} = Proposer.propose(proposer, "failure_test")

      # Immediately kill one acceptor to simulate failure
      GenServer.stop(acceptor3)

      # Wait for consensus with remaining majority
      Process.sleep(150)

      # Should still achieve consensus with 2/3 acceptors
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id) == "failure_test"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(learner)
    end

    test "proposer crash and recovery with higher proposal number" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # First proposer starts a round but crashes
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, _round_id1} = Proposer.propose(proposer1, "crashed_value")

      # Simulate crash by stopping proposer immediately
      GenServer.stop(proposer1)

      # Wait a bit
      Process.sleep(50)

      # New proposer with higher proposal number
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)
      {:ok, round_id2} = Proposer.propose(proposer2, "recovery_value")

      # Wait for consensus
      Process.sleep(100)

      # Should achieve consensus with the recovery value
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id2) == "recovery_value"

      # Cleanup
      GenServer.stop(proposer2)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "rapid successive proposals from same proposer" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Submit multiple proposals rapidly
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Proposer.propose(proposer, "rapid_value_#{i}")
          end)
        end

      # Wait for all proposals
      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert length(results) == 5

      for result <- results do
        assert match?({:ok, _}, result)
      end

      # Wait for all consensus rounds
      Process.sleep(300)

      # Check that learner learned all values
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 5

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "very large cluster with network delays" do
      # Start 7 acceptors for larger cluster
      acceptor_pids =
        for i <- 1..7 do
          acceptor_id = :"acceptor_#{i}"
          {:ok, pid} = Acceptor.start_link(node_id: acceptor_id)
          {acceptor_id, pid}
        end

      acceptors = Enum.map(acceptor_pids, fn {id, _pid} -> id end)

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Propose value
      {:ok, round_id} = Proposer.propose(proposer, "large_cluster_test")

      # Wait longer for larger cluster
      Process.sleep(250)

      # Should achieve consensus with majority (4/7)
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id) == "large_cluster_test"

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(learner)
      for {_id, pid} <- acceptor_pids, do: GenServer.stop(pid)
    end

    test "conflicting proposals with prior accepted values" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # First proposer achieves consensus
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, round_id1} = Proposer.propose(proposer1, "first_value")
      Process.sleep(100)

      # Verify first consensus
      learned_values = Learner.get_learned_values(learner)
      assert Map.get(learned_values, round_id1) == "first_value"

      # Second proposer tries different value
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)
      {:ok, round_id2} = Proposer.propose(proposer2, "second_value")
      Process.sleep(100)

      # Check final state
      final_learned_values = Learner.get_learned_values(learner)
      assert Map.get(final_learned_values, round_id1) == "first_value"
      assert Map.get(final_learned_values, round_id2) == "second_value"

      # Cleanup
      GenServer.stop(proposer1)
      GenServer.stop(proposer2)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "learner receives messages out of order" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Start multiple proposals concurrently
      task1 = Task.async(fn -> Proposer.propose(proposer, "msg_order_1") end)
      task2 = Task.async(fn -> Proposer.propose(proposer, "msg_order_2") end)
      task3 = Task.async(fn -> Proposer.propose(proposer, "msg_order_3") end)

      {:ok, _} = Task.await(task1)
      {:ok, _} = Task.await(task2)
      {:ok, _} = Task.await(task3)

      # Wait for all consensus
      Process.sleep(200)

      # Learner should handle all messages correctly despite order
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 3

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "stress test with high concurrency" do
      # Start 5 acceptors
      acceptor_pids =
        for i <- 1..5 do
          acceptor_id = :"stress_acceptor_#{i}"
          {:ok, pid} = Acceptor.start_link(node_id: acceptor_id)
          {acceptor_id, pid}
        end

      acceptors = Enum.map(acceptor_pids, fn {id, _pid} -> id end)

      {:ok, learner} = Learner.start_link(node_id: :stress_learner, acceptors: acceptors)

      # Start 3 proposers
      proposer_pids =
        for i <- 1..3 do
          proposer_id = :"stress_proposer_#{i}"
          {:ok, pid} = Proposer.start_link(node_id: proposer_id, acceptors: acceptors)
          {proposer_id, pid}
        end

      # Each proposer submits multiple proposals concurrently
      tasks =
        for {proposer_id, pid} <- proposer_pids,
            i <- 1..3 do
          Task.async(fn ->
            Proposer.propose(pid, "stress_#{proposer_id}_#{i}")
          end)
        end

      # Wait for all proposals
      results = Enum.map(tasks, &Task.await(&1, 2000))

      # All should succeed
      assert length(results) == 9

      for result <- results do
        assert match?({:ok, _}, result)
      end

      # Wait for consensus
      Process.sleep(500)

      # Should have learned all 9 values
      learned_values = Learner.get_learned_values(learner)
      assert map_size(learned_values) == 9

      # Cleanup
      for {_id, pid} <- proposer_pids, do: GenServer.stop(pid)
      for {_id, pid} <- acceptor_pids, do: GenServer.stop(pid)
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

    test "proposer increments proposal numbers correctly" do
      {:ok, acceptor1} = Acceptor.start_link(node_id: :test_acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :test_acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :test_acceptor3)

      acceptors = [:test_acceptor1, :test_acceptor2, :test_acceptor3]
      {:ok, proposer} = Proposer.start_link(node_id: :test_proposer, acceptors: acceptors)

      # Make multiple proposals
      {:ok, round1} = Proposer.propose(proposer, "proposal_1")
      {:ok, round2} = Proposer.propose(proposer, "proposal_2")
      {:ok, round3} = Proposer.propose(proposer, "proposal_3")

      # Proposal numbers should increment
      assert round2 > round1
      assert round3 > round2

      # Cleanup
      GenServer.stop(proposer)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
    end
  end
end
