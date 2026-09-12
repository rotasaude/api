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

  it "creates a row on first sight" do
    row = described_class.record!(phone_number_id: phone_number_id, change: { "foo" => "bar" })

    expect(row).to be_persisted
    expect(row.first_seen_at).to be_present
    expect(row.last_seen_at).to eq(row.first_seen_at)
    expect(row.sample_change).to eq({ "foo" => "bar" })
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

  it "publishes a platform audit event while hits <= 3" do
    expect {
      described_class.record!(phone_number_id: phone_number_id, change: {})
    }.to change {
      ApplicationRecord.connected_to(role: :admin) { DomainEvent.where(name: "channel.unknown_seen").count }
    }.by(1)
  end
end
