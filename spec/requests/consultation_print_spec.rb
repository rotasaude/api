require "rails_helper"

# Contratos §4/§9: GET /attendance/consultations/:id/print — PDF na hora, sem
# cache, com trilha; só da autora (decisão do usuário 2026-10-09: não autora
# 403 not_author, mesmo em contexto); 409 not_finalized / patient_name_missing.
RSpec.describe "Impresso da consulta", type: :request do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  def body = JSON.parse(response.body)

  it "PDF para a autora; sem cache; trilha author; rascunho 409; sem nome 409; não autora em contexto 403" do
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
      .to include("patient_id" => consultation.patient_id, "access" => "author")

    consultation.patient.update_columns(full_name: nil)
    get "/attendance/consultations/#{consultation.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 409, "patient_name_missing" ])

    sign_in_as(doctor!(unit, cbo: "223505"))
    get "/attendance/consultations/#{consultation.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 403, "not_author" ])
  end

  it "rascunho de outro profissional → 403 not_author (não revela o estado); o autor recebe 409" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(doctor!(unit))
    get "/attendance/consultations/#{draft.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 403, "not_author" ])
    sign_in_as(doctor)
    get "/attendance/consultations/#{draft.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 409, "not_finalized" ])
  end
end
