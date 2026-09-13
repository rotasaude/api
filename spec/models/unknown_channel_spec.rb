require "rails_helper"

# Roteamento de phone_number_id desconhecido (Whatsapp::Ingest.route), agora
# na plataforma — lido antes de saber a cidade (ADR do banco-por-cidade).
#
# Transactional since 5c-1 (R15): the non-transactional mode and its manual
# cleanup existed only for the RLS bypass of Platform.audit.
RSpec.describe UnknownChannel do
  include ActiveSupport::Testing::TimeHelpers

  let(:phone_number_id) { "pn-#{SecureRandom.hex(6)}" }

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
    # Trap (5c-1 review): the event moved to PlatformEvent on the PLATFORM
    # (Ruling R18) — counting DomainEvent on whatever city happens to be
    # connected would never see it (ApplicationRecord.connected_to(role:
    # :admin) is a silent no-op, 5c-1), so this must read PlatformEvent
    # directly.
    expect {
      described_class.record!(phone_number_id: phone_number_id, change: {})
    }.to change(PlatformEvent, :count).by(1)

    event = PlatformEvent.where(name: "channel.unknown_seen").order(occurred_at: :desc).first
    expect(event.payload.keys).to contain_exactly("phone_number_id", "hits")
    expect(event.payload["phone_number_id"]).to eq(phone_number_id)
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
