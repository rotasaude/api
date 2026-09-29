require "rails_helper"

RSpec.describe "Transições da campanha", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:manager) do
    staff_with("campanhas@cidade.gov.br", "campaign_manager").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:campaign) { draft_campaign!(by: manager) }

  def sign_in!(stepped_up: true)
    session = sign_in_as(manager)
    session.update!(mfa_verified_at: Time.current) if stepped_up
  end

  def payloads(name) = DomainEvent.where(name: name).order(:occurred_at, :id).map(&:payload)

  before { 5.times { person! } }

  it "enviar: draft → sending, quem enviou gravado e o DispatchJob na fila" do
    sign_in!
    expect { json_post "/campaigns/#{campaign.id}/send" }
      .to have_enqueued_job(Campaigns::DispatchJob).with(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id)
    expect(response).to have_http_status(:ok)
    expect(body.dig("campaign", "status")).to eq("sending")
    expect(campaign.reload.dispatched_by_user_id).to eq(manager.id)

    json_post "/campaigns/#{campaign.id}/send"
    expect(status_and_error).to eq([ 422, "invalid_transition" ])
  end

  it "sem escrita JSON: 415 json_required antes de tudo" do
    sign_in!
    post "/campaigns/#{campaign.id}/send"
    expect(status_and_error).to eq([ 415, "json_required" ])
  end

  it "sem step-up: 401 mfa_required em enviar, agendar, desagendar e cancelar; nada muda" do
    sign_in!(stepped_up: false)
    %w[send schedule unschedule cancel].each do |action|
      json_post "/campaigns/#{campaign.id}/#{action}", send_at: 1.day.from_now.iso8601
      expect(status_and_error).to eq([ 401, "mfa_required" ]), action
    end
    expect(campaign.reload.status).to eq("draft")
  end

  it "menos de 5 telefones no envio ou no agendamento: 422 below_minimum e segue draft" do
    sign_in!
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    small = draft_campaign!(by: manager, audience: { "version" => 1, "clinical" => { "all" => [] },
                                                     "geo" => { "scope" => "neighborhoods", "neighborhood_ids" => [ centro.id ] } })
    json_post "/campaigns/#{small.id}/send"
    expect(status_and_error).to eq([ 422, "below_minimum" ])
    json_post "/campaigns/#{small.id}/schedule", send_at: 1.day.from_now.iso8601
    expect(status_and_error).to eq([ 422, "below_minimum" ])
    expect(small.reload.status).to eq("draft")
  end

  it "bairro desativado depois do rascunho: enviar recusa com invalid_audience" do
    sign_in!
    centro = Neighborhood.create!(name: "Centro", source: "seed")
    5.times { person!(neighborhood: centro) }
    draft = draft_campaign!(by: manager, audience: { "version" => 1, "clinical" => { "all" => [] },
                                                     "geo" => { "scope" => "neighborhoods", "neighborhood_ids" => [ centro.id ] } })
    centro.update!(active: false)
    json_post "/campaigns/#{draft.id}/send"
    expect(body).to eq("error" => "invalid_audience",
                       "details" => [ { "path" => "/geo/neighborhood_ids/0", "message" => "inactive_or_unknown" } ])
  end

  it "agendar: de 5 minutos a 90 dias; fora disso ou malformado, invalid_send_at" do
    sign_in!
    [ 4.minutes.from_now.iso8601, 91.days.from_now.iso8601, "amanhã", nil, 12_345 ].each do |send_at|
      json_post "/campaigns/#{campaign.id}/schedule", send_at: send_at
      expect(status_and_error).to eq([ 422, "invalid_send_at" ]), send_at.inspect
    end
    at = 1.day.from_now.change(usec: 0)
    json_post "/campaigns/#{campaign.id}/schedule", send_at: at.iso8601
    expect(body["campaign"]).to include("status" => "scheduled", "send_at" => at.iso8601)
    expect(payloads("campaign.scheduled"))
      .to eq([ { "campaign_id" => campaign.id, "send_at" => at.iso8601, "by_user_id" => manager.id } ])
  end

  it "desagendar volta a draft sem horário; em draft é invalid_transition" do
    sign_in!
    json_post "/campaigns/#{campaign.id}/unschedule"
    expect(status_and_error).to eq([ 422, "invalid_transition" ])
    json_post "/campaigns/#{campaign.id}/schedule", send_at: 1.day.from_now.iso8601
    json_post "/campaigns/#{campaign.id}/unschedule"
    expect(body["campaign"]).to include("status" => "draft", "send_at" => nil)
    expect(campaign.reload.dispatched_by_user_id).to be_nil
    expect(payloads("campaign.unscheduled")).to eq([ { "campaign_id" => campaign.id, "by_user_id" => manager.id } ])
  end

  it "cancelar de draft ou de scheduled; em sending ou sent é invalid_transition" do
    sign_in!
    json_post "/campaigns/#{campaign.id}/cancel"
    expect(body.dig("campaign", "status")).to eq("cancelled")

    scheduled = draft_campaign!(by: manager)
    json_post "/campaigns/#{scheduled.id}/schedule", send_at: 1.day.from_now.iso8601
    json_post "/campaigns/#{scheduled.id}/cancel"
    expect(body.dig("campaign", "status")).to eq("cancelled")
    expect(payloads("campaign.cancelled").map { |p| p["from_status"] }).to eq(%w[draft scheduled])

    sending = draft_campaign!(by: manager)
    sending.update_columns(status: "sending", dispatched_by_user_id: manager.id)
    json_post "/campaigns/#{sending.id}/cancel"
    expect(status_and_error).to eq([ 422, "invalid_transition" ])
    json_post "/campaigns/#{sent_campaign!(by: manager).id}/cancel"
    expect(status_and_error).to eq([ 422, "invalid_transition" ])
  end

  it "papel e 404 vêm antes do step-up" do
    sign_in_as(staff_with("admin@cidade.gov.br", "municipal_admin")).update!(mfa_verified_at: Time.current)
    json_post "/campaigns/#{campaign.id}/send"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    sign_in!(stepped_up: false)
    json_post "/campaigns/#{SecureRandom.uuid}/send"
    expect(status_and_error).to eq([ 404, "not_found" ])
  end
end
