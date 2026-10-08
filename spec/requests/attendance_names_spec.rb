require "rails_helper"

# ADR 0031 (spec §3; contratos §2 e §9): nomes conferidos no documento na
# validação presencial; cliente antigo sem a chave continua validando;
# completar nomes de par já validado no check-in; a fila só com o nome de
# exibição. Nome nunca em log nem em evento.
RSpec.describe "Nomes na validação presencial", type: :request do
  let(:unit) { create_unit }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:marker) { "Marcadora #{SecureRandom.hex(3)}" }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  def verify!(code, **names)
    json_post "/attendance/verifications", { cpf: citizen.cpf, code: code, document_checked: true,
                                            birth_date: "1980-05-10", sex: "female" }.merge(names)
  end

  before { sign_in_as(verifier!) }

  it "valida com nomes (cifrados); nome de exibição é o social; nada em log nem evento" do
    log = capture_log do
      verify!(issue_code_for(citizen), full_name: "#{marker} da Silva", social_name: "Mariana", mother_name: "Joana")
    end
    expect(response).to have_http_status(:created)
    expect(citizen.reload.slice(:full_name, :social_name, :mother_name))
      .to eq("full_name" => "#{marker} da Silva", "social_name" => "Mariana", "mother_name" => "Joana")
    expect(citizen.display_name).to eq("Mariana")
    expect(log).not_to include(marker)
    expect(DomainEvent.pluck(:payload).to_json).not_to include(marker)
  end

  it "com a chave, nome inválido é 422 e o código continua valendo; sem a chave (cliente antigo), valida sem nome" do
    code = issue_code_for(citizen)
    verify!(code, full_name: nil)
    expect(status_and_error).to eq([ 422, "invalid_full_name" ])
    verify!(code, full_name: "Maria", social_name: "x" * 201)
    expect(status_and_error).to eq([ 422, "invalid_social_name" ])
    verify!(code, full_name: "Maria Aparecida", mother_name: [ "Joana" ])
    expect(status_and_error).to eq([ 422, "invalid_mother_name" ])
    verify!(code)
    expect(response).to have_http_status(:created)
    expect(citizen.reload.full_name).to be_nil
  end

  it "cartão do balcão e do check-in: nomes sem os valores e a validação ativa" do
    json_post "/attendance/lookup", cpf: citizen.cpf, code: issue_code_for(citizen)
    expect(body.dig("citizen", "names")).to eq("full_name_set" => false, "display_name" => nil)

    validated = verified_citizen!(8, full_name: "Maria Aparecida da Silva", social_name: nil)
    validated.update_columns(full_name: nil)
    triage = completed_web_triage_for(validated)
    code = Citizens::IssueCheckInCode.call(citizen: validated, triage: triage).payload.fetch(:code)
    json_post "/attendance/check_ins/lookup", cpf: validated.cpf, code: code, health_unit_id: unit.id
    expect(body["citizen"]).to include("names" => { "full_name_set" => false, "display_name" => nil },
                                       "verification_id" => validated.active_verification.id)
  end

  it "check-in que valida devolve a validação, para completar os nomes na sequência" do
    triage = completed_web_triage_for(citizen)
    code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: true
    expect(response).to have_http_status(:created)
    expect(body["verification_id"]).to eq(citizen.reload.active_verification.id)
  end

  it "completar nomes: só citizen_verifier; revogada 409; inválido 422; inexistente 404" do
    verification = CitizenVerification.create!(citizen: citizen, verified_by_user: verifier!, verified_at: Time.current)
    citizen.update!(verification_level: "verified")
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida da Silva", social_name: "Mariana"
    expect(response).to have_http_status(:ok)
    expect(body["citizen"]).to include("id" => citizen.id, "cpf_masked" => citizen.cpf_masked,
                                       "names" => { "full_name_set" => true, "display_name" => "Mariana" })
    expect(body.to_json).not_to include("Aparecida")
    json_post "/attendance/verifications/#{verification.id}/names", full_name: ""
    expect(status_and_error).to eq([ 422, "invalid_full_name" ])
    json_post "/attendance/verifications/#{SecureRandom.uuid}/names", full_name: "Maria Aparecida"
    expect(status_and_error).to eq([ 404, "not_found" ])
    verification.update!(revoked_at: Time.current, revoked_by_user: staff_with("adm-#{SecureRandom.hex(3)}@x.gov.br", "municipal_admin"),
                         revoke_reason: "documento de outra pessoa")
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida"
    expect(status_and_error).to eq([ 409, "already_revoked" ])
    sign_in_as(staff_with("medica-#{SecureRandom.hex(3)}@x.gov.br", "health_professional"))
    json_post "/attendance/verifications/#{verification.id}/names", full_name: "Maria Aparecida"
    expect(response).to have_http_status(:forbidden)
  end

  it "todo item da fila traz só o nome de exibição (recepção incluída)" do
    verified = verified_citizen!(7, full_name: "Maria Aparecida da Silva", social_name: "Mariana")
    walk_in_attendance!(unit, citizen: verified)
    sign_in_as(reception!)
    get "/attendance/units/#{unit.id}/queue"
    expect(body["waiting"].sole["display_name"]).to eq("Mariana")
    expect(response.body).not_to include("Aparecida", "Joana")
  end
end
