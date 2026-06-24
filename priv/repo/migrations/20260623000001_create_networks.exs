defmodule MinutemodemMobile.Repo.Migrations.CreateNetworks do
  use Ecto.Migration

  def change do
    create table(:networks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :active, :boolean, null: false, default: false
      add :params, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:networks, [:name])
    create index(:networks, [:active])
  end
end
