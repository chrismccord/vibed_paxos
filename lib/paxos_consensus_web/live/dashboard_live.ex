defmodule PaxosConsensusWeb.DashboardLive do
  use PaxosConsensusWeb, :live_view

  alias PaxosConsensus.Paxos.{Proposer, Acceptor, Learner}

  def mount(_params, _session, socket) do
    # Subscribe to all Paxos updates
    Phoenix.PubSub.subscribe(PaxosConsensus.PubSub, "paxos_updates")
    Phoenix.PubSub.subscribe(PaxosConsensus.PubSub, "learner_updates")

    initial_state = %{
      # Node management
      proposers: %{},
      acceptors: %{},
      learners: %{},
      node_counter: 0,

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

    # Stop existing nodes
    stop_all_nodes(socket.assigns)

    # Start new nodes
    {proposers, acceptors, learners} = start_paxos_cluster(count)

    message = %{
      timestamp: DateTime.utc_now(),
      type: :system,
      content: "Started #{count} acceptors, 1 proposer, 1 learner"
    }

    {:noreply,
     socket
     |> assign(:proposers, proposers)
     |> assign(:acceptors, acceptors)
     |> assign(:learners, learners)
     |> assign(:node_counter, count)
     |> add_message(message)}
  end

  def handle_event("propose_value", %{"proposal" => %{"value" => value}}, socket) do
    case get_random_proposer(socket.assigns.proposers) do
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
    stop_all_nodes(socket.assigns)

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
    # Start acceptors
    acceptors =
      for i <- 1..acceptor_count, into: %{} do
        acceptor_id = :"acceptor_#{i}"
        {:ok, pid} = Acceptor.start_link(node_id: acceptor_id)
        {acceptor_id, pid}
      end

    acceptor_ids = Map.keys(acceptors)

    # Start proposer
    proposer_id = :proposer_1
    {:ok, proposer_pid} = Proposer.start_link(node_id: proposer_id, acceptors: acceptor_ids)
    proposers = %{proposer_id => proposer_pid}

    # Start learner
    learner_id = :learner_1
    {:ok, learner_pid} = Learner.start_link(node_id: learner_id, acceptors: acceptor_ids)
    learners = %{learner_id => learner_pid}

    {proposers, acceptors, learners}
  end

  defp stop_all_nodes(assigns) do
    # Stop all GenServers safely
    all_pids =
      Map.values(assigns.proposers) ++
        Map.values(assigns.acceptors) ++
        Map.values(assigns.learners)

    Enum.each(all_pids, fn pid ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)
  end

  defp get_random_proposer(proposers) when map_size(proposers) == 0, do: nil

  defp get_random_proposer(proposers) do
    proposers |> Enum.random()
  end

  defp add_message(socket, message) do
    new_log = [message | socket.assigns.message_log] |> Enum.take(20)
    assign(socket, :message_log, new_log)
  end
end
