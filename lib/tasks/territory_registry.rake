# Módulo 24a (ADR 0042; Desvio 1): preenche patients.match_key (chave cega de
# duplicados) dos pacientes gravados antes da migração 20261023900001. Roda
# na conexão de cada cidade (CityConnection.with — nunca Current.city solto).
# Idempotente: só regrava quem está sem chave ou com chave diferente.
# Imprime só contagens — nunca nome, nascimento ou chave.
#
#   bin/rails patients:backfill_match_keys          # toda cidade active/suspended
#   bin/rails 'patients:backfill_match_keys[slug]'  # uma cidade
namespace :patients do
  desc "Preenche a chave cega de duplicados dos pacientes (idempotente). Uso: patients:backfill_match_keys[slug]"
  task :backfill_match_keys, %i[slug] => :environment do |_t, args|
    cities = args[:slug].present? ? City.where(slug: args[:slug]) : City.where(status: %w[active suspended])
    abort "[patients:backfill_match_keys] cidade #{args[:slug]} não existe" if args[:slug].present? && cities.none?

    failed = []
    cities.order(:slug).each do |city|
      filled = 0
      total = 0
      CityConnection.with(city) do
        Patient.find_each do |patient|
          total += 1
          key = Patients::MatchKey.for(patient.full_name, patient.birth_date)
          next if patient.match_key == key

          patient.update_columns(match_key: key)
          filled += 1
        end
      end
      puts "[patients:backfill_match_keys] #{city.slug}: #{total} pacientes, #{filled} preenchidas"
    rescue StandardError => e
      failed << city.slug
      warn "[patients:backfill_match_keys] #{city.slug} falhou — #{e.class}"
    end
    abort "[patients:backfill_match_keys] falharam: #{failed.join(', ')}" if failed.any?
  end
end
