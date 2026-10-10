# spec/requests/clinical_documents/nursing_protocols_spec.rb
require "rails_helper"

# COFEN 801/2026; contrato §6: protocolo municipal (título, número, ano) →
# versões (vigência, itens com dose máxima opcional). Editar = versão nova;
# a vigente é a de maior número que cobre hoje.
RSpec.describe "Protocolos de enfermagem", type: :request do
  before { clinical_city!; import_test_catalog! }

  let(:admin) { municipal_admin! }

  def protocol_body(**over)
    { title: "Saúde da mulher na APS", number: "PE-01", year: 2026, valid_from: "2026-01-01",
      items: [ { catalog_item_id: catalog_item(267_503).id, max_dose: { quantity: 30, unit: "comprimido" } },
               { catalog_item_id: catalog_item(268_162).id } ] }.merge(over)
  end

  it "cria com itens e dose máxima; número + ano repetido → 409; nova versão vira a vigente" do
    stepped_up!(admin)
    json_post "/clinical_documents/nursing_protocols", protocol_body
    expect(response).to have_http_status(:created)
    protocol = json_body
    expect(protocol).to include("title" => "Saúde da mulher na APS", "number" => "PE-01", "year" => 2026)
    expect(protocol["current_version"]).to include("version" => 1, "valid_from" => "2026-01-01", "valid_until" => nil)
    expect(protocol["current_version"]["items"].first)
      .to eq("catalog_item" => ClinicalDocuments::Json.catalog_item(catalog_item(267_503)).as_json,
             "max_dose" => { "quantity" => 30, "unit" => "comprimido" })
    expect(protocol["current_version"]["items"].second["max_dose"]).to be_nil
    expect(protocol["current_version"]["items"].map { |row| row["catalog_item"].slice("antimicrobial", "controlled") })
      .to all(eq("antimicrobial" => false, "controlled" => false))
    expect(protocol["current_version"]["items"].first["catalog_item"]).not_to have_key("in_network")

    json_post "/clinical_documents/nursing_protocols", protocol_body
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_exists" } ])

    json_post "/clinical_documents/nursing_protocols/#{protocol['id']}/versions",
              valid_from: "2026-02-01", items: [ { catalog_item_id: catalog_item(267_778).id } ]
    expect(json_body["current_version"]).to include("version" => 2)
    json_post "/clinical_documents/nursing_protocols/#{protocol['id']}/versions",
              valid_from: (Time.zone.today + 30).iso8601, items: [ { catalog_item_id: catalog_item(267_203).id } ]
    expect(json_body["current_version"]["version"]).to eq(2) # a 3 ainda não vale
    get "/clinical_documents/nursing_protocols"
    expect(json_body["items"].map { |row| row.dig("current_version", "version") }).to eq([ 2 ])
  end

  it "expõe antimicrobial e controlled nos itens da versão vigente" do
    stepped_up!(admin)
    json_post "/clinical_documents/nursing_protocols",
              protocol_body(items: [ { catalog_item_id: catalog_item(271_089).id } ])
    expect(response).to have_http_status(:created)
    expect(json_body["current_version"]["items"].first["catalog_item"])
      .to eq(ClinicalDocuments::Json.catalog_item(catalog_item(271_089)).as_json)
    expect(json_body["current_version"]["items"].first["catalog_item"])
      .to include("antimicrobial" => true, "controlled" => false)
  end

  it "valida cabeçalho, vigência e itens; controlado e escondido recusados" do
    stepped_up!(admin)
    json_post "/clinical_documents/nursing_protocols", protocol_body(title: "x")
    expect(json_body).to eq("error" => "invalid_content", "field" => "title")
    json_post "/clinical_documents/nursing_protocols", protocol_body(valid_until: "2025-12-31")
    expect(json_body).to eq("error" => "invalid_content", "field" => "valid_until")
    json_post "/clinical_documents/nursing_protocols", protocol_body(items: [])
    expect(json_body).to eq("error" => "invalid_content", "field" => "items")
    json_post "/clinical_documents/nursing_protocols", protocol_body(items: [ { catalog_item_id: catalog_item(267_197).id } ])
    expect(json_body).to eq("error" => "controlled_not_allowed", "index" => 0)
    json_post "/clinical_documents/nursing_protocols", protocol_body(items: [ { catalog_item_id: catalog_item(384_258).id } ])
    expect(json_body).to eq("error" => "invalid_item", "index" => 0, "field" => "catalog_item_id")
    json_post "/clinical_documents/nursing_protocols",
              protocol_body(items: [ { catalog_item_id: catalog_item(267_503).id, max_dose: { quantity: 0, unit: "cp" } } ])
    expect(json_body).to eq("error" => "invalid_item", "index" => 0, "field" => "max_dose")
    # Revisão final M4: mais de 2 casas é recusado, nunca arredondado pela coluna.
    expect {
      json_post "/clinical_documents/nursing_protocols",
                protocol_body(items: [ { catalog_item_id: catalog_item(267_503).id, max_dose: { quantity: 0.125, unit: "mL" } } ])
    }.not_to change(NursingProtocolVersionItem, :count)
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_item", "index" => 0, "field" => "max_dose" } ])
  end

  it "enfermeira lê; recepção não; escrita exige admin com step-up" do
    unit = create_unit
    sign_in_as(nurse!(unit))
    get "/clinical_documents/nursing_protocols"
    expect(response).to have_http_status(:ok)
    json_post "/clinical_documents/nursing_protocols", protocol_body
    expect(json_body).to eq("error" => "missing_role")
    sign_in_as(verifier!)
    get "/clinical_documents/nursing_protocols"
    expect(json_body).to eq("error" => "missing_role")
  end
end
