require "rails_helper"

# Módulo 35a, Task 12 (ADR 0054; contrato §7, §9, §17; Q9, Q23, Q24(2)): o
# resultado da amostra de larvas pela coordenação ou pelo vector_lab.
# examinadas ≤ coletadas e aegypti + albopictus ≤ examinadas (senão
# sample_result_invalid com path); a correção exige nota nova de 10–500
# (comparada em texto claro: a cifra muda a cada gravação) e muda o
# resultado; amostra de visita retirada → not_found. O resultado volta ao
# índice do LIRAa (positivos e provisional).
RSpec.describe VectorControl::RecordSampleResult, type: :model do
  let!(:city) { vector_city! }
  let(:lab) { vector_lab! }
  let(:area) { registry_micro_area!(code: "05") }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let(:homes) { liraa_households!(block, 2, micro_area: area) }
  let(:day) { home_visit_day! }

  def inspect!(household, **over)
    visit = home_visit!(day: day, household: household, micro_area: area)
    VectorInspection.create!({ home_visit: visit, household_id: household.id, activity: "li", work_type: "routine",
                               situation: "worked", educational_action: false, city_block: block }.merge(over))
  end

  def sample!(inspection, larvae: 8, group: "A2", number: inspection.samples.count + 1)
    VectorSample.create!(vector_inspection_id: inspection.id, number: number, deposit_group: group, larvae_collected: larvae,
                         label: "#{SecureRandom.hex(4).upcase}-#{format('%02d', number)}")
  end

  def result(examined, aegypti, albopictus, note: nil, version: nil) =
    { "examined_larvae" => examined, "aegypti_larvae" => aegypti, "albopictus_larvae" => albopictus }
      .merge(note.nil? ? {} : { "result_note" => note }).merge(version.nil? ? {} : { "expected_version" => version })

  def record(sample, params, by: lab) = described_class.call(sample: sample, params: params, by: by)
  def refusal(outcome) = [ outcome.reason, outcome.details ]
  def events = DomainEvent.where(name: "vector_sample.result_recorded").order(:created_at, :id)

  let(:sample) { sample!(inspect!(homes.first)) }

  it "examinadas 9 de 8 coletadas → sample_result_invalid path examined_larvae" do
    expect(refusal(record(sample, result(9, 0, 0)))).to eq([ :sample_result_invalid, { path: "examined_larvae" } ])
    expect(sample.reload.result_at).to be_nil
    expect(events).to be_empty
  end

  it "aegypti 5 + albopictus 4 de 8 → sample_result_invalid path aegypti_larvae" do
    expect(refusal(record(sample, result(8, 5, 4)))).to eq([ :sample_result_invalid, { path: "aegypti_larvae" } ])
    expect(sample.reload.result_at).to be_nil
  end

  it "forma: campo ausente, não inteiro ou negativo → invalid_request com o path do campo; nota não texto → result_note" do
    expect(refusal(record(sample, result(8, 5, 0).except("examined_larvae")))).to eq([ :invalid_request, { path: "examined_larvae" } ])
    expect(refusal(record(sample, result(8, "5", 0)))).to eq([ :invalid_request, { path: "aegypti_larvae" } ])
    expect(refusal(record(sample, result(8, 5, -1)))).to eq([ :invalid_request, { path: "albopictus_larvae" } ])
    expect(refusal(record(sample, result(8, 5, 0, note: 12)))).to eq([ :invalid_request, { path: "result_note" } ])
  end

  it "primeiro resultado grava os números, quem e quando; o evento leva corrected: false; nota no primeiro → result_note" do
    expect(refusal(record(sample, result(8, 5, 0, note: "Nota no primeiro resultado")))).to eq([ :invalid_request, { path: "result_note" } ])
    outcome = record(sample, result(8, 5, 0))
    expect(outcome).to be_ok
    expect(outcome.payload[:sample]).to eq(sample)
    expect(sample.reload).to have_attributes(examined_larvae: 8, aegypti_larvae: 5, albopictus_larvae: 0, result_by_user_id: lab.id,
                                             result_note: nil, version: 2)
    expect(sample.result_at).to be_present
    expect(events.sole.payload).to eq("vector_sample_id" => sample.id, "user_id" => lab.id, "corrected" => false)
  end

  it "correção sem nota → invalid_request path result_note; nota curta ou longa também; com nota → corrected: true" do
    coordinator = endemic_coordinator!
    expect(record(sample, result(8, 5, 0))).to be_ok

    expect(refusal(record(sample, result(8, 4, 1, version: 2)))).to eq([ :invalid_request, { path: "result_note" } ])
    expect(refusal(record(sample, result(8, 4, 1, note: "curta", version: 2)))).to eq([ :invalid_request, { path: "result_note" } ])
    expect(refusal(record(sample, result(8, 4, 1, note: "x" * 501, version: 2)))).to eq([ :invalid_request, { path: "result_note" } ])
    expect(record(sample, result(8, 4, 1, note: "  Revisão na lupa: uma larva era albopictus  ", version: 2), by: coordinator)).to be_ok
    expect(sample.reload).to have_attributes(aegypti_larvae: 4, albopictus_larvae: 1, result_by_user_id: coordinator.id,
                                             result_note: "Revisão na lupa: uma larva era albopictus", version: 3)
    expect(events.last.payload).to eq("vector_sample_id" => sample.id, "user_id" => coordinator.id, "corrected" => true)
    expect(events.last.payload.to_s).not_to include("lupa")
  end

  it "correção que só troca a nota → path examined_larvae; nota repetida (texto claro) → path result_note" do
    record(sample, result(8, 5, 0))
    record(sample, result(8, 4, 1, note: "Revisão na lupa: uma larva era albopictus", version: 2))

    only_note = record(sample, result(8, 4, 1, note: "Só a nota mudaria nesta correção", version: 3))
    expect(refusal(only_note)).to eq([ :invalid_request, { path: "examined_larvae" } ])
    same_note = record(sample, result(7, 4, 1, note: "Revisão na lupa: uma larva era albopictus", version: 3))
    expect(refusal(same_note)).to eq([ :invalid_request, { path: "result_note" } ])
    expect(sample.reload).to have_attributes(examined_larvae: 8, aegypti_larvae: 4, version: 3)
    expect(events.count).to eq(2)
  end

  # Q36 (docs e7720b6): a correção leva a versão lida; o primeiro resultado não.
  it "duas correções com a mesma expected_version: a segunda → sample_changed, nada gravado e nenhum evento" do
    expect(record(sample, result(8, 5, 0))).to be_ok
    read = sample.reload.version
    expect(record(sample, result(8, 4, 1, note: "Revisão na lupa: uma larva era albopictus", version: read))).to be_ok

    stale = record(sample, result(8, 3, 2, note: "Outra revisão feita na bancada", version: read), by: endemic_coordinator!)
    expect(refusal(stale)).to eq([ :sample_changed, {} ])
    expect(sample.reload).to have_attributes(examined_larvae: 8, aegypti_larvae: 4, albopictus_larvae: 1, result_by_user_id: lab.id,
                                             result_note: "Revisão na lupa: uma larva era albopictus", version: read + 1)
    expect(events.count).to eq(2)
  end

  it "correção sem expected_version → expected_version_required; fora de inteiro >= 0 → invalid_request; nada gravado" do
    expect(record(sample, result(8, 5, 0))).to be_ok
    note = "Revisão na lupa: uma larva era albopictus"
    expect(refusal(record(sample, result(8, 4, 1, note: note)))).to eq([ :expected_version_required, { path: "expected_version" } ])
    expect(refusal(record(sample, result(8, 4, 1, note: note, version: "2")))).to eq([ :invalid_request, { path: "expected_version" } ])
    expect(refusal(record(sample, result(8, 4, 1, note: note, version: -1)))).to eq([ :invalid_request, { path: "expected_version" } ])
    expect(sample.reload).to have_attributes(aegypti_larvae: 5, result_note: nil, version: 2)
    expect(events.count).to eq(1)
  end

  it "primeiro resultado sem versão passa; com expected_version → invalid_request path expected_version (como a nota)" do
    expect(refusal(record(sample, result(8, 5, 0, version: 1)))).to eq([ :invalid_request, { path: "expected_version" } ])
    expect(sample.reload).to have_attributes(result_at: nil, version: 1)
    expect(record(sample, result(8, 5, 0))).to be_ok
    expect(sample.reload.version).to eq(2)
  end

  it "ACE ou outro papel → missing_role; amostra de visita retirada → not_found" do
    expect(record(sample, result(8, 5, 0), by: endemic_agent!).reason).to eq(:missing_role)
    expect(record(sample, result(8, 5, 0), by: nil).reason).to eq(:missing_role)

    sample.vector_inspection.home_visit.update!(withdrawn_at: Time.current, withdrawn_by_user: day.user,
                                                withdrawal_reason: "registrada no imóvel errado")
    expect(record(sample, result(8, 5, 0)).reason).to eq(:not_found)
    expect(sample.reload.result_at).to be_nil
  end

  it "o resultado com aegypti > 0 muda o IIP do levantamento e tira o provisional" do
    survey = LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: Time.zone.today, ends_on: Time.zone.today + 6)
    stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "standard")
    items = homes.each_with_index.map do |home, i|
      LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: home, position: i + 1)
    end
    survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 0)
    positive = sample!(inspect!(homes.first, activity: "liraa", liraa_draw_item_id: items.first.id))
    inspect!(homes.last, activity: "liraa", liraa_draw_item_id: items.last.id)

    expect(VectorControl::Liraa::Index.for(survey)[:strata].first).to include(inspected: 2, positive_households: 0, provisional: true)
    expect(record(positive, result(8, 3, 0))).to be_ok
    row = VectorControl::Liraa::Index.for(survey)[:strata].first
    expect(row).to include(inspected: 2, positive_households: 1, iip: "50.0", provisional: false)
  end
end
