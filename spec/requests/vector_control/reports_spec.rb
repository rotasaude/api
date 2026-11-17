require "rails_helper"

# Módulo 35a, Task 13 (ADR 0054; contrato §10, §12; Q8): GET
# /vector_control/reports/:name em JSON (VectorReport), `.csv` (BOM, `;`,
# `\r\n`) e `.pdf` só no liraa. Coordenação e municipal_admin leem todos; o
# vector_lab só ovitraps e liraa. 4xx só com error e path.
RSpec.describe "Vigilância ambiental — relatórios", type: :request do
  let!(:city) { vector_city! }
  let(:coordinator) { endemic_coordinator! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:cycle) { VectorCycle.create!(year: 2026, number: 10, starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 31)) }
  let(:today) { Time.zone.today }
  let(:base) { "/vector_control/reports" }

  def worked_inspection!
    household = registry_household_rows!(area, neighborhood_id: neighborhood.id)
    on = Date.new(2026, 10, 5)
    visit = home_visit!(day: home_visit_day!(agent: agent, day: on), micro_area: area, household: household,
                        occurred_at: on.in_time_zone.change(hour: 9))
    VectorInspection.create!(home_visit: visit, household: household, activity: "li", work_type: "routine", situation: "worked",
                             educational_action: false)
  end

  def survey!
    survey = LiraaSurvey.create!(name: "LIRAa outubro", starts_on: today, ends_on: today + 6)
    LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census")
    survey
  end

  it "CSV começa com BOM e separa por `;` com `\\r\\n`" do
    worked_inspection!
    sign_in_as(coordinator)
    get "#{base}/situations.csv", params: { cycle_id: cycle.id, neighborhood_ids: [ neighborhood.id ] }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.headers["Content-Disposition"]).to start_with("attachment").and include("situations-#{today.iso8601}.csv")
    expect(response.headers["Cache-Control"]).to include("no-store")
    body = response.body.dup.force_encoding("UTF-8")
    expect(body).to start_with("﻿")
    lines = body.delete_prefix("﻿").split("\r\n")
    expect(body).to end_with("\r\n")
    expect(lines.first.split(";")).to eq([ "Recorte", "Classe ou bairro", "Cadastrados", "A visitar", "Visitados", "Trabalhados",
                                          "Fechados", "Recusados", "Desocupados", "Recuperados", "Pendência %", "Cobertura %" ])
    expect(lines[1]).to eq("Classe de imóvel;R (residencial);1;1;1;1;0;0;0;0;0,0;100,0")
    expect(lines.last).to eq("Bairro;#{neighborhood.name};1;1;1;1;0;0;0;0;0,0;100,0")
  end

  it "liraa.pdf é `application/pdf` e começa com `%PDF`; situations.pdf → 404" do
    survey = survey!
    sign_in_as(coordinator)
    get "#{base}/liraa.pdf", params: { survey_id: survey.id }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body).to start_with("%PDF")
    expect(response.headers["Content-Disposition"]).to start_with("attachment").and include("liraa-#{today.iso8601}.pdf")

    get "#{base}/liraa.csv", params: { survey_id: survey.id }
    expect(response).to have_http_status(:ok)

    get "#{base}/situations.pdf", params: { cycle_id: cycle.id }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "#{base}/liraa.xml", params: { survey_id: survey.id }
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    get "#{base}/heatmap"
    expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
  end

  it "vector_lab em production → 403; municipal_admin lê; o laboratório lê ovitrampas e LIRAa" do
    period = { from: "2026-10-01", to: "2026-10-31" }
    sign_in_as(vector_lab!)
    get "#{base}/production", params: period
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "#{base}/production.csv", params: period
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    get "#{base}/ovitraps", params: { epi_weeks: [ "2026-41" ], neighborhood_ids: [ neighborhood.id ] }
    expect(response).to have_http_status(:ok)
    get "#{base}/liraa", params: { survey_id: survey!.id }
    expect(response).to have_http_status(:ok)

    sign_in_as(staff_with("admin-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    get "#{base}/production", params: period
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("name" => "production", "rows" => [])

    sign_in_as(agent)
    get "#{base}/blocks", params: period
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "JSON com `name`, `columns` com `kind`, `rows`; liraa com `provisional`" do
    worked_inspection!
    sign_in_as(coordinator)
    get "#{base}/situations", params: { cycle_id: cycle.id, neighborhood_ids: [ neighborhood.id ] }
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to eq(%w[name columns rows notes])
    expect(json_body["columns"].first).to eq("key" => "group", "label" => "Recorte", "kind" => "text")
    expect(json_body["columns"].map { |column| column["kind"] }.uniq).to contain_exactly("text", "count", "percent")
    expect(json_body["rows"].first).to include("label" => "R (residencial)", "visited" => 1, "coverage_percent" => "100.0")

    get "#{base}/liraa", params: { survey_id: survey!.id }
    expect(json_body).to include("name" => "liraa", "provisional" => false)
    expect(json_body["rows"].map { |row| row["stratum"] }).to eq([ "Estrato 1", "Município" ])

    get "#{base}/blocks", params: { from: today.iso8601, to: today.iso8601 }
    expect(json_body).to include("name" => "blocks")
    expect(json_body).not_to have_key("provisional")
  end

  it "filtro inválido → 422 invalid_request com path; chave fora do relatório → 422" do
    sign_in_as(coordinator)
    get "#{base}/ovitraps", params: { epi_weeks: [ "2026-45", "2026-5" ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "epi_weeks[1]" } ])
    get "#{base}/situations"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "cycle_id" } ])
    get "#{base}/blocks", params: { from: "2026-10-02", to: "2026-10-01" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "to" } ])
    get "#{base}/blocks", params: { from: today.iso8601, to: today.iso8601, name: "Joana" }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
  end

  it "vigilância ambiental desligada → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(coordinator)
    get "#{base}/blocks", params: { from: today.iso8601, to: today.iso8601 }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
  end
end
