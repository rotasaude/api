# Operação (api#74): conta de conexões do Postgres para N cidades.
# Uso: bin/rails 'ops:connection_budget[5]'. Runbook: docs/operacao/conexoes-postgres.md.
namespace :ops do
  desc "Orçamento de conexões do Postgres para N cidades (pico, por parte)"
  task :connection_budget, [ :cities ] => :environment do |_task, args|
    cities = Integer(args[:cities].to_s, 10, exception: false)
    unless cities&.positive?
      warn "uso: bin/rails 'ops:connection_budget[5]'"
      exit 1
    end
    puts Ops::ConnectionBudget.report(cities)
  end
end

namespace :ops do
  # api#74: realinha o CONNECTION LIMIT dos roles das cidades já provisionadas ao
  # CITY_ROLE_CONNECTION_LIMIT atual. Roda no host de worker (precisa da credencial
  # do provisioner): kamal app exec --roles=worker "bin/rails ops:align_city_role_limits".
  desc "Realinha o teto de conexões dos roles de cidade ao CITY_ROLE_CONNECTION_LIMIT"
  task align_city_role_limits: :environment do
    City.order(:slug).each do |city|
      limit = CityDatabase.align_connection_limit!(slug: city.slug)
      puts(limit ? "#{city.slug}: CONNECTION LIMIT #{limit}" : "#{city.slug}: role não existe (nada feito)")
    end
  end
end
