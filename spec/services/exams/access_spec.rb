require "rails_helper"

# Quem lê o exame (spec §7; Desvios 9 e 10): solicitante e leitura do 19a
# veem a forma clínica; a equipe só com o exame escalado; unidade e
# regulador a administrativa; prestador e estranho, nada.
RSpec.describe Exams::Access do
  before { exam_city! }

  let(:unit) { create_unit("UBS Acesso") }
  let(:other_unit) { create_unit("UBS Longe") }
  let(:doctor) { doctor!(unit) }
  let(:order) { exam_order!(patient: exam_patient!(20).first, unit: unit, requester: doctor) }

  def team!(user, unit) = exam_team!(unit, user)

  it "matriz de leitura" do
    expect(described_class.for_order(user: doctor, order: order)).to have_attributes(view: :clinical, kind: :author)
    stranger = doctor!(other_unit)
    expect(described_class.for_order(user: stranger, order: order)).to be_nil
    nurse = nurse!(unit)
    team!(nurse, unit)
    expect(described_class.for_order(user: nurse, order: order)).to have_attributes(view: :administrative, kind: :unit)
    ExamOrderEvent.transaction do
      ExamOrderEvent.create!(exam_order: order, kind: "escalated", escalation_reason: "overdue", occurred_at: Time.current)
      order.update!(escalated_at: Time.current)
    end
    expect(described_class.for_order(user: nurse, order: order.reload)).to have_attributes(view: :clinical, kind: :team)
    reception = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
    expect(described_class.for_order(user: reception, order: order)).to have_attributes(view: :administrative, kind: :unit)
    regulator = staff_with("reg-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_regulator")
    expect(described_class.for_order(user: regulator, order: order)).to have_attributes(view: :administrative, kind: :regulator)
    lab = staff_with("lab-#{SecureRandom.hex(2)}@cidade.gov.br", "exam_provider")
    expect(described_class.for_order(user: lab, order: order)).to be_nil
  end

  it "equipe = médico ou enfermeiro ativo em equipe ativa da unidade do exame" do
    tech = screener!(unit, cbo: "322205")
    team!(tech, unit)
    expect(described_class.team_member?(tech, unit.id)).to be(false)
    far_doctor = doctor!(other_unit)
    team!(far_doctor, other_unit)
    expect(described_class.team_member?(far_doctor, unit.id)).to be(false)
    expect(described_class.team_unit_ids(far_doctor)).to eq([ other_unit.id ])
  end
end
