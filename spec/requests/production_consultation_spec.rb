require "rails_helper"

# Contratos §6: correction_pending aparece na Produção e não conta como
# pendente; "não geradas" e "gerar de novo" valem para a consulta; recusada de
# consulta é regerada da origem.
RSpec.describe "Produção — fichas da consulta", type: :request do
  let(:city) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) do
    staff_with("prod-adm@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  def body = JSON.parse(response.body)

  before do
    clinical_city!
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  it "correction_pending na lista, fora da contagem de pendentes" do
    exportable_unit!(unit, doctor)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Current.set(city: city) { Ledi::ConsultationFicha.generate(consultation) }
    accepted = LediOutboxEntry.sole.tap(&:accept!)
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "conduta acrescentada", text: "x",
                                    changes: { "conducts" => [ 1, 9 ] })
    Current.set(city: city) { Ledi::ConsultationFicha.refresh!(consultation.reload) }
    sign_in_as(admin)
    get "/production", params: { competence: accepted.competence }
    expect(body["fichas"].map { |f| f["status"] }).to match_array(%w[accepted correction_pending])
    expect(body["counts"]).to include("pending" => 0, "accepted" => 1)
  end

  it "não gerada da consulta lista o atendimento; gerar de novo resolve; recusada é regerada" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Current.set(city: city) { Ledi::ConsultationFicha.generate(consultation) }
    sign_in_as(admin).update!(mfa_verified_at: Time.current)
    get "/production/generation_failures"
    item = body["items"].sole
    expect(item.values_at("source_type", "source_id", "attendance_id")).to eq([ "Consultation", consultation.id, consultation.attendance_id ])
    exportable_unit!(unit, doctor)
    json_post "/production/generation_failures/#{item['id']}/retry"
    expect(body["resolved_at"]).to be_present
    entry = LediOutboxEntry.sole
    entry.reject!([ { "field" => "cpfCidadao", "code" => "invalid" } ])
    json_post "/production/fichas/#{entry.id}/resend"
    expect(response).to have_http_status(:ok)
    expect(body.values_at("status", "replaces_outbox_id")).to eq([ "pending", entry.id ])
  end
end
