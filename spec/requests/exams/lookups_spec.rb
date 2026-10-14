require "rails_helper"

# Rotas de apoio pedidas pelo plano do dashboard (D2–D5, D8).
RSpec.describe "Exames — rotas de apoio", type: :request do
  before { exam_city!; exam_catalog_item! }

  let(:unit) { create_unit("UBS Apoio") }
  let(:doctor) { doctor!(unit) }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }

  def formatted_cpf(digits) = format("%s.%s.%s-%s", digits[0, 3], digits[3, 3], digits[6, 3], digits[9, 2])

  it "patient_lookup: par validado vira paciente; declarado 409; ninguém 404; sem papel 403; evento só com ids" do
    citizen = verified_citizen!(exam_seq!)
    sign_in_as(reception)
    json_post "/exams/patient_lookup", cpf: formatted_cpf(citizen.cpf)
    expect(json_body["patient"]).to include("id" => citizen.reload.patient_id, "cpf_masked" => citizen.patient.cpf_masked)
    event = DomainEvent.where(name: "exam.patient_looked_up").order(:occurred_at, :created_at).last
    expect(event.payload).to eq("patient_id" => citizen.patient_id, "user_id" => reception.id)
    Citizen.create!(cpf: "39053344705", phone: "+5541999990002", verification_level: "declared")
    json_post "/exams/patient_lookup", cpf: "390.533.447-05"
    expect([ response.status, json_body["error"] ]).to eq([ 409, "citizen_not_verified" ])
    json_post "/exams/patient_lookup", cpf: "111.444.777-35"
    expect([ response.status, json_body["error"] ]).to eq([ 404, "patient_not_found" ])
    sign_in_as(staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider"))
    json_post "/exams/patient_lookup", cpf: "111.444.777-35"
    expect([ response.status, json_body["error"] ]).to eq([ 403, "missing_role" ])
  end

  it "patient_lookup não cria paciente nem guarda CPF no evento" do
    sign_in_as(reception)
    expect { json_post "/exams/patient_lookup", cpf: "111.444.777-35" }.not_to change(Patient, :count)
    expect(DomainEvent.where(name: "exam.patient_looked_up")).to be_empty
  end

  it "catálogo legível, prestadores do exame e solicitantes da unidade" do
    enabled = exam_provider!(name: "Faz")
    exam_provider!(name: "Não faz", items: [])
    doctor
    sign_in_as(reception)
    get "/exams/catalog"
    expect(json_body["items"]).to eq([ { "sigtap_code" => "0202010503", "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA",
                                         "result_fields" => [ { "key" => "hba1c", "label" => "Hemoglobina glicada", "unit" => "%", "loinc" => "4548-4" } ] } ])
    get "/exams/providers", params: { sigtap_code: "0202010503" }
    expect(json_body["providers"]).to eq([ { "id" => enabled.id, "name" => "Faz" } ])
    get "/exams/providers"
    expect(json_body["providers"].map { |p| p["name"] }).to eq([ "Faz", "Não faz" ])
    get "/exams/requesters", params: { unit_id: unit.id }
    expect(json_body["requesters"]).to eq([ { "user_id" => doctor.id, "name" => Screenings::Json.staff_name(doctor) } ])
    sign_in_as(doctor!(create_unit("UBS Outra")))
    get "/exams/requesters", params: { unit_id: unit.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_unit_staff" ])
  end

  it "A34: prestador simulado não é oferecido com fake_lab desligado" do
    exam_provider!(name: "Real")
    exam_provider!(name: "Simulado", simulated: true)
    sign_in_as(reception)
    get "/exams/providers"
    expect(json_body["providers"].map { |p| p["name"] }).to eq([ "Real" ])
  end

  it "resultados externos do paciente pela leitura do 19a" do
    citizen = verified_citizen!(exam_seq!)
    consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    patient = Patients::Resolve.call(citizen).payload[:patient]
    result = ExamResult.create!(patient: patient, sigtap_code: "0202010503", origin: "external", source: "unit",
                                pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                                released_on: Time.zone.today, laboratory_name: "Particular", registered_by_user: doctor)
    sign_in_as(doctor)
    get "/exams/external_results", params: { patient_id: patient.id }
    expect(json_body["results"].map { |r| r.values_at("id", "sigtap_code", "label") })
      .to eq([ [ result.id, "0202010503", "DOSAGEM DE HEMOGLOBINA GLICOSILADA" ] ])
    sign_in_as(doctor!(create_unit("UBS Fora")))
    get "/exams/external_results", params: { patient_id: patient.id }
    expect([ response.status, json_body["error"] ]).to eq([ 403, "out_of_context" ])
  end
end
