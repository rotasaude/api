require "rails_helper"

RSpec.describe "Sessão do cidadão com os interruptores", type: :request do
  it "GET /citizen/session devolve os interruptores utilizáveis da cidade" do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    Platform::Features.set!(city: Current.city, key: "pec_external_view", enabled: true, maintainer: ledi_maintainer!)
    sign_in_citizen
    get "/citizen/session"
    features = JSON.parse(response.body)["features"]
    expect(features).to include("patient_timeline")
    expect(features).not_to include("pec_external_view", "clinical_record")
  end
end
