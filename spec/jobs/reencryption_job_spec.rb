require "rails_helper"

# Smoke do ReencryptionJob: cobre o caminho do AdminRoleJob (BYPASSRLS)
# e verifica que cada target conta as linhas tocadas.
# Não testa "rotação real" entre chaves — isso exigiria injetar prior_keys
# mid-suite, fora deste escopo.
RSpec.describe ReencryptionJob do
  let(:muni_slug) { "reencrypt-test-#{SecureRandom.hex(4)}" }

  before do
    Current.reset
  end

  after do
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
