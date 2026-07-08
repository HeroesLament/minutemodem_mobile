defmodule MinutemodemMobile.Schemas.ChatMessage do
  @moduledoc """
  A single ALE Text Chat message (MIL-STD-188-141D 4G, G.5.6).

  Chat is **link-scoped** and **unacknowledged** — a message only exists in the
  context of an active link, there is no delivery confirmation, and `status`
  can never be more than `"sent"` for an outbound message.

  A conversation is keyed by `peer_addr`, the 16-bit WALE address of the far
  end of the link — an individual station or a multipoint-group (net) address.
  `sender_addr` records who actually originated the message, which matters for
  net conversations where several members share one thread.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w(sent received)

  schema "chat_messages" do
    # "sent" (we transmitted) or "received" (we decoded it off the air).
    field :direction, :string

    # Conversation key: the far end of the link (individual or group address).
    field :peer_addr, :integer

    # Who actually originated this message (our self address for a sent message;
    # the Message Header / carrier sender for a received one).
    field :sender_addr, :integer

    field :text, :string
    field :parity_errors, :integer, default: 0

    # "sent" | "received" | "failed". Never "delivered" — G.5.6 is unacknowledged.
    field :status, :string, default: "sent"

    # The active ALE network at the time, for later scoping (nullable).
    field :network_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(direction peer_addr sender_addr text parity_errors status network_id)a

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, @castable)
    |> validate_required([:direction, :peer_addr, :text])
    |> validate_inclusion(:direction, @directions)
  end

  @doc "Valid direction strings (`\"sent\" | \"received\"`)."
  def directions, do: @directions
end
