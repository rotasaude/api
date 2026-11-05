require "rails_helper"

# Módulo 31, P59 (decisão 4): CAPS nunca é público de campanha. Uma campanha
# "CAPS X" mandaria aviso ou SMS a quem tem vínculo com o CAPS e revelaria o
# vínculo. As opções não listam o CAPS; salvar, prever e enviar recusam com
# caps_unit_not_allowed; e uma campanha gravada antes da regra não alcança
# ninguém pelo CAPS (recusa no envio e, se o disparo rodar, público vazio).
RSpec.describe "Campanhas — CAPS fora do público", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:manager) do
    staff_with("campanhas@cidade.gov.br", "campaign_manager").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  let(:caps) do
    HealthUnit.create!(name: "CAPS AD III Centro Vida", kind: "caps", caps_modality: "caps_ad_iii", service_classification: "001",
                       cnes: "7654321")
  end
  let(:ubs) { create_unit("UBS Centro") }
  let(:valid) { { title: "Vacinação contra a gripe", body: "A campanha começa na segunda-feira." } }

  def unit_geo(id) = { "version" => 1, "geo" => { "scope" => "unit", "health_unit_id" => id }, "clinical" => { "all" => [] } }

  def criterion_audience(criterion)
    city_audience(criterion)
  end

  def outcome_criterion(unit_id)
    { "kind" => "attendance_outcome", "outcomes" => %w[discharged], "from" => 30.days.ago.to_date.iso8601,
      "to" => Date.current.iso8601, "health_unit_id" => unit_id }
  end

  def request_criterion(unit_id) = { "kind" => "appointment_request_open", "target_unit_id" => unit_id }

  before { sign_in_as(manager).update!(mfa_verified_at: Time.current) }

  it "opções: a lista de unidades não traz o CAPS e segue com id e nome apenas" do
    caps
    ubs
    get "/campaigns/options"
    expect(body["units"]).to eq([ { "id" => ubs.id, "name" => "UBS Centro" } ])
  end

  describe "salvar ou prever público com CAPS" do
    {
      "recorte por unidade" => [ ->(id) { { "version" => 1, "geo" => { "scope" => "unit", "health_unit_id" => id },
                                            "clinical" => { "all" => [] } } }, "/geo/health_unit_id" ],
      "desfecho de atendimento na unidade" => [ ->(id) { { "version" => 1, "geo" => { "scope" => "city" },
                                                            "clinical" => { "all" => [ { "kind" => "attendance_outcome",
                                                                                         "outcomes" => %w[discharged],
                                                                                         "from" => "2026-01-01", "to" => "2026-02-01",
                                                                                         "health_unit_id" => id } ] } } },
                                                "/clinical/all/0/health_unit_id" ],
      "pedido aberto com destino na unidade" => [ ->(id) { { "version" => 1, "geo" => { "scope" => "city" },
                                                              "clinical" => { "all" => [ { "kind" => "appointment_request_open",
                                                                                           "target_unit_id" => id } ] } } },
                                                  "/clinical/all/0/target_unit_id" ]
    }.each do |label, (build, path)|
      it "#{label}: 422 caps_unit_not_allowed com o caminho, em prévia, criação e edição" do
        audience = build.call(caps.id)

        json_post "/campaigns/preview", audience: audience
        expect(status_and_error).to eq([ 422, "caps_unit_not_allowed" ])
        expect(body["path"]).to eq(path)
        expect(body["details"]).to eq([ { "path" => path, "message" => "caps_unit_not_allowed" } ])

        json_post "/campaigns", valid.merge(audience: audience)
        expect(status_and_error).to eq([ 422, "caps_unit_not_allowed" ])
        expect(body["path"]).to eq(path)
        expect(Campaign.count).to eq(0)

        draft = draft_campaign!(by: manager)
        patch "/campaigns/#{draft.id}", params: { audience: audience }, as: :json
        expect(status_and_error).to eq([ 422, "caps_unit_not_allowed" ])
        expect(draft.reload.audience).to eq(city_audience)
      end
    end

    it "unidade que não é CAPS segue aceita nos três lugares" do
      [ unit_geo(ubs.id), criterion_audience(outcome_criterion(ubs.id)), criterion_audience(request_criterion(ubs.id)) ].each do |audience|
        json_post "/campaigns/preview", audience: audience
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "campanha gravada antes da regra, com CAPS no público" do
    let(:centro) { Neighborhood.create!(name: "Centro", source: "seed") }
    let!(:caps_people) do
      NeighborhoodCoverage.create!(neighborhood: centro, health_unit: caps)
      Array.new(5) { person!(neighborhood: centro) }
    end

    def legacy_campaign!(audience)
      draft_campaign!(by: manager, audience: audience)
    end

    it "o cálculo do público por unidade CAPS não traz ninguém" do
      expect(Campaigns::Audience.new(unit_geo(caps.id)).citizen_ids).to be_empty
    end

    it "critério com unidade CAPS não traz ninguém, em desfecho e em pedido aberto" do
      create_default_protocol!
      people = Array.new(5) { person! }
      control = person!
      CampaignHistory.attendance!(control, outcome: "discharged", at: 2.days.ago, unit: ubs, by: staff!)
      people.each do |citizen|
        CampaignHistory.attendance!(citizen, outcome: "discharged", at: 2.days.ago, unit: caps, by: staff!)
        CampaignHistory.request!(citizen, unit: caps, by: staff!)
      end

      [ outcome_criterion(caps.id), request_criterion(caps.id) ].each do |criterion|
        expect(Campaigns::Audience.new(criterion_audience(criterion)).citizen_ids).to be_empty
      end
      expect(Campaigns::Audience.new(criterion_audience(outcome_criterion(ubs.id))).citizen_ids.pluck(:id)).to contain_exactly(control.id)
    end

    it "enviar recusa com 422 caps_unit_not_allowed e a campanha continua rascunho" do
      campaign = legacy_campaign!(unit_geo(caps.id))
      expect { json_post "/campaigns/#{campaign.id}/send" }.not_to have_enqueued_job(Campaigns::DispatchJob)
      expect(status_and_error).to eq([ 422, "caps_unit_not_allowed" ])
      expect(body["path"]).to eq("/geo/health_unit_id")
      expect(campaign.reload.status).to eq("draft")
    end

    it "se o disparo rodar mesmo assim, nenhum destinatário do CAPS é congelado" do
      sms_profile!(enabled: true)
      caps_people.each { |p| opt_in!(p) }
      campaign = legacy_campaign!(unit_geo(caps.id))
      campaign.update_columns(status: "sending", dispatched_by_user_id: manager.id)

      expect { Campaigns::DispatchJob.perform_now(city_slug: TEST_CITY_A.slug, campaign_id: campaign.id) }
        .not_to have_enqueued_job(Campaigns::SmsBatchJob)
      expect(CampaignRecipient.where(campaign_id: campaign.id)).to be_empty
      expect(campaign.reload).to have_attributes(status: "failed", failure_reason: "below_minimum")
    end
  end
end
