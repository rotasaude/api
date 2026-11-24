require "rails_helper"

# Módulo 35b, Task 15 (ADR 0054; contrato §8, §10, Q25): GET
# /zoonoses/reports/:name em JSON e `.csv` (BOM, `;`, `\r\n`); `.pdf` e nome
# desconhecido → 404; reader? lê, os outros → 403; query só com as chaves do
# relatório; nenhum dado pessoal no corpo.
RSpec.describe "Zoonoses — relatórios", type: :request do
  let!(:city) do
    zoonoses_city!
    ombudsman_city!(anonymous: true)
  end
  let!(:uvz) { uvz_unit! }
  let(:team) { zoonoses_team! }
  let(:today) { Time.zone.today }
  let(:range) { { from: (today - 30).iso8601, to: today.iso8601 } }
  let(:tutor) { tutor! }

  def seed!
    household_animal = animal!(tutor: tutor, microchip: "123456789012345", name: "Rex Marcado", registry_number: "REG-9")
    campaign = RabiesCampaign.create!(name: "Campanha", year: today.year, starts_on: today - 3, ends_on: today + 20, goal_dogs: 8,
                                      goal_cats: 2, stage: "open")
    rabies_vaccination!(animal: household_animal, campaign: campaign, modality: "fixed_post", vaccinated_on: today)
    zoonoses_demand!
    bite_observation!
    shelter_stay!(animal: household_animal)
    block = city_block!(neighborhood: Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual"), number: "2")
    leish_survey!(blocks: [ block ])
  end

  it "os seis em JSON e CSV (BOM, `;`); `.pdf` → 404" do
    seed!
    sign_in_as(team)
    Zoonoses::Catalog::REPORTS.each do |name|
      get "/zoonoses/reports/#{name}", params: range
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json).to include("name" => name)
      expect(json.fetch("columns").first.keys).to eq(%w[key label kind])

      get "/zoonoses/reports/#{name}.csv", params: range
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.headers["Content-Disposition"]).to start_with("attachment").and include("#{name}-#{today.iso8601}.csv")
      expect(response.headers["Cache-Control"]).to include("no-store")
      body = response.body.dup.force_encoding("UTF-8")
      expect(body).to start_with("﻿")
      expect(body).to include("\r\n")
      expect(body.delete_prefix("﻿").split("\r\n").first.split(";").size).to eq(json.fetch("columns").size)

      get "/zoonoses/reports/#{name}.pdf", params: range
      expect([ response.status, json_body ]).to eq([ 404, { "error" => "not_found" } ])
    end
    get "/zoonoses/reports/nope", params: range
    expect(response).to have_http_status(:not_found)
  end

  it "municipal_admin lê; stock_keeper → 403" do
    seed!
    sign_in_as(staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))
    get "/zoonoses/reports/shelter", params: range
    expect(response).to have_http_status(:ok)

    sign_in_as(staff_with("estoque-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper"))
    get "/zoonoses/reports/shelter", params: range
    expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
  end

  it "recusas: chave fora dos filtros e período → 422 invalid_request" do
    sign_in_as(team)
    get "/zoonoses/reports/demands", params: range.merge(survey_id: SecureRandom.uuid)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request" } ])
    get "/zoonoses/reports/demands"
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "from" } ])
    get "/zoonoses/reports/demands", params: { from: today.iso8601, to: (today - 1).iso8601 }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "from" } ])
  end

  it "nenhum JSON nem CSV traz nome, CPF, telefone, endereço ou microchip" do
    seed!
    sign_in_as(team)
    cpf = Patient.find(tutor.id).cpf.to_s
    forbidden = [ ZoonosesHelpers::ZOONOSES_TUTOR_NAME, "Rex Marcado", "123456789012345", "REG-9", "Rua das Acácias", cpf, tutor.id,
                  "Escorpiões no terreno" ].reject(&:blank?)
    Zoonoses::Catalog::REPORTS.each do |name|
      [ "", ".csv" ].each do |extension|
        get "/zoonoses/reports/#{name}#{extension}", params: range
        expect(response).to have_http_status(:ok)
        forbidden.each { |value| expect(response.body).not_to include(value) }
      end
    end
  end
end
