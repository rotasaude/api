# spec/requests/signature_admin_spec.rb
require "rails_helper"

# Contrato §7 (spec §9, painel do admin; NGS2.02.05/06): quem tem certificado,
# quem vence em 30 dias, pendentes e o mais antigo, documentos por modo no
# período, assinaturas inválidas ou indeterminadas. Só leitura.
RSpec.describe "Painel de assinatura do admin", type: :request do
  before do
    signature_city!
    ciap2_release!; cid10_release!; sigtap_release!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  def body = JSON.parse(response.body)

  it "profissionais, documentos por modo e assinaturas inválidas" do
    expiring = signer_doctor!(create_unit("UBS Dois"), cpf: SignatureHelpers::OTHER_CPF)
    linked_certificate!(expiring, leaf: test_pki.issue(cpf: SignatureHelpers::OTHER_CPF, name: "VENCE LOGO", not_after: 10.days.from_now))
    without = doctor!(create_unit("UBS Tres"))

    # Antes do certificado: com ele ativo, o pedido nasceria na finalização (Task 20).
    signed = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    pending = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    manual = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(3))
    Consultations::AddAddendum.call(consultation: manual, by: doctor, reason: "adendo sem pedido", text: "x")
    certificate = linked_certificate!(doctor)
    signed_request = signature_request!(signed, author: doctor, status: "signed")
    pending_request = signature_request!(pending, author: doctor, reason_code: "no_session")
    signature_row!(signed_request, certificate: certificate)
      .update!(last_verification: "indeterminate", last_verification_at: Time.current, last_verification_reasons: [ "crl_unavailable" ])

    sign_in_as(ledi_admin!)
    get "/signature/admin/overview"
    expect(response).to have_http_status(:ok)
    rows = body["professionals"].index_by { |row| row["user_id"] }
    expect(rows[doctor.id]).to include("certificate_status" => "active", "pending_count" => 1,
                                       "oldest_pending_at" => pending_request.created_at.iso8601)
    expect(rows[expiring.id]).to include("certificate_status" => "expiring", "pending_count" => 0)
    expect(rows[without.id]).to include("certificate_status" => "none")
    expect(rows[without.id]).not_to have_key("not_after")
    expect(body["documents_by_mode"]).to eq("digital" => 1, "pending" => 1, "manual" => 2) # manual: 1 consulta + 1 adendo
    expect(body["invalid_or_indeterminate"].sole)
      .to include("document_type" => "consultation", "verification" => "indeterminate",
                  "signer_name" => doctor.professional.professional_name, "simulated" => false)
    expect(rows[doctor.id]["expires_in_days"]).to eq(certificate.expires_in_days)
    expect(rows[without.id]).not_to have_key("expires_in_days")
    expect(response.body).not_to include(SignatureHelpers::DOCTOR_CPF)
  end

  it "assinatura simulada vem marcada simulated: true" do
    certificate = linked_certificate!(doctor, provider: "simulated")
    request = signature_request!(finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)), author: doctor, status: "signed")
    signature_row!(request, certificate: certificate).update!(last_verification: "invalid")
    sign_in_as(ledi_admin!)
    get "/signature/admin/overview"
    expect(body["invalid_or_indeterminate"].sole).to include("simulated" => true, "verification" => "invalid")
  end

  it "fronteira do dia: o dia de `to` conta inteiro (até 23:59), o dia anterior não" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    day = consultation.finalized_at.in_time_zone.to_date
    sign_in_as(ledi_admin!)
    get "/signature/admin/overview", params: { from: day.iso8601, to: day.iso8601 }
    expect(body["documents_by_mode"]["manual"]).to eq(1)
    get "/signature/admin/overview", params: { from: (day - 5).iso8601, to: (day - 1).iso8601 }
    expect(body["documents_by_mode"]["manual"]).to eq(0)
    get "/signature/admin/overview", params: { from: (day + 1).iso8601, to: (day + 3).iso8601 }
    expect(body["documents_by_mode"]["manual"]).to eq(0)
  end

  it "período: fora dele não conta; data inválida 422; não admin 403; interruptor desligado 403" do
    finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    sign_in_as(ledi_admin!)
    get "/signature/admin/overview"
    expect(body["documents_by_mode"]["manual"]).to eq(1) # padrão: últimos 30 dias até hoje
    get "/signature/admin/overview", params: { from: (Time.zone.today - 60).iso8601, to: (Time.zone.today - 40).iso8601 }
    expect(body["documents_by_mode"]).to eq("digital" => 0, "pending" => 0, "manual" => 0)
    get "/signature/admin/overview", params: { from: Time.zone.tomorrow.iso8601 }
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_period" ]) # from > to (to = hoje)
    get "/signature/admin/overview", params: { from: "2026-13-01" }
    expect([ response.status, body["error"] ]).to eq([ 422, "invalid_period" ])
    sign_in_as(doctor)
    get "/signature/admin/overview"
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    signature_city!(enabled: false)
    sign_in_as(ledi_admin!)
    get "/signature/admin/overview"
    expect(body["error"]).to eq("feature_disabled")
  end
end
