require "rails_helper"

RSpec.describe Professionals::UpdateProfile do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:user) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:professional) do
    Professionals::Create.call(user_id: user.id, by: admin, attrs: {
      professional_name: "Helena Duarte", council: "CRM", council_state: "PR",
      registration_number: "12345", cns: "700000000000005"
    }).payload[:professional]
  end

  it "admin muda o conselho e o evento leva só os nomes dos campos" do
    result = described_class.call(professional: professional, attrs: { "council_state" => "SC", "phone" => "41998765432" }, by: admin)
    expect(result).to be_ok
    expect(professional.reload.council_state).to eq("SC")
    event = DomainEvent.where(name: "professional.profile_updated").sole
    expect(event.payload).to eq("professional_id" => professional.id, "fields" => %w[council_state phone],
                                "by_user_id" => admin.id)
  end

  it "mesmos valores: ok, sem evento" do
    described_class.call(professional: professional, attrs: { "council_state" => "PR", "cns" => "700000000000005" }, by: admin)
    expect(DomainEvent.where(name: "professional.profile_updated").count).to eq(0)
  end

  it "com allowed restrito, chave fora da lista: field_not_editable e nada muda" do
    result = described_class.call(professional: professional, attrs: { "professional_name" => "Helena D.", "cns" => "100000000000007" },
                                  by: user, allowed: Professional::SELF_EDITABLE)
    expect(result.reason).to eq(:field_not_editable)
    expect(result.details[:fields]).to eq(%w[cns])
    expect(professional.reload.professional_name).to eq("Helena Duarte")
  end

  it "user_id nunca é editável, nem pelo admin" do
    other = staff_with("outra@cidade.gov.br", "health_professional")
    result = described_class.call(professional: professional, attrs: { "user_id" => other.id }, by: admin)
    expect(result.reason).to eq(:field_not_editable)
  end

  it "valor inválido: invalid e nada muda" do
    result = described_class.call(professional: professional, attrs: { "contact_email" => "sem-arroba" }, by: user,
                                  allowed: Professional::SELF_EDITABLE)
    expect(result.reason).to eq(:invalid)
    expect(professional.reload.contact_email).to be_nil
  end

  describe "trocar o conselho com vínculo ativo cujo CBO exige o conselho antigo (D9)" do
    let(:unit) { create_unit }

    it "vínculo ativo com CBO que exige o conselho antigo: council_in_use e nada muda" do
      ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: "225125",
                               started_at: Time.current, started_by_user: admin)

      result = described_class.call(professional: professional, attrs: { "council" => "COREN" }, by: admin)

      expect(result.reason).to eq(:council_in_use)
      expect(result.details[:cbo_codes]).to eq(%w[225125])
      expect(professional.reload.council).to eq("CRM")
    end

    it "só um vínculo já encerrado com aquele CBO: permitido" do
      link = ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: "225125",
                                      started_at: Time.current, started_by_user: admin)
      link.update!(ended_at: Time.current, ended_by_user: admin)

      result = described_class.call(professional: professional, attrs: { "council" => "COREN" }, by: admin)

      expect(result).to be_ok
      expect(professional.reload.council).to eq("COREN")
    end

    it "vínculo ativo com CBO sem conselho exigido: permitido" do
      # Nenhum CBO real fica sem conselho hoje (ACS/ACE voltam com CNES, ADR
      # 0021 em aberto); stub `.all` (não só `.find`) porque ProfessionalLink
      # também valida cbo_code contra o catálogo na criação.
      council_less = Professionals::Cbo::Entry.new(code: "999998", title: "x", council: nil, deprecated: false)
      allow(Professionals::Cbo).to receive(:all).and_return(Professionals::Cbo.all + [ council_less ])
      ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: "999998",
                               started_at: Time.current, started_by_user: admin)

      result = described_class.call(professional: professional, attrs: { "council" => "COREN" }, by: admin)

      expect(result).to be_ok
      expect(professional.reload.council).to eq("COREN")
    end
  end
end
