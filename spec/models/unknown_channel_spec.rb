require "rails_helper"

# Roteamento de phone_number_id desconhecido (Whatsapp::Ingest.route), agora
# na plataforma — lido antes de saber a cidade (ADR do banco-por-cidade).
#
# use_transactional_tests = false: record! chama Platform.audit, que grava em
# domain_events (banco compartilhado) via connected_to(role: :admin) para
# bypassar RLS. Sob transactional fixtures o Rails funde writing/admin numa
# única conexão física para o rollback funcionar, anulando o bypass — mesmo
# motivo documentado em spec/events/platform_spec.rb e
# spec/services/whatsapp/ingest_spec.rb.
#
# Cada exemplo usa seu próprio phone_number_id aleatório e limpa só o que ele
# mesmo criou — nada de delete_all na tabela inteira, que mascararia bugs de
# limpeza em outras specs (ex.: spec/services/whatsapp/ingest_spec.rb).
RSpec.describe UnknownChannel do
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  let(:phone_number_id) { "pn-#{SecureRandom.hex(6)}" }

  after do
    described_class.where(phone_number_id: phone_number_id).delete_all
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql([
          "DELETE FROM domain_events WHERE name = 'channel.unknown_seen' AND payload ->> 'phone_number_id' = ?",
          phone_number_id
        ])
      )
    end
  end

  it "lives in the platform database" do
    expect(described_class.connection_db_config.database).to match(/platform/)
  end

  it "creates a row on first sight, keeping only routing metadata" do
    row = described_class.record!(
      phone_number_id: phone_number_id,
      change: { "field" => "messages", "value" => { "messaging_product" => "whatsapp",
                                                     "metadata" => { "phone_number_id" => phone_number_id,
                                                                     "display_phone_number" => "+55 41 0000-0000" } } }
    )

    expect(row).to be_persisted
    expect(row.first_seen_at).to be_present
    expect(row.last_seen_at).to eq(row.first_seen_at)
    expect(row.sample_change).to eq(
      "field" => "messages",
      "messaging_product" => "whatsapp",
      "phone_number_id" => phone_number_id,
      "display_phone_number" => "+55 41 0000-0000"
    )
  end

  it "increments hits on repeat sightings" do
    first = described_class.record!(phone_number_id: phone_number_id, change: { "n" => 1 })

    second = described_class.record!(phone_number_id: phone_number_id, change: { "n" => 2 })

    expect(second.hits).to eq(first.hits + 1)
  end

  it "preserves first_seen_at across repeat sightings" do
    first = described_class.record!(phone_number_id: phone_number_id, change: {})
    original_first_seen_at = first.first_seen_at

    travel_to(1.hour.from_now) do
      second = described_class.record!(phone_number_id: phone_number_id, change: {})

      expect(second.first_seen_at).to be_within(1.second).of(original_first_seen_at)
      expect(second.last_seen_at).to be > second.first_seen_at
    end
  end

  it "publishes a platform audit event with only phone_number_id and hits, while hits <= 3" do
    expect {
      described_class.record!(phone_number_id: phone_number_id, change: {})
    }.to change {
      ApplicationRecord.connected_to(role: :admin) { DomainEvent.where(name: "channel.unknown_seen").count }
    }.by(1)

    ApplicationRecord.connected_to(role: :admin) do
      event = DomainEvent.where(name: "channel.unknown_seen").order(occurred_at: :desc).first
      expect(event.payload.keys).to contain_exactly("phone_number_id", "hits")
      expect(event.payload["phone_number_id"]).to eq(phone_number_id)
    end
  end

  # F-plataforma-sem-dado-de-cidadão: um phone_number_id desconhecido chega
  # com o payload de webhook inteiro (mensagem, contato, status) — nada disso
  # pode pousar na plataforma. Prova por LEITURA CRUA da coluna (não round-trip
  # pelo model, que já passaria pelo decode do driver) que só o metadado de
  # roteamento permitido sobrevive, em qualquer profundidade do JSON gravado.
  it "redacts citizen data out of sample_change, keeping only routing metadata" do
    citizen_phone = "+5541999998888"
    profile_name = "Maria da Silva"
    message_body = "Preciso de uma consulta urgente, meu CPF é 000.000.000-00"

    realistic_change = {
      "field" => "messages",
      "value" => {
        "messaging_product" => "whatsapp",
        "metadata" => {
          "display_phone_number" => "+55 41 0000-0000",
          "phone_number_id" => phone_number_id
        },
        "contacts" => [
          { "profile" => { "name" => profile_name }, "wa_id" => citizen_phone }
        ],
        "messages" => [
          { "from" => citizen_phone, "id" => "wamid.XYZ", "type" => "text",
            "text" => { "body" => message_body } }
        ],
        "statuses" => [
          { "id" => "wamid.XYZ", "status" => "delivered", "recipient_id" => citizen_phone }
        ]
      }
    }

    described_class.record!(phone_number_id: phone_number_id, change: realistic_change)

    raw = described_class.connection.select_value(
      described_class.sanitize_sql([
        "SELECT sample_change FROM unknown_channels WHERE phone_number_id = ?", phone_number_id
      ])
    )

    expect(raw).not_to include(citizen_phone)
    expect(raw).not_to include(profile_name)
    expect(raw).not_to include(message_body)
    expect(raw).not_to include("wa_id")
    expect(raw).not_to include("contacts")
    expect(raw).not_to include("statuses")
    expect(raw).not_to include("recipient_id")
    # "messages" itself is a legitimate value of the permitted "field" key
    # (webhook change type), so assert on the citizen-data-bearing keys
    # instead of the substring: neither the messages array nor its "text"/
    # "id" wrapper made it into storage.
    expect(raw).not_to include("\"text\"")
    expect(raw).not_to include("wamid.")

    stored = JSON.parse(raw)
    expect(stored).to eq(
      "field" => "messages",
      "messaging_product" => "whatsapp",
      "phone_number_id" => phone_number_id,
      "display_phone_number" => "+55 41 0000-0000"
    )
  end

  it "stores no payload content when change is not a Hash" do
    row = described_class.record!(phone_number_id: phone_number_id, change: "not-a-hash-payload")

    raw = described_class.connection.select_value(
      described_class.sanitize_sql([
        "SELECT sample_change FROM unknown_channels WHERE phone_number_id = ?", phone_number_id
      ])
    )

    expect(raw).not_to include("not-a-hash-payload")
    expect(row.sample_change).to eq({})
  end
end
