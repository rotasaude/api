require "rails_helper"

# Módulo 35b, Task 13 (ADR 0054; contrato §6, Q18): o desfecho do cão
# reagente (DPP e ELISA reagentes; senão invalid_request path leish_test_id).
# euthanasia exige a eutanásia já registrada do animal (euthanasia_id, Q18);
# tutor_treatment e refused exigem tutor (path decision). Um desfecho por
# teste (409 invalid_transition path status). Evento só com o id.
RSpec.describe Zoonoses::RecordLeishOutcome, type: :model do
  let!(:city) { zoonoses_city! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:tutor) { tutor! }
  let(:dog) { animal!(tutor: tutor) }
  let(:seq) { [ 0 ] }

  def test!(animal: dog, dpp: "reactive", elisa: "reactive")
    seq[0] += 1
    LeishTest.create!(animal: animal, collected_on: today - 3, label: "LV-#{today.year}-AVUL-#{format('%04d', seq[0])}", dpp_result: dpp,
                      dpp_on: (today - 3 if dpp), elisa_result: elisa, elisa_on: (today - 1 if elisa))
  end

  def decide(test, by: team, **over)
    params = { "leish_test_id" => test.id, "decision" => "tutor_treatment", "decided_on" => today.iso8601 }
               .merge(over.transform_keys(&:to_s)).reject { |_, value| value == :omit }
    described_class.call(params: params, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "tratamento pelo tutor do reagente → ok, nota cifrada, evento só com o id; segundo desfecho → invalid_transition" do
    test = test!
    result = decide(test, note: "Tutor assinou o termo de tratamento.", animal_id: dog.id)
    expect(result).to be_ok
    outcome = result.payload.fetch(:outcome)
    expect(outcome).to have_attributes(animal_id: dog.id, leish_test_id: test.id, decision: "tutor_treatment", decided_on: today,
                                       euthanasia_id: nil, note: "Tutor assinou o termo de tratamento.")
    raw = LeishDogOutcome.connection.select_value("SELECT note FROM leish_dog_outcomes WHERE id = #{LeishDogOutcome.connection.quote(outcome.id)}")
    expect(raw).not_to include("termo")
    expect(DomainEvent.where(name: "leish_dog_outcome.recorded").sole.payload).to eq("leish_dog_outcome_id" => outcome.id)

    expect(refusal(decide(test, decision: "refused"))).to eq([ :invalid_transition, { path: "status" } ])
  end

  it "teste não reagente nos dois → invalid_request path leish_test_id" do
    expect(refusal(decide(test!(elisa: nil)))).to eq([ :invalid_request, { path: "leish_test_id" } ])
    expect(refusal(decide(test!(elisa: "non_reactive")))).to eq([ :invalid_request, { path: "leish_test_id" } ])
    expect(refusal(decide(test!(dpp: "non_reactive", elisa: nil)))).to eq([ :invalid_request, { path: "leish_test_id" } ])
    expect(refusal(described_class.call(params: { "leish_test_id" => SecureRandom.uuid, "decision" => "refused", "decided_on" => today.iso8601 },
                                        by: team))).to eq([ :invalid_request, { path: "leish_test_id" } ])
    expect(refusal(decide(test!, animal_id: animal!.id))).to eq([ :invalid_request, { path: "animal_id" } ])
  end

  it "euthanasia sem eutanásia → path euthanasia_id; com a eutanásia do animal → ok; de outro animal → path euthanasia_id" do
    test = test!
    expect(refusal(decide(test, decision: "euthanasia"))).to eq([ :invalid_request, { path: "euthanasia_id" } ])
    other = euthanasia!(animal: animal!)
    expect(refusal(decide(test, decision: "euthanasia", euthanasia_id: other.id))).to eq([ :invalid_request, { path: "euthanasia_id" } ])
    expect(refusal(decide(test, decision: "euthanasia", euthanasia_id: SecureRandom.uuid))).to eq([ :invalid_request, { path: "euthanasia_id" } ])

    euthanasia = euthanasia!(animal: dog, reason: "leishmaniasis")
    expect(refusal(decide(test, decision: "refused", euthanasia_id: euthanasia.id))).to eq([ :invalid_request, { path: "euthanasia_id" } ])
    result = decide(test, decision: "euthanasia", euthanasia_id: euthanasia.id)
    expect(result).to be_ok
    expect(result.payload[:outcome]).to have_attributes(decision: "euthanasia", euthanasia_id: euthanasia.id)
    # A mesma eutanásia não serve a dois desfechos (um reteste do mesmo cão).
    expect(refusal(decide(test!, decision: "euthanasia", euthanasia_id: euthanasia.id))).to eq([ :invalid_request, { path: "euthanasia_id" } ])
  end

  it "refused sem tutor → path decision; tutor_treatment sem tutor → path decision; comunitário com eutanásia → ok" do
    community = animal!(community: true)
    test = test!(animal: community)
    expect(refusal(decide(test, decision: "refused"))).to eq([ :invalid_request, { path: "decision" } ])
    expect(refusal(decide(test, decision: "tutor_treatment"))).to eq([ :invalid_request, { path: "decision" } ])
    expect(decide(test, decision: "euthanasia", euthanasia_id: euthanasia!(animal: community).id)).to be_ok
  end

  it "recusas de campo: decisão, data, nota curta ou longa, chave estranha, papel" do
    test = test!
    expect(refusal(decide(test, decision: "abandon"))).to eq([ :invalid_request, { path: "decision" } ])
    expect(refusal(decide(test, decided_on: :omit))).to eq([ :invalid_request, { path: "decided_on" } ])
    expect(refusal(decide(test, decided_on: (today + 1).iso8601))).to eq([ :date_out_of_range, { path: "decided_on" } ])
    expect(refusal(decide(test, decided_on: (today - 4).iso8601))).to eq([ :date_out_of_range, { path: "decided_on" } ])
    expect(refusal(decide(test, note: "curta"))).to eq([ :invalid_request, { path: "note" } ])
    expect(refusal(decide(test, note: "x" * 501))).to eq([ :invalid_request, { path: "note" } ])
    expect(refusal(decide(test, tutor_name: "x"))).to eq([ :invalid_request, { path: "tutor_name" } ])
    expect(refusal(decide(test, by: registry_acs_of(registry_household!)))).to eq([ :missing_role, {} ])
    expect(LeishDogOutcome.count).to eq(0)
  end

  it "os domínios da leishmaniose em config/zoonoses/domains.yml seguem os códigos e a ordem do Catalog" do
    domains = YAML.load_file(Rails.root.join("config/zoonoses/domains.yml"))
    { "dpp_results" => Zoonoses::Catalog::DPP_RESULTS, "elisa_results" => Zoonoses::Catalog::ELISA_RESULTS,
      "leish_decisions" => Zoonoses::Catalog::LEISH_DECISIONS, "leish_survey_kinds" => Zoonoses::Catalog::SURVEY_KINDS }.each do |key, codes|
      expect(domains.fetch(key).pluck("code")).to eq(codes)
      expect(domains.fetch(key).pluck("label")).to all(be_a(String).and(be_present))
    end
  end
end
