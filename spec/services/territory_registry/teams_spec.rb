require "rails_helper"

# Módulo 24a (ADR 0042; contrato §9; F-24.8): a equipe da pessoa pelo
# cadastro individual ativo — a da microárea do domicílio (o cabeçalho a
# carrega e a cascata do SaveHousehold a mantém) ou, sem domicílio, a do
# cadastro fora de área (Desvio 3). Saída (moved | death) e equipe inativa
# não contam.
RSpec.describe TerritoryRegistry::Teams do
  before { registry_city! }

  let(:area) { registry_micro_area!(code: "01") }
  let(:team) { area.team }

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  def out_of_area!(team, patient = registry_patient!)
    result = TerritoryRegistry::SaveRegistration.call(params: registry_registration_params(team, patient: patient), by: registry_acs_of(team))
    raise "cadastro recusado: #{result.reason} #{result.details}" if result.failure?

    result.payload[:registration]
  end

  def exit!(registration, reason)
    params = { "reason" => reason, "on" => Time.zone.today.iso8601 }
    params["death_on"] = Time.zone.today.iso8601 if reason == "death"
    result = TerritoryRegistry::ExitRegistration.call(registration: registration, params: params, by: registry_acs_of(registration.household))
    raise "saída recusada: #{result.reason}" if result.failure?
  end

  it "cadastro ativo → equipe da microárea do domicílio; sem domicílio → a equipe do cadastro (fora de área)" do
    housed = registry_registration!(household: registry_household!(micro_area: area))
    other_team = registry_team!(care_unit!)
    outside = out_of_area!(other_team)
    expect(outside).to have_attributes(household_id: nil, team_id: other_team.id)
    expect(described_class.for_patients([ housed.patient_id, outside.patient_id ]))
      .to eq(housed.patient_id => team.id, outside.patient_id => other_team.id)
    expect(described_class.for_patients).to eq(housed.patient_id => team.id, outside.patient_id => other_team.id)
  end

  it "com team: só os cadastrados daquela equipe" do
    mine = registry_registration!(household: registry_household!(micro_area: area))
    theirs = registry_registration!
    expect(described_class.for_patients(nil, team: team)).to eq(mine.patient_id => team.id)
    expect(described_class.for_patients([ theirs.patient_id ], team: team)).to eq({})
    expect(described_class.for_patients([ mine.patient_id, theirs.patient_id ], team: theirs.team)).to eq(theirs.patient_id => theirs.team_id)
  end

  it "saída por mudança ou óbito e equipe inativa não contam" do
    moved = registry_registration!(household: registry_household!(micro_area: area))
    dead = registry_registration!(household: registry_household!(micro_area: area))
    inactive = registry_registration!
    exit!(moved, "moved")
    exit!(dead, "death")
    inactive.team.update!(active: false)
    expect(described_class.for_patients([ moved.patient_id, dead.patient_id, inactive.patient_id ])).to eq({})
  end

  it "lista vazia: {} sem consulta; com lista ou equipe, uma consulta só, qualquer que seja o número de cadastros" do
    expect(count_queries { expect(described_class.for_patients([])).to eq({}) }).to eq(0)
    registry_registration!(household: registry_household!(micro_area: area))
    small = count_queries { described_class.for_patients(nil, team: team) }
    expect(small).to eq(1)
    3.times { registry_registration!(household: registry_household!(micro_area: area)) }
    expect(count_queries { expect(described_class.for_patients(nil, team: team).size).to eq(4) }).to eq(small)
  end
end
