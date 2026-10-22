require "rails_helper"

# Contrato §6: admin municipal e analista; agregado, sem nome; sem trilha.
RSpec.describe "Linhas de cuidado — prévia", type: :request do
  before do
    care_city!
    care_lines_loaded!
  end

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }

  it "analista lê, sem nome e sem trilha; profissional não; indicador e equipe validados" do
    care_patient!(age: 70, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
    sign_in_as(staff_with("analise-#{SecureRandom.hex(3)}@cidade.gov.br", "analyst"))
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C6" }
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("indicator" => "C6", "denominator" => 1, "estimate" => true)
    expect(response.body).not_to match(/display_name|patient_id|citizen_id/)
    expect(DomainEvent.where(name: "clinical_record.viewed").select { |e| e.payload["access"] == "care_line" }).to be_empty
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C1" }
    expect(json_body).to eq("error" => "invalid_indicator")
    get "/care_lines/preview", params: { team_id: SecureRandom.uuid, indicator: "C6" }
    expect(response).to have_http_status(:not_found)
    sign_in_as(doctor)
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C6" }
    expect(response).to have_http_status(:forbidden)
  end

  it "administrador municipal lê; team_id malformado dá 404" do
    sign_in_as(care_admin!)
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C2" }
    expect(response).to have_http_status(:ok)
    get "/care_lines/preview", params: { team_id: "nao-e-uuid", indicator: "C2" }
    expect(response).to have_http_status(:not_found)
  end

  it "sem o catálogo-base carregado: 503 catalog_not_loaded" do
    allow(CareLineTemplate).to receive(:current).with("elderly_c6").and_return(nil)
    sign_in_as(care_admin!)
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C6" }
    expect(response).to have_http_status(:service_unavailable)
    expect(json_body).to eq("error" => "catalog_not_loaded")
  end

  it "interruptor desligado: 403 feature_disabled" do
    Platform::Features.set!(city: Current.city, key: "care_lines", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(care_admin!)
    get "/care_lines/preview", params: { team_id: team.id, indicator: "C6" }
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to include("error" => "feature_disabled")
  end
end
