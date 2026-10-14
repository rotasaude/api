require "rails_helper"

# Contrato §3 (preâmbulo; Desvio 11): o municipal_admin lê o conteúdo dos
# documentos da consulta finalizada, com step-up, linha para sempre e trilha
# administrative; rascunho ou inexistente → 404.
RSpec.describe "Leitura administrativa dos documentos", type: :request do
  before { documents_city!; ciap2_release!; cid10_release!; sigtap_release! }

  it "lê com step-up, deixa linha e trilha; sem step-up 401; profissional 403" do
    unit = create_unit
    doctor = doctor!(unit)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    document = ClinicalDocuments::Issue.call(kind: "sick_note", content: { "type" => "leave", "days" => 2 }, by: doctor,
                                             consultation: consultation).payload[:document]
    admin = municipal_admin!
    sign_in_as(step_up_enrolled!(admin))
    get "/clinical_record/consultations/#{consultation.id}/documents"
    expect(response).to have_http_status(:unauthorized)
    stepped_up!(admin)
    expect { get "/clinical_record/consultations/#{consultation.id}/documents" }.to change(ClinicalRecordAdministrativeRead, :count).by(1)
    expect(json_body["items"].map { |item| item["id"] }).to eq([ document.id ])
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).last.payload).to include("access" => "administrative", "consultation_id" => consultation.id)
    get "/clinical_record/consultations/#{SecureRandom.uuid}/documents"
    expect(response).to have_http_status(:not_found)
    sign_in_as(doctor)
    get "/clinical_record/consultations/#{consultation.id}/documents"
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "forbidden")
  end
end
