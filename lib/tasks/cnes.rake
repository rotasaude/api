# lib/tasks/cnes.rake
# Importação da base mensal do CNES pelo operador (ADR 0028; spec 2026-10-05
# §5). path: BASE_DE_DADOS_CNES_AAAAMM.ZIP ou a pasta extraída. A saída nunca
# leva CPF nem CNS.
namespace :cnes do
  desc "Importa a base mensal do CNES para as cidades ativas. Uso: cnes:import[AAAAMM,path]"
  task :import, %i[competence path] => :environment do |_t, args|
    abort "uso: rails 'cnes:import[AAAAMM,path]'" if args[:competence].blank? || args[:path].blank?

    result = Cnes::Import.call(competence: args[:competence], path: args[:path])
    abort "[cnes:import] #{result.reason} #{result.message} #{result.details}".strip if result.failure?

    result.payload[:imported].each do |ibge, counts|
      puts "[cnes:import] #{ibge}: #{counts[:establishments]} estabelecimentos, #{counts[:teams]} equipes, " \
           "#{counts[:bonds]} vínculos"
    end
    result.payload[:skipped].each { |s| puts "[cnes:import] #{s[:slug]} pulada (#{s[:reason]})" }
  end
end
