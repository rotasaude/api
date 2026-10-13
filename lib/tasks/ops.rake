# Operação (api#74): conta de conexões do Postgres para N cidades.
# Uso: bin/rails 'ops:connection_budget[5]'. Runbook: docs/operacao/conexoes-postgres.md.
namespace :ops do
  desc "Orçamento de conexões do Postgres para N cidades (pico, por parte)"
  task :connection_budget, [ :cities ] => :environment do |_task, args|
    cities = Integer(args[:cities].to_s, exception: false)
    unless cities&.positive?
      warn "uso: bin/rails 'ops:connection_budget[5]'"
      exit 1
    end
    puts Ops::ConnectionBudget.report(cities)
  end
end
