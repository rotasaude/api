namespace :lab do
  namespace :templates do
    desc "Carrega o catálogo-base de exames de laboratório (idempotente; nunca sobrescreve)."
    task load: :environment do
      result = Lab::Templates::Load.call
      puts "[lab:templates:load] criados: #{result[:created]}; fora da SIGTAP ativa: #{result[:skipped].join(', ').presence || 'nenhum'}"
    end
  end
end
