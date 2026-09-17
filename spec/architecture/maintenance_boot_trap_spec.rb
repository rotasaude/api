require "rails_helper"

# I7 (fix round 2): a trava de boot (spec §5) era provada só como função pura —
# spec/lib/maintenance_api_spec.rb testa MaintenanceApi.check_boot! em isolamento.
# Apagar config/initializers/01_maintenance_api.rb não quebrava spec nenhum, e a
# função ficaria correta e nunca chamada: a API subiria em produção com a chave
# ligada. A suíte roda em test, então o que se prova aqui é o FIO — que o
# initializer existe e chama a trava.
RSpec.describe "Maintenance API boot trap" do
  INITIALIZER = Rails.root.join("config/initializers/01_maintenance_api.rb")

  it "exists as an initializer and calls the boot check" do
    expect(INITIALIZER).to exist

    expect(INITIALIZER.read).to match(/MaintenanceApi\.check_boot!/)
  end

  # O prefixo 01_ não é enfeite: os initializers rodam em ordem alfabética, e
  # esta trava precisa rodar antes de qualquer um que monte rota ou abra
  # conexão. 00_ é a checagem de credentials.
  it "runs before the initializers that mount anything" do
    expect(INITIALIZER.basename.to_s).to start_with("01_")
  end
end
