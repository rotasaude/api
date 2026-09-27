require "rails_helper"

RSpec.describe Professionals::Create do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:user) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:attrs) do
    { professional_name: "Helena Duarte", council: "CRM", council_state: "PR",
      registration_number: "12345", cns: "700000000000005", phone: "41998765432" }
  end

  it "cria o perfil e publica professional.created só com ids" do
    result = described_class.call(user_id: user.id, attrs: attrs, by: admin)
    expect(result).to be_ok
    professional = result.payload[:professional]
    expect(professional).to be_persisted
    event = DomainEvent.where(name: "professional.created").sole
    expect(event.payload).to eq("professional_id" => professional.id, "user_id" => user.id, "by_user_id" => admin.id)
  end

  it "usuário sem o papel ativo: user_missing_role" do
    plain = staff_with("viewer@cidade.gov.br", "viewer")
    expect(described_class.call(user_id: plain.id, attrs: attrs, by: admin).reason).to eq(:user_missing_role)
    expect(Professional.count).to eq(0)
  end

  it "papel revogado: user_missing_role" do
    user.memberships.sole.revoke!
    expect(described_class.call(user_id: user.id, attrs: attrs, by: admin).reason).to eq(:user_missing_role)
  end

  it "usuário inexistente: not_found" do
    expect(described_class.call(user_id: SecureRandom.uuid, attrs: attrs, by: admin).reason).to eq(:not_found)
  end

  it "segundo perfil do mesmo usuário: already_exists" do
    described_class.call(user_id: user.id, attrs: attrs, by: admin)
    expect(described_class.call(user_id: user.id, attrs: attrs, by: admin).reason).to eq(:already_exists)
  end

  it "campo inválido: invalid com a lista dos campos" do
    result = described_class.call(user_id: user.id, attrs: attrs.merge(cns: "123", council: "X"), by: admin)
    expect(result.reason).to eq(:invalid)
    expect(result.details[:fields]).to contain_exactly("cns", "council")
  end

  it "CNS de outro perfil: cns_taken; registro de outro perfil: registration_taken" do
    described_class.call(user_id: user.id, attrs: attrs, by: admin)
    other = staff_with("outra@cidade.gov.br", "health_professional")
    same_cns = attrs.merge(registration_number: "999")
    expect(described_class.call(user_id: other.id, attrs: same_cns, by: admin).reason).to eq(:cns_taken)
    same_registration = attrs.merge(cns: "100000000000007")
    expect(described_class.call(user_id: other.id, attrs: same_registration, by: admin).reason).to eq(:registration_taken)
  end
end
