require "rails_helper"

# D-U1: o faturista corrige raça/cor e endereço do paciente pendente; trilha
# só com ids; a resposta só traz as flags (§13 E1), nunca o endereço/raça.
# Billing::Pending/Billing::Close nascem na Task 9: aqui a pendência é a
# crítica de fechamento (Billing::Critic closing: true) do procedimento.
RSpec.describe "Faturamento — dados do paciente para o BPA-I", type: :request do
  before do
    billing_city!
    billing_settings!
  end

  let(:unit) { upa! }
  let(:patient) { billing_patient!(demographics: false) }
  let(:clerk) { billing_clerk! }

  def closing_reasons(procedure)
    facts = Billing::Critic::Facts.new(establishment: Billing::Establishment.for_unit(unit), sigtap_code: procedure.sigtap_code,
                                       performed_on: procedure.performed_on, cbo_code: procedure.cbo_code,
                                       professional_cns: Billing::Staff.cns(procedure.professional_user), cid10: procedure.cid10,
                                       patient: Patient.find(procedure.patient_id))
    Billing::Critic.call(facts, closing: true).reasons
  end

  it "faturista corrige; a pendência some; outros papéis 403; inexistente 404; inválido 422" do
    procedure = recorded_procedure!(unit: unit, professional: doctor!(unit), patient: patient)
    expect(closing_reasons(procedure)).to eq(%w[missing_race_color missing_address])
    sign_in_as(lab_admin!)
    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "03"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(clerk)
    json_patch "/billing/patients/#{SecureRandom.uuid}/demographics", race_color: "03"
    expect(response).to have_http_status(:not_found)
    json_patch "/billing/patients/not-a-uuid/demographics", race_color: "03"
    expect(response).to have_http_status(:not_found)
    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "99"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "invalid_race_color", "field" => "race_color")
    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "05"
    expect(json_body).to eq("error" => "ethnicity_required", "field" => "ethnicity")
    expect(patient.reload.race_color).to be_nil
    expect(DomainEvent.where(name: "billing_patient.demographics_updated")).to be_empty

    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "03", address_zip: "80010000", address_street: "Rua XV de Novembro",
                                                                 address_number: "1200", address_district: "Centro"
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("patient" => { "id" => patient.id, "display_name" => patient.display_name, "has_cpf" => true, "cns_masked" => nil },
                            "race_color_set" => true, "address_set" => true, "address_from_household" => false)
    expect(response.body).not_to include("Novembro", "80010000", "Centro")
    expect(patient.reload).to have_attributes(race_color: "03", ethnicity: nil, address_zip: "80010000", address_street: "Rua XV de Novembro",
                                              address_number: "1200", address_complement: nil, address_district: "Centro")
    expect(DomainEvent.where(name: "billing_patient.demographics_updated").sole.payload).to eq("patient_id" => patient.id, "user_id" => clerk.id)
    expect(closing_reasons(procedure)).to eq([])
  end

  it "corpo sem nenhuma chave de dados do paciente: 422, nada gravado e nenhum evento" do
    sign_in_as(clerk)
    [ {}, { foo: "bar", name: "x" } ].each do |body|
      json_patch "/billing/patients/#{patient.id}/demographics", body
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body).to eq("error" => "invalid_demographics")
    end
    expect(patient.reload).to have_attributes(race_color: nil, address_zip: nil, address_street: nil)
    expect(DomainEvent.where(name: "billing_patient.demographics_updated")).to be_empty
    sign_in_as(lab_admin!)
    json_patch "/billing/patients/#{patient.id}/demographics", {}
    expect(response).to have_http_status(:forbidden)
    sign_in_as(clerk)
    json_patch "/billing/patients/#{SecureRandom.uuid}/demographics", {}
    expect(response).to have_http_status(:not_found)
  end

  # Módulo 24a (Desvio 8; contrato §14 L6): com cadastro ativo em domicílio o
  # endereço é do cadastro domiciliar — só leitura aqui; raça/cor segue livre.
  it "paciente com cadastro ativo em domicílio: endereço 422 address_from_household, raça/cor grava" do
    registry_registration!(patient: patient) # raça/cor 01 e o endereço do domicílio no paciente
    sign_in_as(clerk)
    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "03", address_street: "Rua XV de Novembro"
    expect(response).to have_http_status(:unprocessable_entity)
    expect(json_body).to eq("error" => "address_from_household", "field" => "address_street")
    expect(patient.reload).to have_attributes(race_color: "01", address_street: "das Flores")
    json_patch "/billing/patients/#{patient.id}/demographics", race_color: "03"
    expect(response).to have_http_status(:ok)
    expect(json_body).to include("race_color_set" => true, "address_from_household" => true)
  end
end
