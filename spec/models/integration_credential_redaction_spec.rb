require "rails_helper"

# Módulo 26c (§9; Task 16, Minor 1): o `as_json` padrão do ActiveRecord decifra e
# devolve `secret`; o de IntegrationCredential só leva id, kind e environment. O
# inspect, o to_s e o pretty_print também não trazem valor do segredo, em todo kind.
RSpec.describe IntegrationCredential, type: :model do
  let!(:city) { vaccination_city! }
  let(:admin) { pharmacy_admin! }
  let(:pfx_b64) { Base64.strict_encode64(self_signed_pfx(password: "SenhaPfxRedacaoQuartzo", not_after: 1.year.from_now)) }
  let(:secrets) do
    login = ->(tag) { { "username" => "usuario-#{tag}-redacao", "password" => "senha-#{tag}-redacao" } }
    pfx = { "pfx_base64" => pfx_b64, "pfx_password" => "SenhaPfxRedacaoQuartzo", "requester_cnes" => "7290415" }
    { "ledi" => login.call("ledi"), "cadsus" => login.call("cadsus"), "bnafar" => login.call("bnafar"), "rnds" => pfx,
      "rnds_regulation" => pfx.merge("requester_id" => "61840372915", "responsible_cns" => valid_cns(77)) }
  end

  it "cobre todos os kinds" do
    expect(secrets.keys).to match_array(described_class::KINDS)
  end

  described_class::KINDS.each do |kind|
    it "#{kind}: as_json, to_json, to_s, inspect e pretty_print sem nenhum valor do segredo" do
      credential = described_class.create!(kind: kind, secret: secrets.fetch(kind), set_by_user: admin, set_at: Time.current)
      credential.reload
      expect(credential.secret).to eq(secrets.fetch(kind)) # controle: o segredo está lá, decifrado

      expect(credential.as_json).to eq("id" => credential.id, "kind" => kind, "environment" => credential.environment)
      texts = [ credential.to_json, [ credential ].to_json, { credential: credential }.to_json, credential.to_s, credential.inspect,
                credential.pretty_inspect, "#{credential}" ]
      texts.each do |text|
        expect(text).not_to include("secret")
        secrets.fetch(kind).each_value { |value| expect(text).not_to include(value[0, 40]) }
      end
      expect(credential.pretty_inspect.strip).to eq(credential.inspect)
    end
  end
end
