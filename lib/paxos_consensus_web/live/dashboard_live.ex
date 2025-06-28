defmodule PaxosConsensusWeb.DashboardLive do
  use PaxosConsensusWeb, :live_view

  alias PaxosConsensus.Paxos.{Proposer, Acceptor, Learner}
  alias PaxosConsensus.NodeRegistry

  def mount(_params, _session, socket) do
    # Subscribe to all Paxos updates
    Phoenix.PubSub.subscribe(PaxosConsensus.PubSub, "paxos_updates")
    Phoenix.PubSub.subscribe(PaxosConsensus.PubSub, "learner_updates")

    # Get current nodes from persistent registry
    nodes = NodeRegistry.get_all_nodes()
    stats = NodeRegistry.get_stats()

    initial_state = %{
      # Node management from registry
      proposers: nodes.proposers,
      acceptors: nodes.acceptors,
      learners: nodes.learners,
      node_counter: nodes.node_counter,

      # Real-time activity
      message_log: [],
      consensus_rounds: %{},
      active_round: nil,

      # Statistics
      total_rounds: 0,
      success_rate: 100.0,
      avg_latency: 0,

      # Form data
      proposal_form: to_form(%{"value" => ""}),
      node_form: to_form(%{"count" => "3"})
    }

    {:ok, assign(socket, initial_state)}
  end

  def handle_event("setup_nodes", %{"count" => count_str}, socket) do
    count = String.to_integer(count_str)

    # Clear existing nodes from registry
    NodeRegistry.clear_all_nodes()

    debug_message = %{
      timestamp: DateTime.utc_now(),
      type: :system,
      content: "DEBUG: Starting node creation process for #{count} acceptors..."
    }

    socket = add_message(socket, debug_message)

    # Start new nodes
    case start_paxos_cluster(count) do
      {proposers, acceptors, learners} ->
        # Register nodes in persistent registry
        NodeRegistry.register_nodes(proposers, acceptors, learners)

        success_message = %{
          timestamp: DateTime.utc_now(),
          type: :system,
          content:
            "✅ Started #{map_size(acceptors)} acceptors, #{map_size(proposers)} proposer, #{map_size(learners)} learner"
        }

        debug_pids = %{
          timestamp: DateTime.utc_now(),
          type: :system,
          content:
            "DEBUG: PIDs - Proposers: #{inspect(Map.values(proposers))}, Acceptors: #{inspect(Map.values(acceptors))}, Learners: #{inspect(Map.values(learners))}"
        }

        {:noreply,
         socket
         |> assign(:proposers, proposers)
         |> assign(:acceptors, acceptors)
         |> assign(:learners, learners)
         |> assign(:node_counter, count)
         |> add_message(success_message)
         |> add_message(debug_pids)}

      error ->
        error_message = %{
          timestamp: DateTime.utc_now(),
          type: :error,
          content: "❌ Failed to start nodes: #{inspect(error)}"
        }

        {:noreply, add_message(socket, error_message)}
    end
  end

  def handle_event("propose_value", %{"value" => value}, socket) do
    case NodeRegistry.get_random_proposer() do
      nil ->
        message = %{
          timestamp: DateTime.utc_now(),
          type: :error,
          content: "No proposers available. Setup nodes first."
        }

        {:noreply, add_message(socket, message)}

      {_id, proposer} ->
        case Proposer.propose(proposer, value) do
          {:ok, round_id} ->
            message = %{
              timestamp: DateTime.utc_now(),
              type: :propose,
              content: "Proposer initiated round #{round_id} with value: \"#{value}\""
            }

            {:noreply,
             socket
             |> assign(:active_round, round_id)
             |> add_message(message)
             |> assign(:proposal_form, to_form(%{"value" => ""}))}

          error ->
            message = %{
              timestamp: DateTime.utc_now(),
              type: :error,
              content: "Failed to propose: #{inspect(error)}"
            }

            {:noreply, add_message(socket, message)}
        end
    end
  end

  def handle_event("stop_all_nodes", _params, socket) do
    NodeRegistry.clear_all_nodes()

    message = %{
      timestamp: DateTime.utc_now(),
      type: :system,
      content: "All nodes stopped"
    }

    {:noreply,
     socket
     |> assign(:proposers, %{})
     |> assign(:acceptors, %{})
     |> assign(:learners, %{})
     |> assign(:node_counter, 0)
     |> assign(:active_round, nil)
     |> add_message(message)}
  end

  # Handle real-time PubSub messages from Paxos nodes
  def handle_info({:prepare_sent, round_id, proposal_number, value}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :prepare,
      content: "PREPARE(#{proposal_number}) sent for round #{round_id}: \"#{value}\""
    }

    {:noreply, add_message(socket, message)}
  end

  def handle_info({:promise_sent, acceptor_id, proposal_number, _from}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :promise,
      content: "#{acceptor_id} → PROMISE(#{proposal_number})"
    }

    {:noreply, add_message(socket, message)}
  end

  def handle_info({:accept_sent, round_id, proposal_number, value}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :accept,
      content: "ACCEPT(#{proposal_number}) sent for round #{round_id}: \"#{value}\""
    }

    {:noreply, add_message(socket, message)}
  end

  def handle_info({:accepted_sent, acceptor_id, proposal_number, value, _from}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :accepted,
      content: "#{acceptor_id} → ACCEPTED(#{proposal_number}): \"#{value}\""
    }

    {:noreply, add_message(socket, message)}
  end

  def handle_info({:consensus_achieved, round_id, value}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :consensus,
      content: "✅ CONSENSUS ACHIEVED! Round #{round_id}: \"#{value}\""
    }

    new_total = socket.assigns.total_rounds + 1

    {:noreply,
     socket
     |> assign(:total_rounds, new_total)
     |> assign(:active_round, nil)
     |> add_message(message)}
  end

  def handle_info({:value_learned, learner_id, proposal_number, value}, socket) do
    message = %{
      timestamp: DateTime.utc_now(),
      type: :learned,
      content: "#{learner_id} learned value for proposal #{proposal_number}: \"#{value}\""
    }

    {:noreply, add_message(socket, message)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Private helpers

  defp start_paxos_cluster(acceptor_count) do
    IO.puts("DEBUG: Starting #{acceptor_count} acceptors...")

    # Start acceptors
    acceptors =
      for i <- 1..acceptor_count, into: %{} do
        acceptor_id = :"acceptor_#{i}"
        IO.puts("DEBUG: Starting acceptor #{acceptor_id}...")

        case Acceptor.start_link(node_id: acceptor_id) do
          {:ok, pid} ->
            IO.puts("DEBUG: Acceptor #{acceptor_id} started with PID #{inspect(pid)}")
            {acceptor_id, pid}

          error ->
            IO.puts("ERROR: Failed to start acceptor #{acceptor_id}: #{inspect(error)}")
            raise "Failed to start acceptor #{acceptor_id}: #{inspect(error)}"
        end
      end

    acceptor_ids = Map.keys(acceptors)
    IO.puts("DEBUG: All acceptors started. IDs: #{inspect(acceptor_ids)}")

    # Start proposer
    proposer_id = :proposer_1
    IO.puts("DEBUG: Starting proposer #{proposer_id}...")

    {:ok, proposer_pid} =
      case Proposer.start_link(node_id: proposer_id, acceptors: acceptor_ids) do
        {:ok, pid} ->
          IO.puts("DEBUG: Proposer #{proposer_id} started with PID #{inspect(pid)}")
          {:ok, pid}

        error ->
          IO.puts("ERROR: Failed to start proposer #{proposer_id}: #{inspect(error)}")
          raise "Failed to start proposer #{proposer_id}: #{inspect(error)}"
      end

    proposers = %{proposer_id => proposer_pid}

    # Start learner
    learner_id = :learner_1
    IO.puts("DEBUG: Starting learner #{learner_id}...")

    {:ok, learner_pid} =
      case Learner.start_link(node_id: learner_id, acceptors: acceptor_ids) do
        {:ok, pid} ->
          IO.puts("DEBUG: Learner #{learner_id} started with PID #{inspect(pid)}")
          {:ok, pid}

        error ->
          IO.puts("ERROR: Failed to start learner #{learner_id}: #{inspect(error)}")
          raise "Failed to start learner #{learner_id}: #{inspect(error)}"
      end

    learners = %{learner_id => learner_pid}

    IO.puts("DEBUG: All nodes started successfully!")

    IO.puts(
      "DEBUG: Final counts - Proposers: #{map_size(proposers)}, Acceptors: #{map_size(acceptors)}, Learners: #{map_size(learners)}"
    )

    # Check if all processes are still alive
    all_alive =
      Enum.all?(
        Map.values(proposers) ++ Map.values(acceptors) ++ Map.values(learners),
        &Process.alive?/1
      )

    IO.puts("DEBUG: All processes alive? #{all_alive}")

    {proposers, acceptors, learners}
  end

  defp add_message(socket, message) do
    new_log = [message | socket.assigns.message_log] |> Enum.take(20)
    assign(socket, :message_log, new_log)
  end
end
