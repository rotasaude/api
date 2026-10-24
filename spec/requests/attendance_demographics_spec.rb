require "rails_helper"

# D-U1: a recepção grava raça/cor e endereço ao validar o par e ao completar
# o cadastro de par já validado; opcionais e validados (recusa antes de
# validar o par, §13 E12); a resposta só traz as flags (§13 E1), nunca o endereço.
RSpec.describe "Recepção — raça/cor e endereço do paciente", type: :request do
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:fields) do
    { race_color: "05", ethnicity: "0001", address_zip: "80010-000", address_street: "Rua XV de Novembro", address_number: "1200",
      address_district: "Centro" }
  end

  before do
    clinical_city!
    sign_in_as(verifier!)
  end

  def verify!(**extra)
    json_post "/attendance/verifications", { cpf: citizen.cpf, code: issue_code_for(citizen), document_checked: true, birth_date: "1980-05-10",
                                             sex: "female", full_name: "Maria Aparecida da Silva" }.merge(extra)
  end

  def verified_pair!
    verification = CitizenVerification.create!(citizen: citizen, verified_by_user: verifier!, verified_at: Time.current)
    citizen.update!(verification_level: "verified", profile_source: "verified", birth_date: "1980-05-10", sex: "female",
                    full_name: "Maria Aparecida da Silva")
    verification
  end

  it "na validação: grava no paciente do par (resolvido na hora), com trilha só de ids" do
    verify!(**fields)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("race_color_set" => true, "address_set" => true)
    patient = Patient.find(citizen.reload.patient_id)
    expect(patient).to have_attributes(race_color: "05", ethnicity: "0001", address_zip: "80010000", address_district: "Centro")
    expect(DomainEvent.where(name: "patient.demographics_updated").last.payload).to eq("patient_id" => patient.id, "user_id" => verifier!.id)
    expect(response.body).not_to include("Novembro", "80010000", "0001")
  end

  it "inválido recusa antes de validar o par; sem os campos, nada muda" do
    verify!(race_color: "99")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_race_color", "field" => "race_color")
    expect(citizen.reload.verification_level).to eq("declared")
    verify!
    expect(response).to have_http_status(:created)
    expect(json_body).not_to have_key("race_color_set")
    expect(citizen.reload.patient_id).to be_nil
    expect(DomainEvent.where(name: "patient.demographics_updated")).to be_empty
  end

  # §13 E12: a combinação raça × etnia também é conferida antes do Verify —
  # o par continua declarado e o código não é consumido.
  it "indígena sem etnia na validação: 422 ethnicity_required, par declarado, código intacto" do
    code = issue_code_for(citizen)
    json_post "/attendance/verifications", cpf: citizen.cpf, code: code, document_checked: true, birth_date: "1980-05-10", sex: "female",
                                           full_name: "Maria Aparecida da Silva", race_color: "05"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "ethnicity_required", "field" => "ethnicity")
    expect(citizen.reload.verification_level).to eq("declared")
    expect(CitizenVerificationCode.where(citizen_id: citizen.id, consumed_at: nil)).to exist
    json_post "/attendance/verifications", cpf: citizen.cpf, code: code, document_checked: true, birth_date: "1980-05-10", sex: "female",
                                           full_name: "Maria Aparecida da Silva", race_color: "05", ethnicity: "0001"
    expect(response).to have_http_status(:created)
  end

  it "na validação, a etnia confere com a raça já gravada no paciente do mesmo CPF" do
    verification = verified_pair!
    patient = Patients::Resolve.call(citizen).payload[:patient]
    patient.update!(race_color: "05", ethnicity: "0001")
    json_post "/attendance/verifications/#{verification.id}/names", race_color: "03"
    expect(json_body).to eq("error" => "invalid_ethnicity", "field" => "ethnicity")
    expect(patient.reload.race_color).to eq("05")
  end

  it "no cadastro de par já validado: só os campos (sem nomes) também valem" do
    verification = verified_pair!
    json_post "/attendance/verifications/#{verification.id}/names", race_color: "03", address_zip: "80010000", address_street: "Rua XV",
                                                                   address_number: "SN", address_district: "Centro"
    expect(response).to have_http_status(:ok)
    expect(json_body.slice("race_color_set", "address_set")).to eq("race_color_set" => true, "address_set" => true)
    expect(json_body["citizen"]).to include("id" => citizen.id)
    expect(response.body).not_to include("Rua XV", "80010000")
    expect(Patient.find(citizen.reload.patient_id).address_number).to eq("SN")
  end

  it "no cadastro, nomes sem campos: flags false (sem paciente)" do
    verification = verified_pair!
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida da Silva"
    expect(response).to have_http_status(:ok)
    expect(json_body.slice("race_color_set", "address_set")).to eq("race_color_set" => false, "address_set" => false)
  end

  # §13 E12 em names: recusa antes do CompleteNames — os nomes não mudam.
  it "no cadastro, indígena sem etnia: 422 ethnicity_required e nomes não gravados" do
    verification = verified_pair!
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida Souza", race_color: "05"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "ethnicity_required", "field" => "ethnicity")
    expect(citizen.reload.full_name).to eq("Maria Aparecida da Silva")
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida Souza", address_street: "R" * 31
    expect(json_body).to eq("error" => "too_long", "field" => "address_street")
    expect(citizen.reload.full_name).to eq("Maria Aparecida da Silva")
  end

  it "no cadastro com validação revogada: 409 e nada gravado" do
    verification = verified_pair!
    verification.update!(revoked_at: Time.current, revoked_by_user: lab_admin!, revoke_reason: "documento divergente na conferência")
    json_post "/attendance/verifications/#{verification.id}/names", race_color: "03"
    expect(response).to have_http_status(:conflict)
    expect(citizen.reload.patient_id).to be_nil
  end

  # Módulo 24a (Desvio 8; contrato §14 L6): endereço de paciente com cadastro
  # ativo em domicílio recusado ANTES de gravar os nomes (§13 E12).
  it "no cadastro, paciente com cadastro ativo em domicílio: endereço 422 address_from_household, nomes intactos" do
    verification = verified_pair!
    patient = Patients::Resolve.call(citizen).payload[:patient]
    registry_registration!(patient: patient)
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida Souza", address_zip: "80010000"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "address_from_household", "field" => "address_zip")
    expect(citizen.reload.full_name).to eq("Maria Aparecida da Silva")
    json_post "/attendance/verifications/#{verification.id}/names", race_color: "03"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("race_color_set" => true, "address_from_household" => true)
  end
end
