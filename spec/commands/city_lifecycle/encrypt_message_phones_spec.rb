require "rails_helper"

# api#19: linhas gravadas antes de `encrypts` têm o telefone em claro
# (InboundMessage#from, OutboundMessage#to). A migração de schema roda sem a
# chave da cidade, então a cifra das linhas antigas é um comando
# (city:encrypt_message_phones), rodado dentro da cidade.
RSpec.describe CityLifecycle::EncryptMessagePhones do
  before { Current.city = TEST_CITY_A }

  def insert_inbound_plaintext(from)
    id = SecureRandom.uuid
    InboundMessage.connection.exec_insert(
      InboundMessage.sanitize_sql([<<~SQL, id, "wamid.#{SecureRandom.hex(8)}", from])
        INSERT INTO inbound_messages (id, message_id, "from", kind, raw, created_at, updated_at)
        VALUES (?, ?, ?, 'text', NULL, now(), now())
      SQL
    )
    id
  end

  def insert_outbound_plaintext(to)
    id = SecureRandom.uuid
    OutboundMessage.connection.exec_insert(
      OutboundMessage.sanitize_sql([<<~SQL, id, to, "idem-#{SecureRandom.hex(8)}"])
        INSERT INTO outbound_messages (id, "to", idempotency_key, status, template, context, created_at, updated_at)
        VALUES (?, ?, ?, 200, '{}', '{}', now(), now())
      SQL
    )
    id
  end

  def stored(model, column, id)
    model.connection.select_value(
      model.sanitize_sql(["SELECT \"#{column}\" FROM #{model.table_name} WHERE id = ?", id])
    )
  end

  it "cifra o telefone em claro das duas tabelas, que passa a ser lido e achado normalmente" do
    in_id = insert_inbound_plaintext("5541988887777")
    out_id = insert_outbound_plaintext("5541988886666")

    expect(described_class.call).to eq("InboundMessage" => 1, "OutboundMessage" => 1)

    expect(stored(InboundMessage, :from, in_id)).not_to include("5541988887777")
    expect(InboundMessage.find(in_id).from).to eq("5541988887777")
    expect(InboundMessage.where(from: "5541988887777").pluck(:id)).to eq([in_id])

    expect(stored(OutboundMessage, :to, out_id)).not_to include("5541988886666")
    expect(OutboundMessage.find(out_id).to).to eq("5541988886666")
    expect(OutboundMessage.where(to: "5541988886666").pluck(:id)).to eq([out_id])
  end

  it "não toca linha já cifrada e é idempotente" do
    already = InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(8)}", from: "5541977776666", kind: "text")
    before = stored(InboundMessage, :from, already.id)
    insert_inbound_plaintext("5541966665555")
    insert_outbound_plaintext("5541966664444")

    expect(described_class.call).to eq("InboundMessage" => 1, "OutboundMessage" => 1)
    expect(described_class.call).to eq("InboundMessage" => 0, "OutboundMessage" => 0)
    expect(stored(InboundMessage, :from, already.id)).to eq(before)
  end

  it "exige cidade" do
    Current.set(city: nil) { expect { described_class.call }.to raise_error(CityEncryption::MissingKey) }
  end
end
