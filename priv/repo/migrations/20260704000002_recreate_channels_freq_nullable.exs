defmodule MinutemodemMobile.Repo.Migrations.RecreateChannelsFreqNullable do
  use Ecto.Migration

  # SQLite can't drop a NOT NULL constraint in place, and the original
  # create_channels migration made freq_hz NOT NULL. The channel editor adds a
  # blank row (no freq yet) and fills it in, so freq_hz must be nullable. The
  # table holds no real data at this point, so we rebuild it.

  def up do
    drop_if_exists table(:channels)

    create table(:channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network_id, references(:networks, type: :binary_id, on_delete: :delete_all), null: false
      add :freq_hz, :integer
      add :name, :string
      add :mode, :string, null: false, default: "usb"
      add :role, :string, null: false, default: "none"
      add :enabled, :boolean, null: false, default: true
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:channels, [:network_id])
    create index(:channels, [:network_id, :position])
    create index(:channels, [:network_id, :role])
  end

  def down do
    drop_if_exists table(:channels)
  end
end
