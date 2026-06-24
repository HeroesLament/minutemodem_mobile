defmodule MinutemodemMobile.Repo.Migrations.CreateNetworkMembers do
  use Ecto.Migration

  def change do
    create table(:network_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network_id, references(:networks, type: :binary_id, on_delete: :delete_all), null: false
      add :callsign_id, references(:callsigns, type: :binary_id, on_delete: :delete_all), null: false
      add :alias, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:network_members, [:network_id])
    create index(:network_members, [:callsign_id])
    create unique_index(:network_members, [:network_id, :callsign_id])
  end
end
