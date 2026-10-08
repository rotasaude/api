require "rails_helper"

# Contratos §4: GET /attendance/consultations/:id/print — PDF na hora, sem
# cache, com trilha; 409 not_finalized / patient_name_missing.
RSpec.describe "Impresso da consulta", type: :request do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  def body = JSON.parse(response.body)

  it "PDF para quem lê; sem cache; trilha; rascunho 409; sem nome 409; fora de contexto 403" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor)
    get "/attendance/consultations/#{draft.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 409, "not_finalized" ])

    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    consulting_attendance!(unit, citizen: consultation.attendance.citizen, doctor: doctor)
    get "/attendance/consultations/#{consultation.id}/print"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Disposition"]).to include("consulta.pdf")
    expect(response.headers["Content-Disposition"]).not_to include("Maria")
    expect(DomainEvent.where(name: "clinical_record.viewed").pluck(:payload).last)
      .to include("patient_id" => consultation.patient_id, "access" => "in_context")

    consultation.patient.update_columns(full_name: nil)
    get "/attendance/consultations/#{consultation.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 409, "patient_name_missing" ])

    sign_in_as(doctor!(unit, cbo: "223505"))
    get "/attendance/consultations/#{consultation.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 403, "out_of_context" ])
  end
end
