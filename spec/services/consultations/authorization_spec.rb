require "rails_helper"

# ADR 0031 (spec §4; Desvio 2): consulta por profissional com papel, vínculo
# ativo na unidade e CBO da tabela do MIAI fora de 2232.
RSpec.describe Consultations::Authorization do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }

  def check(user) = ApplicationRecord.transaction { described_class.link_for(user: user, health_unit_id: unit.id) }

  { "225125" => :ok, "223505" => :ok, "225142" => :ok, "223293" => :cbo_not_allowed, "322205" => :cbo_not_allowed }.each do |cbo, expected|
    it("CBO #{cbo} → #{expected}") { expect(check(doctor!(unit, cbo: cbo)).first).to eq(expected) }
  end

  # 223208 (dentista) não está na tabela do MIAI; o stub isola a exclusão 2232.
  it "CBO 2232xx é recusado pelo recorte da spec mesmo se o MIAI o aceitasse" do
    expect(Ledi::ScreeningMapping.miai_cbo?("223208")).to be(false)
    allow(Ledi::ScreeningMapping).to receive(:miai_cbo?).and_call_original
    allow(Ledi::ScreeningMapping).to receive(:miai_cbo?).with("223208").and_return(true)
    expect(Consultations::Cbos.allowed?("223208")).to be(false)
    expect(check(doctor!(unit, cbo: "223208")).first).to eq(:cbo_not_allowed)
  end

  it "sem papel, sem vínculo na unidade; dois vínculos, vale o permitido" do
    expect(check(reception!)).to eq([ :missing_role, nil ])
    expect(check(doctor!(create_unit("UBS Outra"))).first).to eq(:missing_link)
    user = doctor!(unit, cbo: "322205")
    link_professional!(user, unit, cbo: "225125")
    status, link = check(user)
    expect([ status, link.cbo_code ]).to eq([ :ok, "225125" ])
    expect(described_class.any_link(user: user)).to eq(:ok)
    expect(described_class.any_link(user: reception!)).to eq(:missing_role)
  end

  it "tipo sugerido: horário marcado → consulta agendada; demanda espontânea → consulta no dia" do
    walk_in = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    scheduled = scheduled_attendance!(unit, citizen: screening_citizen!(2))
    expect([ Consultations::CareType.suggest(walk_in), Consultations::CareType.suggest(scheduled) ]).to eq([ 5, 2 ])
    expect([ 2, 5 ]).to all(satisfy { |code| Ledi::ConsultationMapping.care_type?(code) })
  end
end
