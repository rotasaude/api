require "rails_helper"

RSpec.describe "Rascunho da campanha" do
  let(:manager) { staff_with("campanhas@cidade.gov.br", "campaign_manager") }
  let(:valid) do
    { "title" => "  Vacinação contra a gripe ", "body" => "Procure a unidade.\nLeve a carteirinha.  ",
      "audience" => city_audience }
  end

  describe Campaigns::Create do
    it "cria draft com pontas aparadas, quebra de linha preservada e evento só com ids" do
      campaign = described_class.call(attrs: valid, by: manager).payload[:campaign]
      expect(campaign).to have_attributes(status: "draft", title: "Vacinação contra a gripe",
                                          body: "Procure a unidade.\nLeve a carteirinha.",
                                          created_by_user_id: manager.id, audience: city_audience)
      expect(DomainEvent.where(name: "campaign.created").order(:occurred_at).map(&:payload))
        .to eq([ { "campaign_id" => campaign.id, "by_user_id" => manager.id } ])
    end

    it "título e texto: faltando, curto, longo, não texto ou com HTML → invalid_campaign com o caminho" do
      {
        valid.except("title") => [ "/title", "required" ],
        valid.merge("title" => "ab") => [ "/title", "length" ],
        valid.merge("title" => "x" * 121) => [ "/title", "length" ],
        valid.merge("title" => [ "Gripe" ]) => [ "/title", "not_a_string" ],
        valid.merge("body" => "curto") => [ "/body", "length" ],
        valid.merge("body" => "x" * 2001) => [ "/body", "length" ],
        valid.merge("body" => "Veja <a href='x'>aqui</a> o aviso") => [ "/body", "html_not_allowed" ]
      }.each do |attrs, (path, message)|
        result = described_class.call(attrs: attrs, by: manager)
        expect([ result.reason, result.details ]).to eq([ :invalid_campaign, { details: [ { path: path, message: message } ] } ]), attrs.inspect
      end
      expect(Campaign.count).to eq(0)
    end

    it "texto com '<' que não abre tag passa (ex.: 'idade < 60', 'idade < a')" do
      [ "Pessoas com idade < 60 anos", "Pessoas com idade < a média" ].each do |body|
        expect(described_class.call(attrs: valid.merge("body" => body), by: manager)).to be_ok, body
      end
    end

    it "público ausente ou inválido → invalid_audience com o caminho; nada criado" do
      result = described_class.call(attrs: valid.except("audience"), by: manager)
      expect([ result.reason, result.details ]).to eq([ :invalid_audience, { details: [ { path: "/", message: "not_an_object" } ] } ])
      result = described_class.call(attrs: valid.merge("audience" => city_audience.merge("version" => 2)), by: manager)
      expect(result.details).to eq(details: [ { path: "/version", message: "must_be_1" } ])
      expect(Campaign.count).to eq(0)
    end

    it "chaves de símbolo no público são gravadas como texto" do
      attrs = valid.merge("audience" => { version: 1, geo: { scope: "city" }, clinical: { all: [] } })
      expect(described_class.call(attrs: attrs, by: manager).payload[:campaign].audience).to eq(city_audience)
    end
  end

  describe Campaigns::Update do
    let(:campaign) { draft_campaign!(by: manager) }

    it "muda só as chaves presentes" do
      result = described_class.call(campaign: campaign, attrs: { "body" => "Novo texto do aviso." })
      expect(result).to be_ok
      expect(campaign.reload).to have_attributes(title: "Vacinação contra a gripe", body: "Novo texto do aviso.")
    end

    it "recusa conteúdo e público inválidos sem mudar nada" do
      expect(described_class.call(campaign: campaign, attrs: { "title" => "" }).reason).to eq(:invalid_campaign)
      expect(described_class.call(campaign: campaign, attrs: { "audience" => "cidade" }).reason).to eq(:invalid_audience)
      expect(campaign.reload.title).to eq("Vacinação contra a gripe")
    end

    it "fora de draft: not_editable" do
      sent = sent_campaign!(by: manager)
      expect(described_class.call(campaign: sent, attrs: { "title" => "Outro título" }).reason).to eq(:not_editable)
    end
  end
end
