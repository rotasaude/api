require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, §12, Q20, Q21): a coleta e a
# sorologia canina. Coleta de cão active (animal_not_dog, animal_not_active);
# inquérito open (survey_not_open); pelo app, só o ACE no escopo do domicílio
# do animal (cbo_not_allowed / out_of_scope) e o domicílio nos quarteirões do
# inquérito (household_not_in_survey path leish_survey_id); datas entre o
# início do inquérito (avulsa: hoje − 30) e hoje (date_out_of_range com o
# path); dpp_result e dpp_on juntos; ELISA só depois de DPP reagente
# (elisa_without_reactive_dpp path elisa_result); correção com
# expected_version (test_changed). Etiqueta pelo Zoonoses::Label, maiúscula.
RSpec.describe Zoonoses::RecordLeishTest, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:neighborhood) { Neighborhood.create!(name: "Bairro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:household) { registry_household!.tap { |row| vector_profile!(row, block: block) } }
  let(:survey) { leish_survey!(blocks: [ block ], starts_on: today - 5) }
  let(:dog) { animal!(household: household) }

  def ace_of(household)
    area = household.micro_area
    field_agent!(cbo: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO, team: area.team).tap { |agent| assignment!(area, agent.professional) }
  end

  def collect(by: team, origin: "dashboard", **over)
    params = { "leish_survey_id" => survey.id, "animal_id" => dog.id, "collected_on" => today.iso8601 }
               .merge(over.transform_keys(&:to_s)).reject { |_, value| value == :omit }
    described_class.call(params: params, by: by, origin: origin)
  end

  def correct(test, by: team, **fields)
    described_class.call(params: { "expected_version" => test.version }.merge(fields.transform_keys(&:to_s)), by: by, test: test)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "coleta pelo dashboard com DPP → etiqueta do inquérito em maiúsculas, evento só com o id" do
    result = collect(dpp_result: "reactive", dpp_on: today.iso8601)
    expect(result).to be_ok
    test = result.payload.fetch(:test)
    expect(test.label).to eq("LV-#{today.year}-#{survey.id.delete('-')[0, 6].upcase}-0001")
    expect(test.label).to match(Zoonoses::Catalog::LABEL)
    expect(test).to have_attributes(animal_id: dog.id, leish_survey_id: survey.id, collected_on: today, dpp_result: "reactive",
                                    dpp_on: today, result_by_user_id: team.id, version: 1)
    expect(DomainEvent.where(name: "leish_test.recorded").sole.payload).to eq("leish_test_id" => test.id)

    second = collect(animal_id: animal!(household: household).id)
    expect(second.payload[:test].label).to end_with("-0002")
    expect(second.payload[:test].result_by_user_id).to be_nil
    avulsa = collect(leish_survey_id: :omit)
    expect(avulsa.payload[:test]).to have_attributes(label: "LV-#{today.year}-AVUL-0001", leish_survey_id: nil)
  end

  it "ELISA sem DPP reagente → elisa_without_reactive_dpp path elisa_result" do
    expect(refusal(collect(elisa_result: "reactive", elisa_on: today.iso8601))).to eq([ :elisa_without_reactive_dpp, { path: "elisa_result" } ])
    expect(refusal(collect(dpp_result: "non_reactive", dpp_on: today.iso8601, elisa_result: "reactive", elisa_on: today.iso8601)))
      .to eq([ :elisa_without_reactive_dpp, { path: "elisa_result" } ])
    expect(refusal(collect(elisa_request: "GAL-123"))).to eq([ :elisa_without_reactive_dpp, { path: "elisa_request" } ])

    test = collect(dpp_result: "non_reactive", dpp_on: today.iso8601).payload[:test]
    expect(refusal(correct(test, elisa_result: "reactive", elisa_on: today.iso8601))).to eq([ :elisa_without_reactive_dpp, { path: "elisa_result" } ])
    reactive = correct(test, dpp_result: "reactive")
    expect(reactive).to be_ok
    elisa = correct(test.reload, elisa_result: "reactive", elisa_on: today.iso8601, elisa_request: "GAL-2026-0001")
    expect(elisa).to be_ok
    expect(test.reload).to have_attributes(elisa_result: "reactive", elisa_on: today, elisa_request: "GAL-2026-0001", version: 3)
    # Voltar o DPP com ELISA lançado é recusado: o ELISA ficaria sem DPP reagente.
    expect(refusal(correct(test, dpp_result: "non_reactive"))).to eq([ :elisa_without_reactive_dpp, { path: "elisa_result" } ])
    expect(DomainEvent.where(name: "leish_test.recorded").count).to eq(3)
  end

  it "gato → animal_not_dog; desaparecido → animal_not_active; inquérito closed ou draft → survey_not_open" do
    expect(refusal(collect(animal_id: animal!(household: household, species: "cat").id))).to eq([ :animal_not_dog, { path: "animal_id" } ])
    expect(refusal(collect(animal_id: animal!(household: household, status: "missing").id))).to eq([ :animal_not_active, {} ])
    expect(refusal(collect(animal_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "animal_id" } ])
    closed = leish_survey!(blocks: [ block ], stage: "closed")
    expect(refusal(collect(leish_survey_id: closed.id))).to eq([ :survey_not_open, { path: "leish_survey_id" } ])
    draft = leish_survey!(blocks: [ block ], stage: "draft")
    expect(refusal(collect(leish_survey_id: draft.id))).to eq([ :survey_not_open, { path: "leish_survey_id" } ])
    expect(refusal(collect(leish_survey_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "leish_survey_id" } ])
    expect(LeishTest.count).to eq(0)
  end

  it "ACS pelo app → cbo_not_allowed; agente fora do escopo → out_of_scope; ACE no escopo → ok" do
    acs = registry_acs_of(household)
    expect(refusal(collect(by: acs, origin: "field"))).to eq([ :cbo_not_allowed, {} ])
    outsider = ace_of(registry_household!)
    expect(refusal(collect(by: outsider, origin: "field"))).to eq([ :out_of_scope, {} ])
    expect(refusal(collect(by: ace_of(household), origin: "field", animal_id: animal!.id))).to eq([ :out_of_scope, {} ])

    ace = ace_of(household)
    result = collect(by: ace, origin: "field", dpp_result: "non_reactive", dpp_on: today.iso8601, client_uuid: SecureRandom.uuid)
    expect(result).to be_ok
    expect(result.payload[:test].result_by_user_id).to eq(ace.id)
    # Pelo app, só a coleta e o DPP (§11): sem ELISA.
    expect(refusal(collect(by: ace, origin: "field", elisa_request: "GAL-1"))).to eq([ :invalid_request, { path: "elisa_request" } ])
    # A equipe não lança pelo app; o ACE não lança pelo dashboard.
    expect(refusal(collect(by: ace))).to eq([ :missing_role, {} ])
  end

  it "domicílio fora do inquérito pelo app → household_not_in_survey path leish_survey_id" do
    other_block = city_block!(neighborhood: neighborhood, number: "2")
    elsewhere = leish_survey!(blocks: [ other_block ])
    ace = ace_of(household)
    expect(refusal(collect(by: ace, origin: "field", leish_survey_id: elsewhere.id)))
      .to eq([ :household_not_in_survey, { path: "leish_survey_id" } ])
    # Pelo dashboard, o domicílio não é conferido.
    expect(collect(leish_survey_id: elsewhere.id)).to be_ok
    expect(collect(by: ace, origin: "field")).to be_ok
  end

  it "dpp_result sem dpp_on → invalid_request path dpp_on; dpp_on sem resultado → path dpp_result" do
    expect(refusal(collect(dpp_result: "reactive"))).to eq([ :invalid_request, { path: "dpp_on" } ])
    expect(refusal(collect(dpp_on: today.iso8601))).to eq([ :invalid_request, { path: "dpp_result" } ])
    expect(refusal(collect(elisa_result: "reactive", dpp_result: "reactive", dpp_on: today.iso8601)))
      .to eq([ :invalid_request, { path: "elisa_on" } ])
    expect(refusal(collect(dpp_result: "positivo", dpp_on: today.iso8601))).to eq([ :invalid_request, { path: "dpp_result" } ])
    expect(refusal(collect(elisa_request: "x" * 31, dpp_result: "reactive", dpp_on: today.iso8601)))
      .to eq([ :invalid_request, { path: "elisa_request" } ])
    expect(refusal(collect(collected_on: "23/11/2026"))).to eq([ :invalid_request, { path: "collected_on" } ])
    expect(refusal(collect(collected_on: :omit))).to eq([ :invalid_request, { path: "collected_on" } ])
    expect(refusal(collect(label: "LV-2026-AVUL-0001"))).to eq([ :invalid_request, { path: "label" } ])
  end

  it "datas fora de [início do inquérito ou hoje − 30, hoje] → date_out_of_range com o path (Q20)" do
    expect(refusal(collect(collected_on: (today - 6).iso8601))).to eq([ :date_out_of_range, { path: "collected_on" } ])
    expect(refusal(collect(collected_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "collected_on" } ])
    expect(collect(leish_survey_id: :omit, collected_on: (today - 30).iso8601)).to be_ok
    expect(refusal(collect(leish_survey_id: :omit, collected_on: (today - 31).iso8601))).to eq([ :date_out_of_range, { path: "collected_on" } ])
    expect(refusal(collect(collected_on: (today - 1).iso8601, dpp_result: "reactive", dpp_on: (today - 2).iso8601)))
      .to eq([ :date_out_of_range, { path: "dpp_on" } ])
    expect(refusal(collect(dpp_result: "reactive", dpp_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "dpp_on" } ])
  end

  it "correção com versão velha → test_changed; sem versão → expected_version_required; campo da coleta não se corrige" do
    test = collect.payload[:test]
    expect(correct(test, dpp_result: "reactive", dpp_on: today.iso8601)).to be_ok
    expect(test.reload.version).to eq(2)
    stale = described_class.call(params: { "expected_version" => 1, "dpp_result" => "invalid" }, by: team, test: test)
    expect(refusal(stale)).to eq([ :test_changed, {} ])
    expect(refusal(described_class.call(params: { "dpp_result" => "invalid" }, by: team, test: test)))
      .to eq([ :expected_version_required, { path: "expected_version" } ])
    expect(refusal(correct(test, collected_on: today.iso8601))).to eq([ :invalid_request, { path: "collected_on" } ])
    expect(refusal(correct(test, animal_id: dog.id))).to eq([ :invalid_request, { path: "animal_id" } ])
    expect(refusal(correct(test))).to eq([ :invalid_request, { path: nil } ])
    expect(refusal(correct(test, by: registry_acs_of(household), dpp_result: "invalid"))).to eq([ :missing_role, {} ])
    expect(test.reload).to have_attributes(dpp_result: "reactive", version: 2)
  end

  it "sequência da etiqueta esgotada (999999, Q36) → invalid_request path label, nada gravado" do
    LeishTest.create!(animal: animal!, collected_on: today, label: "LV-#{today.year}-AVUL-999999")
    expect(refusal(collect(leish_survey_id: :omit))).to eq([ :invalid_request, { path: "label" } ])
    expect(LeishTest.count).to eq(1)
    expect(DomainEvent.where(name: "leish_test.recorded")).to be_empty
  end

  it "teste com desfecho não muda de resultado (409 invalid_transition path status); o número do GAL muda" do
    test = collect(dpp_result: "reactive", dpp_on: today.iso8601).payload[:test]
    test = correct(test, elisa_result: "reactive", elisa_on: today.iso8601).payload[:test]
    LeishDogOutcome.create!(animal: dog, leish_test: test, decision: "euthanasia", decided_on: today, euthanasia: euthanasia!(animal: dog))
    expect(refusal(correct(test, elisa_result: "non_reactive"))).to eq([ :invalid_transition, { path: "status" } ])
    expect(correct(test, elisa_request: "GAL-77")).to be_ok
  end
end
