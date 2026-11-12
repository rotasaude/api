require "rails_helper"

# Módulo 33, Task 9 (ADR 0051; contrato §4; §16 Q21): o e-mail do teto da
# denúncia anônima vai a cada `ombudsman` ativo, só com a contagem do dia —
# nunca protocolo, texto, unidade nem id. Um envio por dia.
RSpec.describe "Ombudsman::MailJob" do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ombudsman_city!(anonymous: true)
    travel_to Time.zone.local(2026, 11, 11, 15, 0)
  end
  after do
    travel_back
    Current.reset
  end

  let!(:ombudsmen) do
    [ staff_with("ouvidora-um@cidade.gov.br", "ombudsman"), staff_with("ouvidor-dois@cidade.gov.br", "ombudsman") ]
  end

  def deliver!(ref = Time.zone.today.iso8601) = Ombudsman::MailJob.perform_now(city_slug: Current.city.slug, kind: "anonymous_cap", ref: ref)
  def deliveries = ActionMailer::Base.deliveries
  def full_text(mail) = [ mail.subject, mail.text_part.body.decoded, mail.html_part.body.decoded ].join("\n")
  def anonymous!(**attrs) = raw_manifestation!(kind: "report", identification_mode: "anonymous", **attrs)

  it "entrega a cada ombudsman ativo só a contagem do dia, sem protocolo nem texto" do
    gone = staff_with("ouvidor-saiu@cidade.gov.br", "ombudsman")
    gone.update!(deactivated_at: Time.current)
    revoked = staff_with("ouvidor-revogado@cidade.gov.br", "ombudsman")
    Membership.where(user: revoked).update_all(revoked_at: Time.current)
    staff_with("tecnico@cidade.gov.br", "ombudsman_staff")
    staff_with("respondente@cidade.gov.br", "ombudsman_responder")
    unit = create_unit("UBS Sigilosa")
    reports = [ anonymous!(referred_health_unit_id: unit.id), anonymous!, anonymous! ]
    anonymous!(received_at: 1.day.ago)                                    # ontem: fora
    raw_manifestation!(citizen: web_citizen!, kind: "report")             # identificada: fora
    deliveries.clear

    deliver!

    expect(deliveries.map(&:to)).to contain_exactly([ "ouvidora-um@cidade.gov.br" ], [ "ouvidor-dois@cidade.gov.br" ])
    mail = deliveries.last
    expect(mail.subject).to eq("[rota-saúde] Teto diário da denúncia anônima atingido")
    text = full_text(mail)
    expect(text).to include("Denúncias anônimas recebidas em 11/11/2026: 3", "painel da cidade")
    forbidden = reports.flat_map { |r| [ r.protocol, r.id ] } + [ OmbudsmanHelpers::BODY, "UBS Sigilosa", unit.id, "http" ]
    forbidden.each { |value| expect(text).not_to include(value) }
  end

  it "duas execuções no mesmo dia → um envio por destinatário" do
    anonymous!
    deliveries.clear

    deliver!
    deliver!

    expect(deliveries.size).to eq(2)
    expect(ProcessedEvent.where(consumer: "ombudsman_mail", event_id: "anonymous_cap:2026-11-11").count).to eq(1)
  end

  # Fix round 1: a rodada sem nada a dizer não gasta o dedup do dia.
  it "contagem zero: não envia e não consome o dia; a rodada seguinte com contagem envia" do
    deliveries.clear

    deliver!
    expect(deliveries).to be_empty
    expect(ProcessedEvent.where(consumer: "ombudsman_mail")).to be_empty

    anonymous!
    deliver!
    expect(deliveries.size).to eq(2)
    expect(ProcessedEvent.where(consumer: "ombudsman_mail", event_id: "anonymous_cap:2026-11-11").count).to eq(1)
  end

  it "conta o dia da referência, não o de hoje" do
    2.times { anonymous!(received_at: 1.day.ago) }
    anonymous!
    deliveries.clear

    deliver!("2026-11-10")

    expect(full_text(deliveries.last)).to include("Denúncias anônimas recebidas em 10/11/2026: 2")
  end

  it "sem ombudsman ativo: nada a entregar, sem erro" do
    Membership.where(user: ombudsmen).update_all(revoked_at: Time.current)
    anonymous!
    deliveries.clear

    expect { deliver! }.not_to raise_error
    expect(deliveries).to be_empty
  end

  it "kind ou ref inválidos levantam" do
    expect { Ombudsman::MailJob.perform_now(city_slug: Current.city.slug, kind: "other", ref: "2026-11-11") }
      .to raise_error(ArgumentError)
    expect { deliver!("ontem") }.to raise_error(Date::Error)
  end
end
