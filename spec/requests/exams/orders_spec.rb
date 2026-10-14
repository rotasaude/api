require "rails_helper"
require "json_schemer"

# Contrato §3 (Divergências D2, D5, D6): a guia da recepção nasce de um par
# validado; a lista pede um recorte (paciente, unidade ou requester=me) e
# devolve a visão de quem lê; leitura clínica deixa trilha.
RSpec.describe "Exames — pedidos", type: :request do
  before { exam_city!; exam_catalog_item! }

  let(:unit) { create_unit("UBS Guia") }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(50) }
  let(:schema) { JSONSchemer.schema(Rails.root.join("spec/fixtures/exams/exam-order-v1.json")) }

  def upload!(user)
    ExamFile.create!(content_type: "application/pdf", byte_size: ExamHelpers::PDF_BYTES.bytesize, sha256: "0" * 64,
                     data: Base64.strict_encode64(ExamHelpers::PDF_BYTES), uploaded_by_user: user)
  end

  def guide(over = {})
    { citizen_id: citizen.id, unit_id: unit.id, sigtap_code: "0202010503", priority: "routine",
      requester: { name: "Dra. Ana Externa", cns: Professionals::Cns.generate("externa") },
      external_reference: "GUIA-123", guide_upload_id: upload!(reception).id }.merge(over)
  end

  it "a recepção cadastra a guia: paciente resolvido, solicitante digitado, forma administrativa válida no esquema" do
    sign_in_as(reception)
    json_post "/exams/orders", guide
    expect(response).to have_http_status(:created)
    order = ExamOrder.find(json_body["id"])
    expect(order).to have_attributes(origin: "reception_guide", requester_user_id: nil, requester_name: "Dra. Ana Externa",
                                     unit_id: unit.id, patient_id: citizen.reload.patient_id, status: "awaiting_schedule")
    expect(order.guide_file.consumed?).to be(true)
    expect(json_body["requester"]["cns"]).to be_nil
    expect(json_body["guide_url"]).to start_with("/exams/files/")
    expect(schema.valid?(json_body)).to be(true)
  end

  it "recusa: par declarado 409, catálogo, CNS, guia ausente ou de outro, solicitante sem papel, fora da unidade" do
    sign_in_as(reception)
    declared = Citizen.create!(cpf: "39053344705", phone: "+5541999990001", verification_level: "declared")
    { { citizen_id: declared.id } => [ 409, "citizen_not_verified" ],
      { sigtap_code: "0202020380" } => [ 422, "sigtap_not_in_catalog" ],
      { requester: { name: "Fulano", cns: "123" } } => [ 422, "invalid_cns" ],
      { requester: { user_id: reception.id } } => [ 422, "invalid_requester" ],
      { guide_upload_id: upload!(doctor).id } => [ 422, "guide_missing" ],
      { citizen_id: SecureRandom.uuid } => [ 404, "not_found" ] }.each do |over, (status, error)|
      json_post "/exams/orders", guide(over)
      expect([ response.status, json_body["error"] ]).to eq([ status, error ]), over.inspect
    end
    other_unit = create_unit("UBS Outra")
    sign_in_as(doctor)
    json_post "/exams/orders", guide(unit_id: other_unit.id, guide_upload_id: upload!(doctor).id)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_unit_staff" ])
  end

  it "lista por paciente exige leitura do 19a e deixa trilha; requester=me; unidade vê administrativa" do
    patient, = exam_patient!(51)
    order = exam_order!(patient: patient, unit: unit, requester: doctor)
    outsider = doctor!(create_unit("UBS Fora"))
    sign_in_as(outsider)
    get "/exams/orders", params: { patient_id: patient.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
    sign_in_as(doctor)
    get "/exams/orders", params: { requester: "me" }
    expect(json_body["orders"].map { |o| o["id"] }).to eq([ order.id ])
    expect(json_body["orders"].first).not_to have_key("events")
    # A lista do solicitante é clínica: trilha por exame, como no detalhe.
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("access" => "author", "exam_order_id" => order.id, "user_id" => doctor.id)
    get "/exams/orders/#{order.id}"
    expect(json_body["events"].map { |e| e["kind"] }).to eq(%w[requested])
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("access" => "author", "exam_order_id" => order.id, "user_id" => doctor.id)
    sign_in_as(reception)
    get "/exams/orders", params: { unit_id: unit.id }
    expect(json_body["orders"].first["result"]).to be_nil
    get "/exams/orders"
    expect([ response.status, json_body["error"] ]).to eq([ 422, "filter_required" ])
    get "/exams/orders", params: { unit_id: unit.id, status: [ "bogus" ] }
    expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_filter" ])
    get "/exams/orders/#{SecureRandom.uuid}"
    expect(response).to have_http_status(:not_found)
  end

  it "recorte por consulta (autora ou em contexto), com consultation_id no exame" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(exam_seq!))
    sign_in_as(doctor)
    get "/exams/orders", params: { consultation_id: consultation.id }
    expect(json_body["orders"].map { |o| o["consultation_id"] }).to eq([ consultation.id ])
    sign_in_as(doctor!(create_unit("UBS Alheia")))
    get "/exams/orders", params: { consultation_id: consultation.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
  end

  it "pagina por cursor sem repetir nem perder" do
    patient, = exam_patient!(52)
    ids = 5.times.map { exam_order!(patient: patient, unit: unit, requester: doctor).id }
    sign_in_as(reception)
    seen = []
    before = nil
    loop do
      get "/exams/orders", params: { unit_id: unit.id, limit: 2, before: before }.compact
      seen += json_body["orders"].map { |o| o["id"] }
      before = json_body["next_before"]
      break unless before
    end
    expect(seen.sort).to eq(ids.sort)
    expect(seen.uniq.size).to eq(5)
  end
end
