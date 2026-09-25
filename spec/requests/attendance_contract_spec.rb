require "rails_helper"

# ADR 0018 invariant (spec §8.1): check-in, exceção e encerramento só
# acrescentam ao módulo de atendimento; nunca tocam as tabelas de triagem já
# gravadas (report/dashboard já publicados) nem os registros de consentimento.
# citizens/citizen_verifications MUDAM de propósito (document_checked grava a
# validação) e ficam de fora, de propósito.
RSpec.describe "Attendance contract: triages/consents/reports/metrics untouched", type: :request do
  before { Current.city = TEST_CITY_A; Rails.cache.clear }
  after { Current.reset }

  let(:verifier) { user_with("atendente@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { user_with("medica@cidade.gov.br", "health_professional") }
  let(:unit) { create_unit }

  def user_with(email, role)
    User.create!(email_address: email, password: "senha-segura-123").tap do |u|
      Membership.create!(user: u, role: role, granted_at: Time.current)
    end
  end

  def check_in_code_for(citizen, triage)
    Citizens::IssueCheckInCode.call(citizen: citizen, triage: triage).payload.fetch(:code)
  end

  def snapshot
    {
      triages: Triage.order(:id).map { |t| t.attributes.except("id") },
      consents: Consent.order(:id).map { |c| c.attributes.except("id") },
      report_snapshots: ReportSnapshot.order(:id).map { |r| r.attributes.except("id") },
      dashboard_metrics: DashboardMetric.order(:id).map { |m| m.attributes.except("id") }
    }
  end

  it "check-in por código com document_checked: true não altera triagens/consentimentos/relatórios/métricas" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(citizen, triage)
    sign_in_as(verifier)

    before = snapshot
    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id, document_checked: true
    expect(response).to have_http_status(:created)

    expect(snapshot).to eq(before)
  end

  it "check-in por exceção não altera triagens/consentimentos/relatórios/métricas" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    sign_in_as(verifier)

    before = snapshot
    json_post "/attendance/check_ins/exception", cpf: citizen.cpf, triage_id: triage.id, health_unit_id: unit.id,
                                                 reason: "cidadão sem celular no momento"
    expect(response).to have_http_status(:created)

    expect(snapshot).to eq(before)
  end

  it "encerrar (referido) não altera triagens/consentimentos/relatórios/métricas" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    triage = completed_web_triage_for(citizen)
    code = check_in_code_for(citizen, triage)
    sign_in_as(verifier)
    json_post "/attendance/check_ins", cpf: citizen.cpf, code: code, health_unit_id: unit.id
    expect(response).to have_http_status(:created)
    attendance_id = JSON.parse(response.body).dig("attendance", "id")
    referral_unit = create_unit("UBS Referência")

    sign_in_as(doctor)
    json_post "/attendance/attendances/#{attendance_id}/call", health_unit_id: unit.id
    expect(response).to have_http_status(:ok)

    before = snapshot
    json_post "/attendance/attendances/#{attendance_id}/close", outcome: "referred", referral_unit_id: referral_unit.id
    expect(response).to have_http_status(:ok)

    expect(snapshot).to eq(before)
  end
end
