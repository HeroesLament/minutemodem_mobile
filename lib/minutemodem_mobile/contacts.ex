defmodule MinutemodemMobile.Contacts do
  @moduledoc """
  Context for saved ALE contacts (`MinutemodemMobile.Schemas.Contact`).

  Besides CRUD, this resolves a contact's stored, generation-specific fields
  into the packed address values the ALE stack uses:

    * `address_3g/1` packs a 3G contact into its 11-bit value.
    * `display/1` renders a human-readable address for the UI.
    * `dest/1` returns a tagged destination the Linking layer can act on.
  """
  import Ecto.Query
  import Bitwise

  alias MinutemodemMobile.Repo
  alias MinutemodemMobile.Schemas.Contact

  @doc "All contacts, in display order (position, then age)."
  def list do
    Repo.all(from c in Contact, order_by: [asc: c.position, asc: c.inserted_at])
  end

  @doc "Fetch a contact by id, or nil."
  def get(id), do: Repo.get(Contact, id)

  @doc "Create a contact. Appends at the end of the list by default."
  def add(attrs \\ %{}) do
    attrs = attrs |> normalize_keys() |> Map.put_new("position", next_position())

    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
  rescue
    e -> {:error, e}
  end

  @doc "Update a contact by id."
  def update(id, attrs) do
    case Repo.get(Contact, id) do
      nil -> {:error, :not_found}
      c -> c |> Contact.changeset(normalize_keys(attrs)) |> Repo.update()
    end
  rescue
    e -> {:error, e}
  end

  @doc "Delete a contact by id (idempotent)."
  def delete(id) do
    case Repo.get(Contact, id) do
      nil -> :ok
      c -> Repo.delete(c) |> case(do: ({:ok, _} -> :ok; other -> other))
    end
  end

  # ── search ──────────────────────────────────────────────────────────────

  @doc """
  Filter an in-memory list of contacts by a free-text `query`, matching across
  **all** of a contact's format representations — name, generation, 2G ASCII
  address, 3G group/member/packed value, and 4G user-process / PDU / network
  numbers. Case-insensitive substring match, capped at 8 results.

  So a station saved as `NWNS7` is found by typing `S7`, `NWNS`, `7`, etc.,
  regardless of which generation format it uses. Operating on the already-
  loaded list keeps this off the database on every keystroke.
  """
  @spec search([Contact.t()], String.t()) :: [Contact.t()]
  def search(contacts, query) when is_list(contacts) and is_binary(query) do
    case String.downcase(String.trim(query)) do
      "" -> []
      q -> contacts |> Enum.filter(&matches?(&1, q)) |> Enum.take(8)
    end
  end

  @doc "True if `contact` matches the (already-downcased) query across any format."
  @spec matches?(Contact.t(), String.t()) :: boolean()
  def matches?(%Contact{} = contact, downcased_query) do
    String.contains?(search_blob(contact), downcased_query)
  end

  @doc """
  The value to drop into a call/destination field for this contact: the numeric
  address (3G packed / 4G PDU) as a string, or the alphanumeric address (2G /
  4G user-process), or `""` if incomplete.
  """
  @spec call_value(Contact.t()) :: String.t()
  def call_value(%Contact{} = c) do
    case dest(c) do
      {:addr, n} -> Integer.to_string(n)
      {:user_process, s} -> s
      {:ascii, s} -> s
      _ -> ""
    end
  end

  # A single lower-cased string blending every searchable representation.
  defp search_blob(%Contact{} = c) do
    packed = address_3g(c)

    [
      c.name,
      c.generation,
      c.addr_2g,
      c.up_4g,
      c.grp_3g && "grp#{c.grp_3g}",
      c.mbr_3g && "mbr#{c.mbr_3g}",
      packed && Integer.to_string(packed),
      c.pdu_4g && Integer.to_string(c.pdu_4g),
      c.net_4g && "net#{c.net_4g}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  # ── address resolution ──────────────────────────────────────────────────

  @doc """
  Packed 11-bit 3G address: member number in the 6 MSBs, dwell group in the
  5 LSBs (C.4.5.1). Returns nil if either part is missing.
  """
  @spec address_3g(Contact.t()) :: non_neg_integer() | nil
  def address_3g(%Contact{grp_3g: g, mbr_3g: m}) when is_integer(g) and is_integer(m) do
    (m <<< 5) ||| (g &&& 0x1F)
  end

  def address_3g(_), do: nil

  @doc "Human-readable address string for a contact, per its generation."
  @spec display(Contact.t()) :: String.t()
  def display(%Contact{generation: "2g", addr_2g: a}), do: a || "—"

  def display(%Contact{generation: "3g"} = c) do
    case address_3g(c) do
      nil -> "—"
      val -> "grp #{c.grp_3g} · mbr #{c.mbr_3g}  (#{val})"
    end
  end

  def display(%Contact{generation: "4g", form_4g: "user_process"} = c) do
    base = c.up_4g || "—"
    if c.multipoint_4g, do: base <> " (multipoint)", else: base
  end

  def display(%Contact{generation: "4g", form_4g: "pdu"} = c) do
    kind = if c.multipoint_4g, do: "multipoint", else: "PU"
    net = if c.net_4g, do: " · net #{c.net_4g}", else: ""
    "#{c.pdu_4g} (#{kind})#{net}"
  end

  def display(_), do: "—"

  @doc """
  Resolve a contact to a tagged destination for the Linking layer:

    * `{:addr, integer}` — a numeric ALE address (3G 11-bit, or 4G PDU 16-bit)
    * `{:user_process, string}` — a 4G alphanumeric User Process address
    * `{:ascii, string}` — a 2G ASCII address
    * `{:error, :incomplete}` — required fields missing
  """
  @spec dest(Contact.t()) ::
          {:addr, non_neg_integer()}
          | {:user_process, String.t()}
          | {:ascii, String.t()}
          | {:error, :incomplete}
  def dest(%Contact{generation: "2g", addr_2g: a}) when is_binary(a) and a != "", do: {:ascii, a}
  def dest(%Contact{generation: "3g"} = c) do
    case address_3g(c) do
      nil -> {:error, :incomplete}
      val -> {:addr, val}
    end
  end

  def dest(%Contact{generation: "4g", form_4g: "user_process", up_4g: up})
      when is_binary(up) and up != "",
      do: {:user_process, up}

  def dest(%Contact{generation: "4g", form_4g: "pdu", pdu_4g: p}) when is_integer(p),
    do: {:addr, p}

  def dest(_), do: {:error, :incomplete}

  # ── internals ───────────────────────────────────────────────────────────

  defp next_position do
    (Repo.one(from c in Contact, select: max(c.position)) || -1) + 1
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
