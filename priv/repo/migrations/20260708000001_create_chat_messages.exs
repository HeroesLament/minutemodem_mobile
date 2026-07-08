defmodule MinutemodemMobile.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :direction, :string, null: false
      add :peer_addr, :integer, null: false
      add :sender_addr, :integer
      add :text, :text, null: false
      add :parity_errors, :integer, null: false, default: 0
      add :status, :string, null: false, default: "sent"
      add :network_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat_messages, [:peer_addr])
    create index(:chat_messages, [:peer_addr, :inserted_at])
  end
end
