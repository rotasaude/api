# spec/services/signatures/oauth_states_spec.rb
require "rails_helper"

# ADR 0032 (spec §10; Review Focus 4): state de uso único, amarrado à cidade, ao
# usuário e ao propósito; PKCE S256; 10 minutos.
RSpec.describe Signatures::OauthStates do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = signature_city! }
  after { Current.reset }

  let(:doctor) { signer_doctor!(create_unit) }

  def issue(**over) = described_class.issue!(user: doctor, purpose: "link", provider: "vidaas", return_to: "/conta/assinatura", **over)

  it "emite state assinado, verifier com o challenge S256 e guarda o verifier cifrado" do
    issued = issue
    expect(issued.challenge).to eq(Base64.urlsafe_encode64(Digest::SHA256.digest(issued.verifier), padding: false))
    expect(issued.verifier.size).to be >= 43
    raw = ApplicationRecord.connection.select_value("SELECT code_verifier FROM signature_oauth_states WHERE id = #{ApplicationRecord.connection.quote(issued.row.id)}")
    expect(raw).not_to include(issued.verifier)
    expect(issued.state).not_to include(issued.verifier)
  end

  it "consome uma vez só; outro usuário, outra cidade e adulterado não consomem" do
    issued = issue
    other = signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF)
    expect(described_class.consume(issued.state, user: other).reason).to eq(:invalid_state)
    Current.set(city: City.new(slug: "outra-cidade")) do
      expect(described_class.consume(issued.state, user: doctor).reason).to eq(:invalid_state)
    end
    expect(described_class.consume("#{issued.state}x", user: doctor).reason).to eq(:invalid_state)
    expect(described_class.consume(nil, user: doctor).reason).to eq(:invalid_state)
    expect(described_class.consume("a" * 5000, user: doctor).reason).to eq(:invalid_state)
    first = described_class.consume(issued.state, user: doctor)
    expect(first).to be_ok
    expect(first.payload[:state].code_verifier).to eq(issued.verifier)
    expect(described_class.consume(issued.state, user: doctor).reason).to eq(:invalid_state)
  end

  it "vencido: authorization_expired, e fica consumido" do
    issued = issue
    travel 11.minutes do
      expect(described_class.consume(issued.state, user: doctor).reason).to eq(:authorization_expired)
      expect(described_class.consume(issued.state, user: doctor).reason).to eq(:invalid_state)
    end
  end

  it "não vaza state nem verifier em inspect/to_s/mensagens" do
    issued = issue
    result = described_class.consume(issued.state, user: doctor)
    dump = [ issued.inspect, issued.to_s, issued.row.inspect, result.payload[:state].inspect,
             described_class.consume(issued.state, user: doctor).to_h.to_s ].join(" ")
    expect(dump).not_to include(issued.verifier)
    expect(dump).not_to include(issued.state)
  end

  it "o state de outro usuário adulterado não consome a linha" do
    issued = issue
    other = signer_doctor!(create_unit("UBS Tres"), cpf: SignatureHelpers::OTHER_CPF)
    described_class.consume(issued.state, user: other)
    expect(issued.row.reload.consumed_at).to be_nil
  end

  it "return_to só aceita caminho relativo do dashboard" do
    expect(described_class.safe_return_to("/signature/pendentes")).to eq("/signature/pendentes")
    [ "//evil.test/x", "https://evil.test", "assinatura", "/a b", "/\\evil.test", "/\\\\x", "/ok\\x", nil, 42, "/#{'x' * 300}" ].each do |value|
      expect(described_class.safe_return_to(value)).to eq("/"), value.inspect
    end
  end
end
