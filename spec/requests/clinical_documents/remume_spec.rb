# spec/requests/clinical_documents/remume_spec.rb
require "rails_helper"

# Contrato §6: a REMUME é o recorte da cidade sobre o catálogo da plataforma,
# por id; unidades opcionais. municipal_admin com step-up.
RSpec.describe "REMUME", type: :request do
  before { clinical_city!; import_test_catalog! }

  let(:admin) { municipal_admin! }
  let(:unit) { create_unit }

  it "inclui, atualiza as unidades, lista e remove" do
    stepped_up!(admin)
    losartana = catalog_item(268_856)
    json_post "/clinical_documents/remume", catalog_item_id: losartana.id
    expect(response).to have_http_status(:created)
    expect(json_body).to eq("catalog_item" => { "id" => losartana.id, "catmat_code" => 268_856, "label" => "LOSARTANA POTÁSSICA 50 MG",
                                                "active_ingredient" => "LOSARTANA POTÁSSICA", "strength" => "50 MG",
                                                "dosage_form" => nil, "antimicrobial" => false, "controlled" => false,
                                                "controlled_list" => nil, "anticonvulsant" => false },
                            "unit_ids" => [])
    json_post "/clinical_documents/remume", catalog_item_id: losartana.id, unit_ids: [ unit.id ]
    expect([ response.status, json_body["unit_ids"] ]).to eq([ 200, [ unit.id ] ])
    get "/clinical_documents/remume"
    expect(json_body["items"].map { |row| row.dig("catalog_item", "catmat_code") }).to eq([ 268_856 ])
    json_delete "/clinical_documents/remume/#{losartana.id}"
    expect(response).to have_http_status(:no_content)
    expect(CityMedication.count).to eq(0)
    json_delete "/clinical_documents/remume/#{losartana.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "recusa item escondido, inexistente ou removido e unidade desconhecida" do
    stepped_up!(admin)
    json_post "/clinical_documents/remume", catalog_item_id: catalog_item(384_258).id
    expect(json_body).to eq("error" => "invalid_catalog_item")
    json_post "/clinical_documents/remume", catalog_item_id: "nao-e-uuid"
    expect(json_body).to eq("error" => "invalid_catalog_item")
    json_post "/clinical_documents/remume", catalog_item_id: catalog_item(268_856).id, unit_ids: [ SecureRandom.uuid ]
    expect(json_body).to eq("error" => "invalid_unit")
  end

  it "profissional lê; escrita exige admin e step-up" do
    sign_in_as(doctor!(unit))
    get "/clinical_documents/remume"
    expect(response).to have_http_status(:ok)
    json_post "/clinical_documents/remume", catalog_item_id: catalog_item(268_856).id
    expect(json_body).to eq("error" => "missing_role")
    sign_in_as(step_up_enrolled!(admin))
    json_post "/clinical_documents/remume", catalog_item_id: catalog_item(268_856).id
    expect(json_body).to eq("error" => "mfa_required")
  end
end
