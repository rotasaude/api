require "rails_helper"

# Contrato §13 E6: o CBO do liberador do laboratório vem do vínculo ativo mais
# antigo em qualquer unidade; vínculo encerrado não conta; sem vínculo, nil.
RSpec.describe Billing::Staff do
  let(:lab) { Billing::Establishment.new(type: "lab_provider", id: SecureRandom.uuid, cnes: "7654321", name: "Lab", kind: "lab") }
  let(:unit_a) { create_unit("UPA A", kind: "upa") }
  let(:unit_b) { create_unit("UPA B", kind: "upa") }
  let(:user) { staff_with("liberador-#{SecureRandom.hex(3)}@cidade.gov.br", "lab_releaser") }

  # O vínculo é append-only (trigger): started_at entra na criação; encerrar só ended_at.
  def link!(unit, cbo, started_at:, ended_at: nil)
    admin = staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
    professional = user.professional || Professional.create!(user: user, professional_name: "Liberador", council: "CRM", council_state: "PR",
                                                             registration_number: (Professional.count + 10_000).to_s, cns: Professionals::Cns.generate(user.id))
    link = ProfessionalLink.create!(professional: professional, health_unit: unit, cbo_code: cbo, started_at: started_at, started_by_user: admin)
    link.update!(ended_at: ended_at, ended_by_user: admin) if ended_at
    link
  end

  it "laboratório: o vínculo ativo mais antigo, em qualquer unidade, dá o CBO" do
    link!(unit_b, "223505", started_at: 1.day.ago)
    link!(unit_a, "225125", started_at: 10.days.ago)
    expect(described_class.cbo_for(user, lab)).to eq("225125")
    expect(described_class.cbos_for(user, lab)).to eq(%w[225125 223505])
  end

  it "laboratório: vínculo encerrado é ignorado" do
    link!(unit_a, "225125", started_at: 10.days.ago, ended_at: 5.days.ago)
    link!(unit_b, "223505", started_at: 1.day.ago)
    expect(described_class.cbo_for(user, lab)).to eq("223505")
  end

  it "laboratório: sem vínculo ativo, nil" do
    expect(described_class.cbo_for(user, lab)).to be_nil
    link!(unit_a, "225125", started_at: 10.days.ago, ended_at: 5.days.ago)
    expect(described_class.cbo_for(user, lab)).to be_nil
  end

  it "unidade: só vale o vínculo da unidade" do
    link!(unit_a, "225125", started_at: 10.days.ago)
    unit = Billing::Establishment.for_unit(unit_b)
    expect(described_class.cbo_for(user, unit)).to be_nil
    expect(described_class.cbo_for(user, Billing::Establishment.for_unit(unit_a))).to eq("225125")
  end

  it "sem usuário, os quatro auxiliares respondem vazio sem levantar" do
    expect(described_class.cbo_for(nil, lab)).to be_nil
    expect(described_class.cns(nil)).to be_nil
    expect(described_class.linked?(nil, unit_a.id)).to be(false)
    expect(described_class.cbos_for(nil, lab)).to eq([])
    expect(described_class.eligible?(nil, lab)).to be(false)
    expect(described_class.non_aps_units(nil)).to be_empty
  end
end
