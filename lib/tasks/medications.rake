# lib/tasks/medications.rake
# Catálogo de medicamentos da plataforma (ADR 0033). O caminho normal é o
# maintenance (importMedicationCatalog / importAnvisaLists); estas tarefas
# servem à operação e ao primeiro provisionamento. As listas Anvisa ANTES do
# catálogo (as marcas saem delas).
namespace :medications do
  desc "Importa as listas da Anvisa de config/medications/anvisa"
  task import_anvisa: :environment do
    result = Medications::AnvisaImport.call(by: "rake")
    abort("[medications] listas: #{result.reason} #{result.message}") if result.failure?
    puts "[medications] listas ativas: #{result.payload[:antimicrobials]} antimicrobianos, #{result.payload[:controlled]} controlados"
  end

  desc "Importa o CATMAT classe 6505 da API aberta do Compras.gov"
  task import_catmat: :environment do
    result = Medications::CatalogImport.call(by: "rake")
    abort("[medications] catálogo: #{result.reason} #{result.message}") if result.failure?
    puts "[medications] catálogo ativo: +#{result.payload[:added]} ~#{result.payload[:changed]} -#{result.payload[:removed]}"
  end
end
