require "rails_helper"

# Módulo 35a, Task 12 (ADR 0054; contrato §9, §12, §17; Q8, Q9): a fila de
# amostras de larvas da coordenação e do vector_lab (403 missing_role para os
# outros) e o resultado. GET /vector_control/samples?state=pending|done →
# `{ items, next_before }` de VectorSample, das visitas válidas: pending por
# (dia da visita, etiqueta), done por result_at decrescente (Q27);
# POST /vector_control/samples/:id/result → VectorSample.
# Nunca imóvel nem morador; a nota nunca sai. 4xx só com error e path.
RSpec.describe "Vigilância ambiental — amostras", type: :request do
  let!(:city) { vector_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "7") }
  let(:household) do
    home = registry_household!(micro_area: area)
    vector_profile!(home, block: block)
    home
  end
  let(:lab) { vector_lab! }
  let(:uuid) { "3f2a9c1e-#{SecureRandom.uuid[9..]}" }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def earlier_today = [ 2.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0)

  # Visita do ACE pelo POST /home_visits com duas amostras. -> HomeVisit
  def visit_with_samples!
    report = { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
               "deposits" => [ { "group" => "A2", "existing" => 2, "with_water" => 2, "with_larvae" => 1, "eliminated" => 1, "treated" => 0 },
                               { "group" => "B", "existing" => 1, "with_water" => 1, "with_larvae" => 1, "eliminated" => 1, "treated" => 0 } ],
               "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 8 },
                              { "number" => 2, "deposit_group" => "B", "larvae_collected" => 3 } ] }
    sign_in_as(agent)
    json_post "/home_visits", "client_uuid" => uuid, "team_id" => team.id, "occurred_at" => earlier_today.iso8601,
                              "household_id" => household.id, "subject" => "none", "outcome" => 1, "reasons" => [], "shared" => false,
                              "vector_inspection" => report
    expect(response).to have_http_status(:created)
    HomeVisit.find_by!(client_uuid: uuid)
  end

  # Amostra direto nas linhas, numa visita de `on` (sem quarteirão). -> VectorSample
  def older_sample!(on:, label:)
    visit = home_visit!(day: home_visit_day!(day: on), household: household, micro_area: area)
    inspection = VectorInspection.create!(home_visit: visit, household_id: household.id, activity: "li", work_type: "routine",
                                          situation: "worked", educational_action: false)
    VectorSample.create!(vector_inspection_id: inspection.id, number: 1, deposit_group: "C", larvae_collected: 4, label: label)
  end

  def item(sample, visit_on:, city_block: nil, result: nil)
    { "id" => sample.id, "label" => sample.label, "visit_on" => visit_on.iso8601, "deposit_group" => sample.deposit_group,
      "larvae_collected" => sample.larvae_collected, "city_block" => city_block, "result" => result }
  end

  it "a fila não traz imóvel nem morador; ACE → 403" do
    visit_with_samples!
    first, second = VectorSample.order(:number).to_a
    old = older_sample!(on: today - 3, label: "FFFFFFFF-01")
    withdrawn = older_sample!(on: today - 2, label: "00000000-01")
    gone = withdrawn.vector_inspection.home_visit
    gone.update!(withdrawn_at: Time.current, withdrawn_by_user: gone.recorded_by_user, withdrawal_reason: "registrada no imóvel errado")

    get "/vector_control/samples", params: { state: "pending" }
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    json_post "/vector_control/samples/#{first.id}/result", examined_larvae: 8, aegypti_larvae: 5, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

    sign_in_as(lab)
    get "/vector_control/samples"
    frozen = { "id" => block.id, "number" => "7" }
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("items" => [ item(old, visit_on: today - 3),
                                         item(first, visit_on: today, city_block: frozen),
                                         item(second, visit_on: today, city_block: frozen) ],
                            "next_before" => nil)
    expect(first.label).to eq("#{uuid[0, 8].upcase}-01")
    text = response.body
    expect(text).not_to include(household.id)
    expect(text).not_to include("Rua das Flores")
    expect(text).not_to include("household")

    json_post "/vector_control/samples/#{first.id}/result", examined_larvae: 8, aegypti_larvae: 5, albopictus_larvae: 0
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("id" => first.id, "label" => first.label, "city_block" => frozen)
    expect(json_body["result"]).to include("examined_larvae" => 8, "aegypti_larvae" => 5, "albopictus_larvae" => 0, "corrected" => false)

    get "/vector_control/samples", params: { state: "pending" }
    expect(json_body["items"].map { |row| row["id"] }).to eq([ old.id, second.id ])
    get "/vector_control/samples", params: { state: "done" }
    expect(json_body["items"].map { |row| row["id"] }).to eq([ first.id ])

    json_post "/vector_control/samples/#{withdrawn.id}/result", examined_larvae: 4, aegypti_larvae: 0, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    json_post "/vector_control/samples/#{SecureRandom.uuid}/result", examined_larvae: 4, aegypti_larvae: 0, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "o resultado aparece no GET da visita (`samples[].result`)" do
    visit = visit_with_samples!
    sample = VectorSample.find_by!(number: 1)

    sign_in_as(lab)
    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 8, aegypti_larvae: 5, albopictus_larvae: 0
    expect(response).to have_http_status(:ok)
    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 8, aegypti_larvae: 4, albopictus_larvae: 1
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "result_note" } ])
    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 8, aegypti_larvae: 4, albopictus_larvae: 1,
                                                             result_note: "Revisão na lupa: uma larva era albopictus"
    expect(response).to have_http_status(:ok)
    corrected = json_body["result"]
    expect(corrected).to include("aegypti_larvae" => 4, "albopictus_larvae" => 1, "corrected" => true)
    expect(response.body).not_to include("lupa")

    sign_in_as(agent)
    get "/home_visits/#{visit.id}"
    expect(response).to have_http_status(:ok)
    samples = json_body["vector_inspection"]["samples"]
    expect(samples.map { |row| [ row["number"], row["result"] ] }).to eq([ [ 1, corrected ], [ 2, nil ] ])
    expect(response.body).not_to include("lupa")
  end

  it "recusas saem só com error e path" do
    visit_with_samples!
    sample = VectorSample.find_by!(number: 2)
    sign_in_as(lab)

    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 4, aegypti_larvae: 0, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "sample_result_invalid", "path" => "examined_larvae" } ])
    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 3, aegypti_larvae: 2, albopictus_larvae: 2
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "sample_result_invalid", "path" => "aegypti_larvae" } ])
    json_post "/vector_control/samples/#{sample.id}/result", examined_larvae: 3, aegypti_larvae: 0, albopictus_larvae: 0, extra: 1
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "extra" } ])
    json_post "/vector_control/samples/#{sample.id}/result?examined_larvae=3", aegypti_larvae: 0, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])

    get "/vector_control/samples", params: { state: "open" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "state" } ])
    get "/vector_control/samples", params: { household_id: household.id }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/vector_control/samples", params: { before: "não-é-cursor" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    expect(sample.reload.result_at).to be_nil
  end

  def ids = json_body["items"].map { |row| row["id"] }

  def result!(sample, aegypti: 1, note: nil)
    body = { examined_larvae: 4, aegypti_larvae: aegypti, albopictus_larvae: 0 }
    json_post "/vector_control/samples/#{sample.id}/result", note ? body.merge(result_note: note) : body
    expect(response).to have_http_status(:ok)
  end

  it "pending: duas páginas por (dia da visita, etiqueta), sem pular nem repetir" do
    stub_const("VectorControl::SamplesController::LIMIT", 2)
    later = older_sample!(on: today - 1, label: "AAAAAAAA-01")
    second = older_sample!(on: today - 4, label: "CCCCCCCC-01")
    first = older_sample!(on: today - 4, label: "BBBBBBBB-01")
    sign_in_as(endemic_coordinator!)

    get "/vector_control/samples"
    expect(ids).to eq([ first.id, second.id ])
    expect(json_body["next_before"]).to be_present
    get "/vector_control/samples", params: { before: json_body["next_before"] }
    expect(ids).to eq([ later.id ])
    expect(json_body["next_before"]).to be_nil
  end

  it "done (Q27): result_at decrescente, a correção sobe ao topo; duas páginas; cursor da outra aba → invalid_cursor" do
    stub_const("VectorControl::SamplesController::LIMIT", 2)
    one, two, three = %w[AAAAAAAA-01 BBBBBBBB-01 CCCCCCCC-01].each_with_index.map do |label, i|
      older_sample!(on: today - 5 + i, label: label)
    end
    %w[DDDDDDDD-01 EEEEEEEE-01 FFFFFFFF-01].each { |label| older_sample!(on: today - 1, label: label) }
    sign_in_as(lab)
    [ one, two, three ].each { |sample| result!(sample) }

    get "/vector_control/samples", params: { state: "done" }
    expect(ids).to eq([ three.id, two.id ])
    result!(one, aegypti: 2, note: "Revisão na lupa: duas larvas eram aegypti")
    get "/vector_control/samples", params: { state: "done" }
    expect(ids).to eq([ one.id, three.id ])
    expect(json_body["items"].first["result"]).to include("aegypti_larvae" => 2, "corrected" => true)
    done_cursor = json_body["next_before"]
    get "/vector_control/samples", params: { state: "done", before: done_cursor }
    expect(ids).to eq([ two.id ])
    expect(json_body["next_before"]).to be_nil

    get "/vector_control/samples", params: { state: "pending" }
    expect(ids.size).to eq(2)
    pending_cursor = json_body["next_before"]
    get "/vector_control/samples", params: { state: "done", before: pending_cursor }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
    get "/vector_control/samples", params: { state: "pending", before: done_cursor }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cursor" } ])
  end

  it "papel antes da query: ACE com query no POST → 403 missing_role" do
    sample = older_sample!(on: today - 1, label: "AAAAAAAA-01")
    sign_in_as(agent)
    json_post "/vector_control/samples/#{sample.id}/result?examined_larvae=3", aegypti_larvae: 0, albopictus_larvae: 0
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end
end
