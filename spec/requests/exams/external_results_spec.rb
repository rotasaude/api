require "rails_helper"

# Spec §6 "Resultado externo" (F-21.9): profissional com leitura do
# paciente (na consulta) ou a unidade; origem external; ciência dada por
# quem registra; nunca aparece para o prestador.
RSpec.describe "Exames — resultado externo", type: :request do
  before { exam_city!; exam_catalog_item! }

  let(:unit) { create_unit("UBS Externo") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(exam_seq!) }

  def upload(user)
    sign_in_as(user)
    json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    json_body["upload_id"]
  end

  def post_external(**over)
    json_post "/exams/external_results", { sigtap_code: "0202010503", released_on: Time.zone.today.iso8601,
                                           laboratory_name: "Lab", values: [] }.merge(over)
  end

  it "o profissional em contexto registra; vira resultado externo com ciência; evento só com id; leitura deixa trilha" do
    consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    patient = Patients::Resolve.call(citizen).payload[:patient]
    upload_id = upload(doctor)
    expect do
      post_external(patient_id: patient.id, laboratory_name: "Laboratório Particular", upload_id: upload_id,
                    values: [ { key: "hba1c", value: "8.2" } ])
    end.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(response).to have_http_status(:created)
    result = ExamResult.find(json_body["id"])
    expect(result).to have_attributes(origin: "external", source: "unit", exam_order_id: nil, registered_by_user_id: doctor.id,
                                      patient_id: patient.id, consultation_id: nil)
    expect(result.pdf_file).to be_consumed
    expect(json_body).to include("origin" => "external", "acknowledged_at" => be_present, "values" => [ hash_including("value" => "8.2") ])
    expect(DomainEvent.where(name: "exam_result.external_recorded").last.payload).to eq("exam_result_id" => result.id)
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("patient_id" => patient.id, "user_id" => doctor.id, "access" => "in_context", "exam_result_id" => result.id)
  end

  it "fora de contexto 403; SIGTAP fora do grupo 02 422; sem PDF 422; a recepção registra pelo par" do
    patient = Patients::Resolve.call(citizen).payload[:patient]
    stranger = doctor!(create_unit("UBS Fora"))
    upload_id = upload(stranger)
    post_external(patient_id: patient.id, upload_id: upload_id)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
    reception = staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
    upload_id = upload(reception)
    post_external(citizen_id: citizen.id, sigtap_code: "0301010064", upload_id: upload_id)
    expect(json_body["error"]).to eq("sigtap_unknown")
    post_external(citizen_id: citizen.id, upload_id: SecureRandom.uuid)
    expect(json_body["error"]).to eq("missing_pdf")
    expect do
      post_external(citizen_id: citizen.id, upload_id: upload_id)
      expect(response).to have_http_status(:created)
    end.not_to(change { DomainEvent.where(name: "clinical_record.viewed").count }) # visão administrativa: sem trilha
    expect(json_body.keys).to eq(%w[id origin source released_on laboratory_name])
  end

  it "recusa não cria Patient nem consome o arquivo" do
    stranger = doctor!(create_unit("UBS Fora 2"))
    upload_id = upload(stranger)
    expect(Patient.where(cpf: citizen.cpf)).to be_empty
    expect do
      post_external(citizen_id: citizen.id, upload_id: upload_id)
    end.not_to(change { Patient.count })
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
    expect(ExamFile.find(upload_id)).not_to be_consumed
    expect(ExamResult.count).to eq(0)
  end

  it "sem papel 403; consulta de outra autora 404; data futura e laboratório inválido 422; PDF que não é PDF desfaz o consumo" do
    other = staff_with("outro-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    upload_id = upload(other)
    post_external(citizen_id: citizen.id, upload_id: upload_id)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])

    reception = staff_with("rec2-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier")
    upload_id = upload(reception)
    post_external(citizen_id: citizen.id, upload_id: upload_id, released_on: (Time.zone.today + 1).iso8601)
    expect(json_body["error"]).to eq("invalid_released_on")
    post_external(citizen_id: citizen.id, upload_id: upload_id, laboratory_name: " ")
    expect(json_body["error"]).to eq("invalid_laboratory")
    post_external(citizen_id: citizen.id, upload_id: upload_id, values: [ { key: "nope", value: "1" } ])
    expect(json_body["error"]).to eq("invalid_values")
    post_external(citizen_id: citizen.id, upload_id: upload_id, consultation_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)

    png = ExamFile.create!(content_type: "image/png", byte_size: 8, sha256: "0" * 64, data: Base64.strict_encode64("\x89PNG\r\n\x1A\n".b),
                           uploaded_by_user: reception)
    post_external(citizen_id: citizen.id, upload_id: png.id)
    expect(json_body["error"]).to eq("missing_pdf")
    expect(png.reload).not_to be_consumed
    expect(ExamResult.count).to eq(0)
  end
end
