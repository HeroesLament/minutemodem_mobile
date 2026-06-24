defmodule MinutemodemMobile.Repo.Migrations.CreateLqaSoundings do
  use Ecto.Migration

  def change do
    create table(:lqa_soundings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network_id, references(:networks, type: :binary_id, on_delete: :delete_all), null: false
      add :callsign_id, references(:callsigns, type: :binary_id, on_delete: :delete_all), null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :freq_hz, :integer, null: false
      add :snr_db, :float
      add :ber, :float
      add :sinad_db, :float
      add :direction, :string
      add :frame_type, :string
      add :extra, :map, null: false, default: %{}
    end

    create index(:lqa_soundings, [:network_id])
    create index(:lqa_soundings, [:callsign_id])
    create index(:lqa_soundings, [:network_id, :freq_hz, :timestamp])
  end
end
