require "rails_helper"

# Módulo 31, fix round 1 da Task 14 (P51, G1): os caminhos automáticos que
# levariam o nome do CAPS ao wpda. A cobertura do bairro e o prestador próprio
# recusam o CAPS; o CAPS que já estava na cobertura (dado antigo) não vira
# unidade de referência nem destino do pedido da triagem web; e a unidade com
# cobertura ou prestador não vira CAPS (409 unit_has_attendances).
RSpec.describe "CAPS — caminhos automáticos da agenda", type: :request do
  let(:caps_name) { "CAPS II Boa Vista" }
  let(:caps) { HealthUnit.create!(name: caps_name, kind: "caps", caps_modality: "caps_ii", service_classification: "001", cnes: "7654321") }
  let!(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
  def body = JSON.parse(response.body)

  describe "triagem web do bairro coberto por um CAPS (dado antigo)" do
    before do
      Current.city = TEST_CITY_A
      ensure_appointment_types!
      ConsentTerm.create!(version: "1", body: "Termo de teste", published_at: Time.current)
      NeighborhoodCoverage.create!(neighborhood: centro, health_unit: caps)
      sign_in_citizen("+5541998765432")
    end
    after { Current.reset; Rails.cache.clear }

    let(:rule) { [ { "when" => { "gte" => [ "outcome.score", 1 ] }, "appointment_type" => "consulta_medica", "priority" => "routine", "due_in_days" => 30 } ] }

    it "não abre pedido no CAPS; /citizen/triages/:id e /citizen/appointments não mostram o CAPS" do
      active_protocol!("saude-do-idoso", scheduling: rule)
      started = start_citizen_triage(protocol_name: "saude-do-idoso", neighborhood_id: centro.id)
      citizen_id = started["citizen_id"]
      json_post "/citizen/conversations/#{started['conversation_id']}/answers", answer: "true", idempotency_key: SecureRandom.uuid
      triage_id = body.fetch("triage_id")

      request = AppointmentRequest.find_by!(origin_triage_id: triage_id)
      expect(request.target_unit_id).to be_nil
      get "/citizen/triages/#{triage_id}"
      expect(response).to have_http_status(:ok)
      expect(body["reference_units"]).to eq([])
      expect(body.dig("scheduling_request", "unit_name")).to be_nil
      expect(response.body).not_to include(caps_name)
      get "/citizen/appointments", params: { citizen_id: citizen_id }
      expect(response).to have_http_status(:ok)
      expect(body["appointments"].size).to eq(1)
      expect(response.body).not_to include(caps_name)
    end
  end

  describe "cadastro" do
    let!(:city) { psychosocial_city! }
    let(:admin) { psychosocial_admin! }

    before { sign_in_as(admin) }

    it "cobertura do bairro com CAPS → 422 caps_unit_not_allowed (path health_unit_ids)" do
      json_post "/territory/neighborhoods/#{centro.id}/coverage", health_unit_ids: [ caps.id ]
      expect([ response.status, body["error"], body["path"] ]).to eq([ 422, "caps_unit_not_allowed", "health_unit_ids" ])
      expect(NeighborhoodCoverage.count).to eq(0)
    end

    it "unidade na cobertura de bairro ou prestador próprio da regulação não vira CAPS (409 unit_has_attendances)" do
      covered = HealthUnit.create!(name: "UBS Coberta", kind: "ubs")
      NeighborhoodCoverage.create!(neighborhood: centro, health_unit: covered)
      provider = HealthUnit.create!(name: "Policlínica", kind: "other", cnes: "1231231")
      CareProvider.create!(name: "Policlínica", kind: "own", health_unit: provider, active: true, updated_by_user: admin)
      [ covered, provider ].each do |unit|
        json_post "/attendance/units/#{unit.id}", name: unit.name, kind: "caps", caps_modality: "caps_ii"
        expect([ response.status, body["error"] ]).to eq([ 409, "unit_has_attendances" ])
        expect(unit.reload.kind).not_to eq("caps")
      end
    end
  end
end
