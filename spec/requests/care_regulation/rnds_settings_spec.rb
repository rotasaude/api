require "rails_helper"

# Módulo 26c (contrato §5, Q13, Q19): configurações do envio da regulação à RNDS.
# Valem antes de ligar o interruptor (sem o gate do RNDS); o PUT pede step-up.
RSpec.describe "Regulação — configurações do envio à RNDS", type: :request do
  let!(:city) { regulation_city! }
  let(:admin) { regulation_admin! }
  let(:regulator) { care_regulator! }
  let(:defaults) do
    { "priority_by_color" => { "red" => "urgent", "yellow" => "routine", "green" => "routine", "blue" => "routine" },
      "specialty_sigtap" => {}, "default_sigtap" => "0301010072", "send_external" => false, "version" => 1 }
  end

  def put_body(**over)
    { expected_version: 1, priority_by_color: defaults["priority_by_color"], specialty_sigtap: {}, send_external: false }.merge(over)
  end

  def settings_events = DomainEvent.where(name: "regulation_rnds.settings_changed").map(&:payload)

  describe "GET" do
    it "o regulador lê as configurações padrão" do
      sign_in_as(regulator)
      get "/regulation/admin/rnds_settings"
      expect([ response.status, json_body ]).to eq([ 200, defaults ])
    end

    it "com rnds_regulation desligado (o padrão) devolve 200 com os padrões; o admin também lê" do
      sign_in_as(admin)
      get "/regulation/admin/rnds_settings"
      expect([ response.status, json_body ]).to eq([ 200, defaults ])
    end

    it "com a credencial recusada devolve 200" do
      rnds_regulation_credential!.update!(last_check_status: "unauthorized")
      sign_in_as(regulator)
      get "/regulation/admin/rnds_settings"
      expect([ response.status, json_body ]).to eq([ 200, defaults ])
    end

    it "profissional → 403 missing_role; sem sessão → 401; care_regulation desligado → 403 feature_disabled" do
      get "/regulation/admin/rnds_settings"
      expect(response).to have_http_status(:unauthorized)
      sign_in_as(doctor!(create_unit("UBS RNDS")))
      get "/regulation/admin/rnds_settings"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      Platform::Features.set!(city: city, key: "care_regulation", enabled: false, maintainer: ledi_maintainer!)
      sign_in_as(regulator)
      get "/regulation/admin/rnds_settings"
      expect([ response.status, json_body["error"] ]).to eq([ 403, "feature_disabled" ])
    end
  end

  describe "PUT" do
    it "o admin grava com step-up: a versão sobe e o evento leva só user_id" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings",
               put_body(priority_by_color: { red: "urgent", yellow: "urgent", green: "routine", blue: "routine" },
                        specialty_sigtap: { "225120" => "0209010037" }, send_external: true)
      expect([ response.status, json_body ]).to eq(
        [ 200, { "priority_by_color" => { "red" => "urgent", "yellow" => "urgent", "green" => "routine", "blue" => "routine" },
                 "specialty_sigtap" => { "225120" => "0209010037" }, "default_sigtap" => "0301010072",
                 "send_external" => true, "version" => 2 } ]
      )
      row = RegulationRndsSetting.current
      expect([ row.version, row.updated_by_user_id ]).to eq([ 2, admin.id ])
      expect(settings_events).to eq([ { "user_id" => admin.id } ])
      get "/regulation/admin/rnds_settings"
      expect(json_body).to include("version" => 2, "send_external" => true)
    end

    it "sem mudança não sobe a versão nem publica evento" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body
      expect([ response.status, json_body["version"] ]).to eq([ 200, 1 ])
      expect(settings_events).to be_empty
    end

    it "funciona com rnds_regulation desligado e sem credencial" do
      expect(Regulation::RndsGate.enabled?(city)).to be(false)
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body(send_external: true)
      expect(response).to have_http_status(:ok)
    end

    it "sem expected_version → 422 expected_version_required; versão velha → 409 rnds_settings_changed" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body.except(:expected_version)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "expected_version_required" } ])
      json_put "/regulation/admin/rnds_settings", put_body(send_external: true)
      expect(response).to have_http_status(:ok)
      json_put "/regulation/admin/rnds_settings", put_body(send_external: false)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "rnds_settings_changed" } ])
      expect(RegulationRndsSetting.current.send_external).to be(true)
    end

    it "caráter fora de routine/urgent → 422 invalid_priority com path da cor; urgent em blue passa" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body(priority_by_color: { red: "urgent", yellow: "orange", green: "routine", blue: "routine" })
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_priority", "path" => "priority_by_color.yellow" } ])
      json_put "/regulation/admin/rnds_settings", put_body(priority_by_color: { red: "urgent", yellow: "routine", green: "routine" })
      expect(json_body).to eq("error" => "invalid_priority", "path" => "priority_by_color.blue")
      json_put "/regulation/admin/rnds_settings", put_body(priority_by_color: { red: "urgent", yellow: "routine", green: "routine", blue: "urgent" })
      expect([ response.status, json_body.dig("priority_by_color", "blue") ]).to eq([ 200, "urgent" ])
    end

    it "forma inválida → 422 invalid_request com path (cor desconhecida, objeto, send_external, versão)" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body(priority_by_color: { red: "urgent", yellow: "routine", green: "routine", blue: "routine", orange: "urgent" })
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "priority_by_color" } ])
      json_put "/regulation/admin/rnds_settings", put_body(priority_by_color: "urgent")
      expect(json_body).to eq("error" => "invalid_request", "path" => "priority_by_color")
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: [])
      expect(json_body).to eq("error" => "invalid_request", "path" => "specialty_sigtap")
      json_put "/regulation/admin/rnds_settings", put_body(send_external: "yes")
      expect(json_body).to eq("error" => "invalid_request", "path" => "send_external")
      json_put "/regulation/admin/rnds_settings", put_body(expected_version: "1")
      expect(json_body).to eq("error" => "invalid_request", "path" => "expected_version")
      expect(RegulationRndsSetting.current.version).to eq(1)
    end

    it "SIGTAP de grupo não regulável (0101010010) → 422 invalid_sigtap com path specialty_sigtap.225120" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: { "225120" => "0101010010" })
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_sigtap", "path" => "specialty_sigtap.225120" } ])
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: { "225120" => "123" })
      expect(json_body).to eq("error" => "invalid_sigtap", "path" => "specialty_sigtap.225120")
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: { "225120" => nil })
      expect(json_body).to eq("error" => "invalid_sigtap", "path" => "specialty_sigtap.225120")
    end

    it "chave que não é CBO de 6 dígitos → 422 invalid_cbo com path specialty_sigtap.<chave>" do
      stepped_up!(admin)
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: { "22512" => "0209010037" })
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_cbo", "path" => "specialty_sigtap.22512" } ])
    end

    it "mais de SPECIALTY_SIGTAP_MAX entradas → 422 invalid_request path specialty_sigtap" do
      stepped_up!(admin)
      many = (1..(Regulation::RndsLimits::SPECIALTY_SIGTAP_MAX + 1)).to_h { |i| [ format("%06d", i), "0209010037" ] }
      json_put "/regulation/admin/rnds_settings", put_body(specialty_sigtap: many)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_request", "path" => "specialty_sigtap" } ])
    end

    it "o regulador grava → 403 mesmo com step-up" do
      stepped_up!(regulator)
      json_put "/regulation/admin/rnds_settings", put_body(send_external: true)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
      expect(RegulationRndsSetting.current.send_external).to be(false)
    end

    it "sem step-up → 401 mfa_required" do
      sign_in_as(step_up_enrolled!(admin))
      json_put "/regulation/admin/rnds_settings", put_body(send_external: true)
      expect([ response.status, json_body["error"] ]).to eq([ 401, "mfa_required" ])
      expect(RegulationRndsSetting.current.send_external).to be(false)
    end
  end
end
