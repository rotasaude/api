require "rails_helper"

RSpec.describe "Sessão do cidadão com os interruptores", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  it "GET /citizen/session devolve os interruptores utilizáveis da cidade" do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    Platform::Features.set!(city: Current.city, key: "pec_external_view", enabled: true, maintainer: ledi_maintainer!)
    sign_in_citizen
    get "/citizen/session"
    features = JSON.parse(response.body)["features"]
    expect(features).to include("patient_timeline")
    expect(features).not_to include("pec_external_view", "clinical_record")
  end

  it "POST /citizen/session traz patient_timeline quando ligado e não traz quando desligado" do
    OtpSender::Test.reset!
    timeline_city!
    phone = "(41) 99876-5432"
    open_session = lambda do
      json_post "/citizen/otp", phone: phone
      json_post "/citizen/session", phone: phone, code: OtpSender::Test.deliveries.last[:code]
      expect(response).to have_http_status(:created)
      JSON.parse(response.body)["features"]
    end
    expect(open_session.call).to include("patient_timeline")

    Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: false, maintainer: ledi_maintainer!)
    travel 2.minutes do
      expect(open_session.call).not_to include("patient_timeline")
    end
  end

  # Módulo 23 (contrato §11 T6): care_lines chega pelo mecanismo genérico.
  it "GET /citizen/session traz care_lines só quando utilizável (modo record com o prontuário)" do
    care_city!
    sign_in_citizen
    get "/citizen/session"
    expect(JSON.parse(response.body)["features"]).to include("clinical_record", "care_lines")
    Current.city.update!(record_mode: "integrated")
    CityCatalog.reset_cache!
    get "/citizen/session"
    expect(JSON.parse(response.body)["features"]).not_to include("care_lines")
  end
end
