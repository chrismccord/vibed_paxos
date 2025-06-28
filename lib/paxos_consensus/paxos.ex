defmodule PaxosConsensus.Paxos do
  @moduledoc """
  Core Paxos data structures and types for consensus algorithm implementation.
  """

  @type node_id :: atom()
  @type proposal_number :: non_neg_integer()
  @type value :: any()
  @type round_id :: non_neg_integer()

  defmodule Proposal do
    @moduledoc """
    Represents a proposal in the Paxos algorithm.
    """
    defstruct [:number, :value]

    @type t :: %__MODULE__{
            number: PaxosConsensus.Paxos.proposal_number(),
            value: PaxosConsensus.Paxos.value()
          }
  end

  defmodule Promise do
    @moduledoc """
    Represents a promise response from an acceptor.
    """
    defstruct [:proposal_number, :accepted_proposal, :from]

    @type t :: %__MODULE__{
            proposal_number: PaxosConsensus.Paxos.proposal_number(),
            accepted_proposal: Proposal.t() | nil,
            from: PaxosConsensus.Paxos.node_id()
          }
  end

  defmodule Accept do
    @moduledoc """
    Represents an accept message in the Paxos algorithm.
    """
    defstruct [:proposal_number, :value]

    @type t :: %__MODULE__{
            proposal_number: PaxosConsensus.Paxos.proposal_number(),
            value: PaxosConsensus.Paxos.value()
          }
  end

  defmodule Accepted do
    @moduledoc """
    Represents an accepted response from an acceptor.
    """
    defstruct [:proposal_number, :value, :from]

    @type t :: %__MODULE__{
            proposal_number: PaxosConsensus.Paxos.proposal_number(),
            value: PaxosConsensus.Paxos.value(),
            from: PaxosConsensus.Paxos.node_id()
          }
  end

  defmodule ConsensusRound do
    @moduledoc """
    Represents the state of a consensus round.
    """
    defstruct [
      :round_id,
      :proposal,
      :promises,
      :accepts,
      :phase,
      :result,
      :start_time
    ]

    @type phase :: :prepare | :accept | :completed | :failed
    @type t :: %__MODULE__{
            round_id: PaxosConsensus.Paxos.round_id(),
            proposal: Proposal.t() | nil,
            promises: [Promise.t()],
            accepts: [Accepted.t()],
            phase: phase(),
            result: PaxosConsensus.Paxos.value() | nil,
            start_time: DateTime.t()
          }
  end
end
