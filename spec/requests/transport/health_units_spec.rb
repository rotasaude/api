require "rails_helper"

# Módulo 30, T46 (contrato §14): unidades de saúde ativas para a central.
# `{ units: [ { id, name } ] }`, sem outros campos, sem trilha, sem evento.
RSpec.describe "Transporte — unidades de saúde da central", type: :request do
  let!(:city) { transport_city! }

  describe "GET /transport/health_units" do
    it "central recebe só as unidades ativas, ordenadas pelo nome, com exatamente id e name" do
      sign_in_as(dispatcher!)
      zeta = create_unit("UBS Zeta", cnes: "1234567")
      alfa = create_unit("UBS Alfa")
      create_unit("UBS Inativa", active: false)

      expect { get "/transport/health_units" }.not_to change { DomainEvent.count }

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq("units" => [ { "id" => alfa.id, "name" => "UBS Alfa" }, { "id" => zeta.id, "name" => "UBS Zeta" } ])
    end

    it "outros papéis → 403 missing_role" do
      create_unit("UBS Alfa")
      [ driver_user!, committee! ].each do |user|
        sign_in_as(user)
        get "/transport/health_units"
        expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
      end
    end

    it "transporte desligado → 403 feature_disabled" do
      sign_in_as(dispatcher!)
      Platform::Features.set!(city: city, key: "sanitary_transport", enabled: false, maintainer: ledi_maintainer!)
      get "/transport/health_units"
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "sanitary_transport")
      expect(response).to have_http_status(:forbidden)
    end

    it "sem sessão → 401" do
      get "/transport/health_units"
      expect(response).to have_http_status(:unauthorized)
    end

    it "chave de query desconhecida → 422 invalid_request com o nome da chave" do
      sign_in_as(dispatcher!)
      get "/transport/health_units", params: { cpf: "x" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to include("error" => "invalid_request", "path" => "cpf")
    end
  end
end
