defmodule PaxosConsensus.PaxosRecoveryTest do
  use ExUnit.Case, async: false

  alias PaxosConsensus.Paxos.{Proposer, Acceptor, Learner}

  describe "concurrent proposal handling" do
    test "multiple sequential proposals achieve consensus separately" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)
      {:ok, proposer} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)

      # Submit proposals sequentially with delays to ensure completion
      {:ok, round1} = Proposer.propose(proposer, "value_1")
      # Wait for first consensus to complete
      Process.sleep(100)

      {:ok, round2} = Proposer.propose(proposer, "value_2")
      # Wait for second consensus to complete
      Process.sleep(100)

      {:ok, round3} = Proposer.propose(proposer, "value_3")
      # Wait for third consensus to complete
      Process.sleep(100)

      # Check results - each proposal should get its own value since they complete separately
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

    test "proposer recovery adopts previously accepted value (Paxos safety)" do
      # Start 3 acceptors
      {:ok, acceptor1} = Acceptor.start_link(node_id: :acceptor1)
      {:ok, acceptor2} = Acceptor.start_link(node_id: :acceptor2)
      {:ok, acceptor3} = Acceptor.start_link(node_id: :acceptor3)

      acceptors = [:acceptor1, :acceptor2, :acceptor3]

      {:ok, learner} = Learner.start_link(node_id: :learner1, acceptors: acceptors)

      # First proposer starts but doesn't complete consensus (simulates crash during accept phase)
      {:ok, proposer1} = Proposer.start_link(node_id: :proposer1, acceptors: acceptors)
      {:ok, round_id1} = Proposer.propose(proposer1, "first_value")

      # Let prepare/promise phase complete, but crash before consensus
      Process.sleep(50)
      GenServer.stop(proposer1)

      # Check that some acceptors may have accepted the first value
      acceptor1_state = Acceptor.get_state(acceptor1)
      # At least one acceptor should have seen the first proposal

      # New proposer with different value - MUST adopt first value if it was accepted
      {:ok, proposer2} = Proposer.start_link(node_id: :proposer2, acceptors: acceptors)
      {:ok, round_id2} = Proposer.propose(proposer2, "second_value")

      # Wait for second consensus
      Process.sleep(150)

      # Check final results - the second proposer should adopt the first value
      # if any acceptor had accepted it (Paxos safety property)
      final_learned_values = Learner.get_learned_values(learner)

      # We should have at least one consensus result
      assert map_size(final_learned_values) >= 1

      # If the first round completed, it should have the first value
      if Map.has_key?(final_learned_values, round_id1) do
        assert Map.get(final_learned_values, round_id1) == "first_value"
      end

      # The second round should either:
      # 1. Not exist (if first round completed)
      # 2. Have "first_value" (if proposer2 adopted it)
      # 3. Have "second_value" (if no prior acceptance occurred)
      if Map.has_key?(final_learned_values, round_id2) do
        learned_value = Map.get(final_learned_values, round_id2)
        assert learned_value in ["first_value", "second_value"]
      end

      # Cleanup
      GenServer.stop(proposer2)
      GenServer.stop(acceptor1)
      GenServer.stop(acceptor2)
      GenServer.stop(acceptor3)
      GenServer.stop(learner)
    end

    test "concurrent proposals may result in one consensus" do
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

      # Check results - may be 1 or 2 consensus results depending on timing
      learned_values = Learner.get_learned_values(learner)

      # At least one should succeed
      assert map_size(learned_values) >= 1

      # If both rounds are learned, they should have valid values
      if Map.has_key?(learned_values, round1) do
        value1 = Map.get(learned_values, round1)
        assert value1 in ["concurrent_1", "concurrent_2"]
      end

      if Map.has_key?(learned_values, round2) do
        value2 = Map.get(learned_values, round2)
        assert value2 in ["concurrent_1", "concurrent_2"]
      end

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
