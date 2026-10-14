require "rails_helper"

# Divergência D3: upload por JSON (Base64) — a guarda de escrita por cookie
# recusa multipart. O download pela URL curta exige a sessão do mesmo usuário.
RSpec.describe "Arquivos de exame", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city! }

  let(:user) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }

  it "sobe em JSON, recusa multipart, baixa só pela URL curta" do
    sign_in_as(user)
    post "/exams/uploads", params: { file: Rack::Test::UploadedFile.new(StringIO.new(ExamHelpers::PDF_BYTES), "application/pdf", original_filename: "guia.pdf") }
    expect(response).to have_http_status(:unsupported_media_type)
    log = capture_log do
      json_post "/exams/uploads", content_type: "application/pdf", data: Base64.strict_encode64(ExamHelpers::PDF_BYTES)
    end
    expect(response).to have_http_status(:created)
    expect(log).not_to include(Base64.strict_encode64(ExamHelpers::PDF_BYTES)[0, 20])
    file = ExamFile.find(json_body["upload_id"])
    file.update!(consumed_at: Time.current) # arquivo solto não sai: só o ligado a pedido ou resultado
    get Exams::Files.url_for(file, user: user)
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(ExamHelpers::PDF_BYTES)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.headers["Content-Disposition"]).to start_with("inline")
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(0) # guia: sem trilha (A27)
    sign_in_as(municipal_admin!)
    get Exams::Files.url_for(file, user: user)
    expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])
    sign_in_as(user)
    url = Exams::Files.url_for(file, user: user)
    travel(6.minutes) { get url }
    expect([ response.status, json_body["error"] ]).to eq([ 410, "link_expired" ])
    json_post "/exams/uploads", content_type: "application/zip", data: Base64.strict_encode64("PK\x03\x04")
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_file" ])
  end

  it "A27: baixar o PDF de um laudo grava clinical_record.viewed com access exam_result" do
    patient, = exam_patient!(exam_seq!)
    file = pdf_file!(user: user).tap { |f| f.update!(consumed_at: Time.current) }
    result = ExamResult.create!(patient: patient, pdf_file: file, origin: "external", source: "unit", sigtap_code: "0202010503",
                                laboratory_name: "Lab", released_on: Time.zone.today, values: "[]", registered_by_user: user)
    sign_in_as(user)
    expect { get Exams::Files.url_for(file, user: user) }.to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    payload = DomainEvent.where(name: "clinical_record.viewed").last.payload
    expect(payload).to include("access" => "exam_result", "exam_result_id" => result.id, "patient_id" => patient.id, "user_id" => user.id)
    expect(payload.to_s).not_to include("JVBER")
  end
end
