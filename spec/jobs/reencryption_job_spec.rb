require "rails_helper"

# Smoke do ReencryptionJob: cobre o caminho do AdminRoleJob (BYPASSRLS)
# e verifica que cada target conta as linhas tocadas.
# Não testa "rotação real" entre chaves — isso exigiria injetar prior_keys
# mid-suite, fora deste escopo.
RSpec.describe ReencryptionJob do
  self.use_transactional_tests = false

  let(:muni_slug) { "reencrypt-test-#{SecureRandom.hex(4)}" }

  before do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM consents")
      ApplicationRecord.connection.execute("DELETE FROM inbound_messages")
      ApplicationRecord.connection.execute("DELETE FROM municipality_channels")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM users")
      ApplicationRecord.connection.execute("DELETE FROM municipalities WHERE slug LIKE 'reencrypt-test-%'")
    end
    Current.reset
  end

  after do
    ApplicationRecord.connected_to(role: :admin) do
      ApplicationRecord.connection.execute("DELETE FROM consents")
      ApplicationRecord.connection.execute("DELETE FROM inbound_messages")
      ApplicationRecord.connection.execute("DELETE FROM municipality_channels")
      ApplicationRecord.connection.execute("DELETE FROM conversations")
      ApplicationRecord.connection.execute("DELETE FROM users")
      ApplicationRecord.connection.execute("DELETE FROM municipalities WHERE slug LIKE 'reencrypt-test-%'")
    end
    Current.reset
  end

  it "executa sem levantar e conta linhas re-encriptadas por target" do
    ApplicationRecord.connected_to(role: :admin) do
      User.create!(email_address: "rotate@example.org", password: "secret123", otp_secret: "S3CR3T")
      muni = Municipality.create!(name: "Rotate", slug: muni_slug)
      Conversation.create!(municipality_id: muni.id, phone: "+551199999", state: :greeting)
      MunicipalityChannel.create!(
        municipality: muni, phone_number_id: "PN-#{SecureRandom.hex(3)}",
        waba_id: "W", display_phone_number: "+5511", access_token: "tok", active: true
      )
    end

    stats = described_class.new.perform
    expect(stats["User"]).to be >= 1
    expect(stats["Conversation"]).to be >= 1
    expect(stats["MunicipalityChannel"]).to be >= 1
  end

  it "limita target via :only" do
    ApplicationRecord.connected_to(role: :admin) do
      User.create!(email_address: "scoped@example.org", password: "secret123", otp_secret: "X")
    end

    stats = described_class.new.perform(only: [:user])
    expect(stats.keys).to eq(["User"])
    expect(stats["User"]).to be >= 1
  end
end
