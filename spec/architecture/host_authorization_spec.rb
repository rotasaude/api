require "rails_helper"
require Rails.root.join("lib/platform_hosts").to_s

# Spec §5 e Plano 8: fora de development o Host precisa casar com o domínio da
# plataforma. Lista VAZIA faz o Rails PULAR o middleware inteiro — por isso a
# guarda é sobre a lista, e em test ela continua vazia de propósito (o harness
# usa hosts sintéticos como testcitya.rotasaude.app).
#
# PlatformHosts fica em lib/, não em app/services/, e é require`ado explicitamente
# aqui e em config/environments/production.rb: aquele arquivo roda antes do
# Zeitwerk (Finisher), então não pode depender do autoloader nem para si mesmo
# nem para nada que ele referencie (F1 do fix pass — era exatamente esse boot
# que caía com "uninitialized constant PlatformHosts").
RSpec.describe PlatformHosts do
  # Mesmo idioma de stub do spec/requests/cors_spec.rb: o template público é a
  # única fonte do domínio, então é dele que os hosts derivam.
  def with_production_template
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
      .and_return("https://%{slug}.rota-saude.example")
    yield
  end

  it "declares the platform domain and the city wildcard in production" do
    with_production_template do
      expect(described_class.for("production")).to eq([ "rota-saude.example", ".rota-saude.example" ])
    end
  end

  it "stays empty outside production, where the harness uses synthetic hosts" do
    with_production_template do
      expect(described_class.for("test")).to eq([])
      expect(described_class.for("development")).to eq([])
    end
  end

  it "raises instead of silently disabling the guard when the derived domain is blank" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything).and_return("%{slug}")

    expect { described_class.for("production") }.to raise_error(PlatformHosts::BlankDomain)
  end

  # O modo de falha que o BlankDomain NÃO cobre: um template em que o slug não é
  # o primeiro rótulo do host produz um domínio errado em vez de vazio, então a
  # guarda anterior passa e produção sobe com config.hosts MENTIROSO — aceitando
  # um domínio que não é nosso e recusando os que são. Falha aberta disfarçada de
  # sucesso, que é a classe de defeito que este módulo inteiro existe para negar.
  it "raises when the slug is not the leading label, instead of deriving a wrong domain" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("CITY_PUBLIC_BASE_TEMPLATE", anything)
      .and_return("https://%{slug}-cidades.rota-saude.example")

    expect { described_class.for("production") }.to raise_error(PlatformHosts::UnexpectedTemplate, /x-cidades/)
  end
end
