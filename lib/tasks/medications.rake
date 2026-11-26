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

  # O portal OBM não tem API nem download automático (contrato 27b, Q12): o
  # operador da plataforma baixa o arquivo e o entrega por aqui. O mapa de
  # colunas é config/medications/obm_columns.yml. Nada do arquivo vai à saída.
  desc "Carrega o arquivo do OBM (CSV): apresentações e o VMP dos itens do catálogo"
  task :import_obm, [ :path ] => :environment do |_task, args|
    path = args[:path].to_s
    abort("[medications] uso: rake medications:import_obm[caminho/do/arquivo.csv]") if path.empty?
    abort("[medications] arquivo não encontrado: #{path}") unless File.file?(path)

    result = Medications::ObmImport.call(csv: File.binread(path, Medications::ObmImport::MAX_BYTES + 1), by: "system")
    if result.failure?
      # Q47: as primeiras 20 linhas recusadas, só posição e código.
      refused = Array(result.details&.dig(:rejected_lines)).map do |r|
        "linha #{r[:line]} coluna #{r[:column] || '-'}: #{r[:code]}"
      end
      abort(([ "[medications] OBM: #{result.reason} #{result.message}" ] + refused).join("\n"))
    end
    counts = result.payload
    puts "[medications] OBM: +#{counts[:added]} ~#{counts[:changed]} -#{counts[:deactivated]}; " \
         "VMP ligado a #{counts[:vmp_linked]} itens; #{counts[:unmatched]} sem item no catálogo"
  end
end
