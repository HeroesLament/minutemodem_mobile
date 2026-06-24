defmodule MinutemodemMobile.Repo.Migrations.CreateCallsigns do
  use Ecto.Migration

  def change do
    create table(:callsigns, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :addr, :integer, null: false
      add :name, :string
      add :callsign, :string
      add :source, :string, null: false
      add :first_heard, :utc_datetime_usec
      add :last_heard, :utc_datetime_usec
      add :heard_count, :integer, null: false, default: 0
      add :notes, :string
      add :protocol_config, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:callsigns, [:addr])
  end
end
