namespace :surveillance do
  desc "Carrega a lista nacional de notificação compulsória (versão 1; idempotente; nunca sobrescreve a curadoria)."
  task load_disease_list: :environment do
    result = Surveillance::DiseaseList::Load.call
    puts "[surveillance:load_disease_list] versões criadas: #{result[:created]}"
  end
end
