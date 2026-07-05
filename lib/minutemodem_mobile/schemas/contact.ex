defmodule MinutemodemMobile.Schemas.Contact do
  @moduledoc """
  A saved ALE contact, addressed in the format of a specific ALE generation.

  The three generations address nodes very differently, so a contact stores a
  `generation` and only the fields that generation uses:

  ## 2G ALE (MIL-STD-188-141 Appendix A)

  An address is a string of 1–15 characters drawn from the ALE "basic 38"
  character subset (`A–Z`, `0–9`, and `@` / `?`). Held in `addr_2g`.

  ## 3G ALE (Appendix C, synchronous mode)

  An 11-bit address with internal structure (C.4.5.1): the 5 LSBs are the
  **dwell group** number (0–31) and the 6 MSBs are the **member number** within
  that group (0–63). Held as `grp_3g` + `mbr_3g`; the packed value is
  `member <<< 5 ||| group` (see `MinutemodemMobile.Contacts.address_3g/1`).

  ## 4G ALE (Appendix G)

  Two forms, selected by `form_4g`:

    * `"user_process"` — an alphanumeric **User Process address** of 3–15
      printable ASCII characters (`up_4g`), shown on user interfaces.
    * `"pdu"` — a 16-bit binary **PDU address** (`pdu_4g`, 0–65535), optionally
      paired with a 16-bit **network number** (`net_4g`, NATO). `multipoint_4g`
      marks a multipoint address (a pre-programmed collection of PUs, analogous
      to a 2G net address) versus an individual PU.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @generations ~w(2g 3g 4g)
  @forms_4g ~w(user_process pdu)

  # 2G ALE basic-38 character subset and the 4G printable-ASCII range.
  @re_2g ~r/^[A-Z0-9@?]{1,15}$/
  @re_4g_up ~r/^[\x20-\x7E]{3,15}$/

  schema "contacts" do
    field :name, :string
    field :generation, :string, default: "4g"

    # 2G
    field :addr_2g, :string

    # 3G — dwell group (0-31) + member number (0-63)
    field :grp_3g, :integer
    field :mbr_3g, :integer

    # 4G
    field :form_4g, :string, default: "user_process"
    field :up_4g, :string
    field :pdu_4g, :integer
    field :net_4g, :integer
    field :multipoint_4g, :boolean, default: false

    field :position, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(name generation addr_2g grp_3g mbr_3g form_4g up_4g pdu_4g net_4g multipoint_4g position)a

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, @castable)
    |> update_change(:addr_2g, &upcase/1)
    |> validate_required([:name, :generation])
    |> validate_inclusion(:generation, @generations)
    |> validate_by_generation()
  end

  @doc "Valid generation strings (`\"2g\" | \"3g\" | \"4g\"`)."
  def generations, do: @generations

  @doc "Valid 4G address forms (`\"user_process\" | \"pdu\"`)."
  def forms_4g, do: @forms_4g

  # ── generation-specific validation ──────────────────────────────────────

  defp validate_by_generation(changeset) do
    case get_field(changeset, :generation) do
      "2g" -> validate_2g(changeset)
      "3g" -> validate_3g(changeset)
      "4g" -> validate_4g(changeset)
      _ -> changeset
    end
  end

  # Address fields are validated *when present* but not required, so a contact
  # can be created and its fields filled in one at a time. Completeness is
  # judged at use time by `Contacts.dest/1`.

  defp validate_2g(changeset) do
    validate_format(changeset, :addr_2g, @re_2g,
      message: "must be 1–15 chars of A–Z, 0–9, @ or ?"
    )
  end

  defp validate_3g(changeset) do
    changeset
    |> validate_number(:grp_3g, greater_than_or_equal_to: 0, less_than_or_equal_to: 31)
    |> validate_number(:mbr_3g, greater_than_or_equal_to: 0, less_than_or_equal_to: 63)
  end

  defp validate_4g(changeset) do
    changeset = validate_inclusion(changeset, :form_4g, @forms_4g)

    case get_field(changeset, :form_4g) do
      "pdu" ->
        changeset
        |> validate_number(:pdu_4g, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
        |> validate_net_4g()

      _ ->
        validate_format(changeset, :up_4g, @re_4g_up,
          message: "must be 3–15 printable ASCII characters"
        )
    end
  end

  # Network number is optional, but if present must be a 16-bit value.
  defp validate_net_4g(changeset) do
    if get_field(changeset, :net_4g) == nil do
      changeset
    else
      validate_number(changeset, :net_4g,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 65_535
      )
    end
  end

  defp upcase(nil), do: nil
  defp upcase(s) when is_binary(s), do: s |> String.trim() |> String.upcase()
  defp upcase(other), do: other
end
