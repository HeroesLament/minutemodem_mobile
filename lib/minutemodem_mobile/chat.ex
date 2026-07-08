defmodule MinutemodemMobile.Chat do
  @moduledoc """
  ALE Text Chat context (MIL-STD-188-141D 4G, G.5.6).

  Chat is link-scoped and unacknowledged. Conversations are keyed by the far
  end of the active link (`peer_addr`) — an individual station or a
  multipoint-group (net) address. Outbound text is transmitted via
  `Minutewave.ALE.Link.send_message/2`; inbound text arrives as an
  `{:ale, :message, payload}` event and is recorded with `record_received/2`.
  """
  import Ecto.Query

  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.ChatMessage
  alias Minutewave.ALE.Link

  @doc "Messages for a conversation (peer address), oldest first."
  def thread(peer_addr) when is_integer(peer_addr) do
    Repo.all(
      from m in ChatMessage,
        where: m.peer_addr == ^peer_addr,
        order_by: [asc: m.inserted_at]
    )
  end

  def thread(_), do: []

  @doc "Distinct peer addresses that have chat history (conversation list)."
  def peers do
    Repo.all(from m in ChatMessage, distinct: true, select: m.peer_addr)
  end

  @doc """
  Record an inbound message decoded off the air.

  `conversation_addr` is the thread key — normally the active link's peer/group
  address; falls back to the message sender when there is no link context. The
  `payload` is the `{:ale, :message, payload}` map.
  """
  def record_received(conversation_addr, payload) when is_map(payload) do
    peer = conversation_addr || payload[:from]

    %ChatMessage{}
    |> ChatMessage.changeset(%{
      direction: "received",
      peer_addr: peer,
      sender_addr: payload[:from],
      text: payload[:text] || "",
      parity_errors: payload[:parity_errors] || 0,
      status: "received",
      network_id: payload[:network_id]
    })
    |> Repo.insert()
  end

  @doc """
  Send text on the active link: transmit via `Link.send_message/2` and, on
  success, persist it as a sent message. Returns `{:ok, message}` or
  `{:error, reason}` (e.g. `:not_linked`, `:non_ascii`, `{:too_long, _, _}`).
  Nothing is persisted if the transmission is rejected.
  """
  def send(rig_id, self_addr, peer_addr, text, opts \\ []) when is_binary(text) do
    case Link.send_message(rig_id, text) do
      :ok ->
        %ChatMessage{}
        |> ChatMessage.changeset(%{
          direction: "sent",
          peer_addr: peer_addr,
          sender_addr: self_addr,
          text: text,
          status: "sent",
          network_id: Keyword.get(opts, :network_id)
        })
        |> Repo.insert()

      {:error, reason} ->
        {:error, reason}
    end
  end
end
