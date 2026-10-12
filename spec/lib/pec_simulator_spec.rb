require "rails_helper"
require Rails.root.join("lib/pec_simulator").to_s

# O simulador monta a URL como o PEC (docs/pesquisa/2026-10-11-pec-sistemas-externos.md):
# a assinatura que ele gera é a que a página aceita.
RSpec.describe PecSimulator do
  let(:city) { timeline_city!(record_mode: "integrated", clinical_record: false, pec: true) }

  it "assina a URL inteira até o pec_timestamp, com a chave da cidade" do
    pec_settings!(key: "dev-pec-hmac-key-teste-0123456789")
    at = Time.zone.at(1_791_720_000)
    url = described_class.signed_url(city: city, professional: "529.982.247-25", citizen: "111.444.777-35", cnes: "1234567",
                                     at: at, base: "http://maringa.localhost:3040")
    expect(url).to start_with("http://maringa.localhost:3040/pec/timeline?documento-profissional=52998224725" \
                              "&documento-cidadao=11144477735&cnes=1234567&pec_timestamp=1791720000&pec_sign=")
    expect(PecExternal::Signature.verify(url: url, key: "dev-pec-hmac-key-teste-0123456789", timestamp: "1791720000", now: at))
      .to eq(:ok)
    without_citizen = described_class.signed_url(city: city, professional: "52998224725", citizen: "", cnes: "1234567", at: at)
    expect(without_citizen).not_to include("documento-cidadao")
  end

  it "a página tem o formulário e o iframe da URL" do
    html = described_class.page(city: city, form: { professional: "1", citizen: "2", cnes: "3", minutes_ago: "0" },
                                url: "http://x.localhost/pec/timeline?a=1&pec_sign=f")
    expect(html).to include("<form", %(<iframe src="http://x.localhost/pec/timeline?a=1&amp;pec_sign=f"))
  end

  it "defaults: a cidadã da semente é o par validado com atendimento na unidade da enfermeira, não o mais antigo" do
    city
    unit = create_unit("UBS Semente").tap { |u| u.update!(cnes: "7654321") }
    screener!(unit).update!(email_address: "enfermeira@#{city.slug}.demo")
    verified_citizen!(171).update_columns(created_at: 1.year.ago) # validado antigo, sem histórico
    seeded = verified_citizen!(172)
    walk_in_attendance!(unit, citizen: seeded)
    walk_in_attendance!(create_unit("UBS Outra"), citizen: verified_citizen!(173))

    expect(described_class.defaults(city)).to include(citizen: seeded.cpf, cnes: "7654321")
  end

  it "defaults: sem atendimento na unidade, cai no validado mais antigo" do
    city
    oldest = verified_citizen!(174).tap { |c| c.update_columns(created_at: 1.year.ago) }
    verified_citizen!(175)
    expect(described_class.defaults(city)[:citizen]).to eq(oldest.cpf)
  end
end
