defmodule MinutemodemMobile.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  def change do
    create table(:contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :generation, :string, null: false, default: "4g"

      # 2G ALE — ASCII address
      add :addr_2g, :string

      # 3G ALE — 11-bit address split into dwell group (5 LSB) + member (6 MSB)
      add :grp_3g, :integer
      add :mbr_3g, :integer

      # 4G ALE — user-process (alphanumeric) or PDU (16-bit) forms
      add :form_4g, :string, default: "user_process"
      add :up_4g, :string
      add :pdu_4g, :integer
      add :net_4g, :integer
      add :multipoint_4g, :boolean, null: false, default: false

      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:contacts, [:generation])
    create index(:contacts, [:position])
  end
end
