# Tela de manutenção de development: lista a configuração de todas as cidades
# registradas. Rota desenhada SÓ em development (config/routes.rb) — fora de dev
# ela não existe, e a garantia é o roteador, não um before_action aqui.
#
# Herda de ActionController::Base, e não de ApplicationController: a aplicação é
# `config.api_only = true`, então ApplicationController é ActionController::API e
# não renderiza view. As views que existem hoje são todas de mailer (o
# ActionMailer traz o próprio stack de renderização, independente do api_only).
# Este é o único controller do projeto que serve HTML.
#
# Sem autenticação por decisão explícita: é ferramenta de desenvolvimento. O que
# torna isso defensável não é a ausência de dado sensível na tela — é a rota não
# existir fora de dev. Ver spec/architecture/maintenance_route_spec.rb.
#
# Três linhas de propósito: toda a inteligência mora em CityInventory, que a
# suíte alcança sem rota nenhuma (a suíte roda em test, onde esta rota não
# existe). Se algo aqui crescer além de chamar o inventário, o lugar certo é lá.
class MaintenanceController < ActionController::Base
  layout false

  def index
    @cities = CityInventory.call
    @console = CityInventory.console
    @expected_version = CitySchema.expected_version
  end
end
