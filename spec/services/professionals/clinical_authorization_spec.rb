require "rails_helper"

RSpec.describe Professionals::ClinicalAuthorization do
  let(:unit) { create_unit }
  let(:other_unit) { create_unit("UPA Norte", kind: "upa") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }

  def check(user = doctor, unit_id = unit.id) = described_class.check(user: user, health_unit_id: unit_id)

  it "papel + vínculo ativo com a unidade: ok (qualquer CBO)" do
    link_professional!(doctor, unit, cbo: "225124")
    expect(check).to eq(:ok)
  end

  it "sem papel: missing_role, mesmo com vínculo" do
    link_professional!(doctor, unit)
    doctor.memberships.sole.revoke!
    expect(check).to eq(:missing_role)
  end

  it "papel sem perfil, sem vínculo, vínculo em outra unidade, vínculo encerrado: missing_link" do
    expect(check).to eq(:missing_link)
    link = link_professional!(doctor, other_unit)
    expect(check).to eq(:missing_link)
    link.update!(ended_at: Time.current, ended_by_user: link.started_by_user)
    expect(check(doctor, other_unit.id)).to eq(:missing_link)
  end

  it "nil: missing_role" do
    expect(described_class.check(user: nil, health_unit_id: unit.id)).to eq(:missing_role)
  end

  it "nunca consulta turnos" do
    link_professional!(doctor, unit)
    expect(ProfessionalShift).not_to receive(:where)
    expect(ProfessionalShift).not_to receive(:valid_shifts)
    expect(check).to eq(:ok)
  end
end
