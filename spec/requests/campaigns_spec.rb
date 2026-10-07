# spec/requests/campaigns_spec.rb
require "rails_helper"

RSpec.describe "Campanhas — rascunho e prévia", type: :request do
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  let(:manager) { staff_with("campanhas@cidade.gov.br", "campaign_manager") }
  let(:valid) do
    { title: "Vacinação contra a gripe", body: "A campanha começa na segunda-feira.", audience: city_audience }
  end

  describe "com campaign_manager" do
    before { sign_in_as(manager) }

    it "cria, edita, lê e lista (mais nova primeiro), sem lista de destinatários" do
      json_post "/campaigns", valid
      expect(response).to have_http_status(:created)
      id = body.dig("campaign", "id")
      expect(body["campaign"].keys).to match_array(%w[id title status send_at dispatched_at recipients_count body audience
                                                      failure_reason sms_enabled phones_count created_at stats])
      expect(body["campaign"]).to include("status" => "draft", "send_at" => nil, "stats" => nil, "audience" => city_audience)

      patch "/campaigns/#{id}", params: { title: "Gripe: vacinação" }, as: :json
      expect(response).to have_http_status(:ok)
      expect(body.dig("campaign", "title")).to eq("Gripe: vacinação")

      older = draft_campaign!(by: manager)
      older.update_columns(created_at: 1.day.ago)
      get "/campaigns"
      expect(body["campaigns"].map { |c| c["id"] }).to eq([ id, older.id ])
      expect(body["campaigns"].first.keys).to match_array(%w[id title status send_at dispatched_at recipients_count])

      get "/campaigns/#{id}"
      expect(body.dig("campaign", "body")).to eq("A campanha começa na segunda-feira.")
    end

    it "prévia: contagens com 5 telefones ou mais; menos de 5 sem números" do
      4.times { person! }
      json_post "/campaigns/preview", audience: city_audience
      expect(body).to eq("below_minimum" => true)
      person!
      json_post "/campaigns/preview", audience: city_audience
      expect(body).to eq("citizens" => 5, "phones" => 5)
    end

    it "público malformado: 422 invalid_audience com o caminho, nunca 500, nada gravado" do
      bad = [
        [ city_audience.merge("geo" => { "scope" => "neighborhoods", "neighborhood_ids" => "Centro" }), "/geo/neighborhood_ids" ],
        [ city_audience.merge("geo" => { "scope" => "unit", "health_unit_id" => "ubs-1" }), "/geo/health_unit_id" ],
        [ city_audience({ "kind" => "appointment_no_show", "from" => "2026-02-30", "to" => Time.zone.today.iso8601 }),
          "/clinical/all/0/from" ],
        [ city_audience({ "from" => Time.zone.today.iso8601 }), "/clinical/all/0/kind" ],
        [ "cidade toda", "/" ]
      ]
      bad.each do |audience, path|
        json_post "/campaigns/preview", audience: audience
        expect(status_and_error).to eq([ 422, "invalid_audience" ]), path
        expect(body["details"].map { |d| d["path"] }).to eq([ path ])
        json_post "/campaigns", valid.merge(audience: audience)
        expect(status_and_error).to eq([ 422, "invalid_audience" ]), path
      end
      expect(Campaign.count).to eq(0)
    end

    it "bairro desativado depois do rascunho: prévia e edição recusam com o caminho do item" do
      centro = Neighborhood.create!(name: "Centro", source: "seed")
      audience = { "version" => 1, "geo" => { "scope" => "neighborhoods", "neighborhood_ids" => [ centro.id ] },
                   "clinical" => { "all" => [] } }
      json_post "/campaigns", valid.merge(audience: audience)
      id = body.dig("campaign", "id")
      centro.update!(active: false)

      json_post "/campaigns/preview", audience: audience
      expect(body).to eq("error" => "invalid_audience",
                         "details" => [ { "path" => "/geo/neighborhood_ids/0", "message" => "inactive_or_unknown" } ])
      patch "/campaigns/#{id}", params: { audience: audience }, as: :json
      expect(status_and_error).to eq([ 422, "invalid_audience" ])
    end

    it "título ou texto inválido: 422 invalid_campaign com o caminho" do
      json_post "/campaigns", valid.merge(title: "ab")
      expect(body).to eq("error" => "invalid_campaign", "details" => [ { "path" => "/title", "message" => "length" } ])
    end

    it "editar fora de draft: 422 not_editable" do
      sent = sent_campaign!(by: manager)
      patch "/campaigns/#{sent.id}", params: { title: "Outro título" }, as: :json
      expect(status_and_error).to eq([ 422, "not_editable" ])
    end

    it "campanha inexistente ou id que não é UUID: 404 not_found" do
      [ SecureRandom.uuid, "nao-e-uuid" ].each do |id|
        get "/campaigns/#{id}"
        expect(status_and_error).to eq([ 404, "not_found" ])
      end
    end

    it "opções: protocolos e faixas de triagens concluídas, desfechos, bairros e unidades ativos" do
      create_default_protocol!
      CampaignHistory.triage!(person!, tier: "alta", at: 2.days.ago)
      CampaignHistory.triage!(person!, protocol_name: "dengue", tier: "baixa", at: 2.days.ago)
      CampaignHistory.triage!(person!, protocol_name: "abandonado", status: "aborted_by_timeout", at: 2.days.ago)
      centro = Neighborhood.create!(name: "Centro", source: "seed")
      Neighborhood.create!(name: "Ahu", source: "seed", active: false)
      ubs = create_unit("UBS Centro")
      create_unit("UBS Antiga", active: false)

      get "/campaigns/options"
      expect(body).to eq(
        "protocols" => %w[dengue triage-respiratoria], "tiers" => %w[alta baixa],
        "outcomes" => %w[discharged referred return left scheduled_from_screening oriented],
        "neighborhoods" => [ { "id" => centro.id, "name" => "Centro" } ],
        "units" => [ { "id" => ubs.id, "name" => "UBS Centro" } ]
      )
    end
  end

  describe "só o campaign_manager" do
    (Membership::ROLES - %w[campaign_manager]).each do |role|
      it "#{role}: 403 missing_role em todas, nada muda" do
        campaign = draft_campaign!
        sign_in_as(staff_with("#{role}@cidade.gov.br", role))
        get "/campaigns"
        expect(status_and_error).to eq([ 403, "missing_role" ])
        get "/campaigns/options"
        expect(status_and_error).to eq([ 403, "missing_role" ])
        get "/campaigns/#{campaign.id}"
        expect(status_and_error).to eq([ 403, "missing_role" ])
        json_post "/campaigns/preview", audience: city_audience
        expect(status_and_error).to eq([ 403, "missing_role" ])
        json_post "/campaigns", valid
        expect(status_and_error).to eq([ 403, "missing_role" ])
        patch "/campaigns/#{campaign.id}", params: { title: "Outro título" }, as: :json
        expect(status_and_error).to eq([ 403, "missing_role" ])
        expect(Campaign.count).to eq(1)
      end
    end

    it "sem sessão: 401" do
      get "/campaigns"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
