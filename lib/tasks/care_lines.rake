namespace :care_lines do
  namespace :templates do
    desc "Carrega o catálogo-base das linhas de cuidado C2–C7 (idempotente; nunca sobrescreve)."
    task load: :environment do
      result = CareLines::Templates::Load.call
      puts "[care_lines:templates:load] versões criadas: #{result[:created]}"
    end
  end
end
