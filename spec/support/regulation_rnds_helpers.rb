require_relative "../../lib/fake_rnds/app"

# Módulo 26c (Task 10): cidade com o envio da regulação à RNDS e o simulado
# (FakeRnds::App) servido por WebMock#to_rack em http://fake-rnds.test:8094.
# Nenhuma spec bate em URL real. A credencial `rnds_regulation` é a do
# VaccinationHelpers#rnds_regulation_credential! (o PFX autoassinado mora lá).
module RegulationRndsHelpers
  FAKE_RNDS_URL = "http://fake-rnds.test:8094".freeze

  # Liga o simulado (um novo, ou o passado) e aponta o FAKE_RNDS_URL para ele;
  # devolve a instância (o `log` mostra o que chegou).
  def fake_rnds!(app = FakeRnds::App.new(timeout_delay: 0))
    Rnds::Client.reset_cache!
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FAKE_RNDS_URL").and_return(FAKE_RNDS_URL)
    stub_request(:any, /\A#{Regexp.escape(FAKE_RNDS_URL)}/).to_rack(app)
    app
  end

  # A cidade da regulação (regulation_city!) com IBGE/UF, a credencial
  # `rnds_regulation`, a linha de ajustes e o interruptor `rnds_regulation`
  # ligado; com `mock`, também o `rnds_mock` (use com fake_rnds!).
  def rnds_regulation_city!(mock: true)
    city = regulation_city!
    city_profile!.update!(ibge_code: "4106902", uf: "PR")
    rnds_regulation_credential!
    RegulationRndsSetting.ensure_defaults!
    maintainer = ledi_maintainer!
    keys = [ Regulation::RndsGate::KEY ]
    keys << "rnds_mock" if mock
    keys.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
    CityCatalog.reset_cache!
    city
  end

  # Ajustes do envio pelo comando real (versão atual; os padrões no resto).
  def rnds_settings!(**over)
    current = RegulationRndsSetting.current
    attrs = { "expected_version" => current.version, "priority_by_color" => current.priority_by_color,
              "specialty_sigtap" => current.specialty_sigtap, "send_external" => current.send_external }
    result = Regulation::SaveRndsSettings.call(attrs: attrs.merge(over.transform_keys(&:to_s)), by: regulation_admin!)
    raise "ajustes recusados: #{result.reason} #{result.details}" if result.failure?

    RegulationRndsSetting.current
  end
end

RSpec.configure { |c| c.include RegulationRndsHelpers }
