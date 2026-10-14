require "rails_helper"

# Contrato §4: 403 not_verified para par declarado; 404 not_available sem
# paciente ou sem prontuário; trilha citizen.
RSpec.describe "Resumo clínico do cidadão", type: :request do
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  it "validado com paciente: o resumo; declarado: 403; sem paciente: 404 not_available" do
    timeline_city!
    ciap2_release!; cid10_release!; sigtap_release!
    citizen = verified_citizen!(131)
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    declared = Citizen.create!(cpf: "11144477735", phone: citizen.phone, verification_level: "declared")
    fresh = verified_citizen!(132)
    sign_in_citizen(citizen.phone)
    get "/citizen/health_summary", params: { citizen_id: citizen.id }
    expect(response).to have_http_status(:ok)
    expect(body.keys).to match_array(%w[problems medications exam_requests vitals])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload["access"]).to eq("citizen")
    get "/citizen/health_summary", params: { citizen_id: declared.id }
    expect(status_and_error).to eq([ 403, "not_verified" ])
    sign_in_citizen(fresh.phone)
    get "/citizen/health_summary", params: { citizen_id: fresh.id }
    expect(status_and_error).to eq([ 404, "not_available" ])
  end

  it "modo integrado (sem prontuário): 404 not_available" do
    timeline_city!(record_mode: "integrated", clinical_record: false)
    citizen = verified_citizen!(133)
    sign_in_citizen(citizen.phone)
    get "/citizen/health_summary", params: { citizen_id: citizen.id }
    expect(status_and_error).to eq([ 404, "not_available" ])
  end
end
