require "rails_helper"

# Plano 6: o proxy do Kamal precisa aceitar o console e o callback do gov.br,
# e algum jeito de servir cidade.
#
# README.md "Hosts publicados (Plano 6)", opção (1), instrui o operador a
# tirar a linha "*.<domínio>" e listar cada host de cidade explicitamente —
# exigir SEMPRE o curinga (como esta spec fazia antes) deixa a suíte vermelha
# pra quem seguir a própria documentação (fix wave, Important #3). A spec
# agora aceita as duas opções do README: curinga OU pelo menos um host de
# cidade além de api/console/auth.
RSpec.describe "Kamal proxy hosts" do
  %w[development production].each do |env|
    it "publishes console and auth hosts on the right domain, plus a wildcard or an explicit city host, in #{env}" do
      config = YAML.load_file(Rails.root.join("deploy/#{env}/deploy.yml"))
      hosts = config.fetch("proxy").fetch("hosts")

      admin_host = hosts.find { |h| h.start_with?("admin.") }
      auth_host  = hosts.find { |h| h.start_with?("auth.") }
      expect(admin_host).not_to be_nil, "sem host do console em #{env}"
      expect(auth_host).not_to be_nil, "sem host do callback gov.br em #{env}"

      # Domínio completo, não só o prefixo "admin."/"auth.": um host apontando
      # pro domínio errado precisa quebrar aqui. O primeiro host da lista é o
      # próprio app (api.<domínio> em produção, dev.<domínio> em development);
      # o domínio dele, sem o primeiro rótulo, é o sufixo que os demais hosts
      # precisam ter.
      api_host = hosts.first
      domain = api_host.sub(/\A[^.]+\./, "")
      expect(admin_host).to end_with(domain), "console em domínio errado em #{env}: #{admin_host}"
      expect(auth_host).to end_with(domain), "callback gov.br em domínio errado em #{env}: #{auth_host}"

      wildcard_present = hosts.any? { |h| h.start_with?("*.") }
      explicit_city_host_present = hosts.any? do |h|
        h != api_host && h != admin_host && h != auth_host && !h.start_with?("*.")
      end
      expect(wildcard_present || explicit_city_host_present).to be(true),
        "nem curinga nem host de cidade explícito em #{env} (README opção 1 exige pelo menos um dos dois)"

      expect(config.fetch("proxy")).not_to have_key("host")
    end
  end
end
