# Semente de bairros por cidade (ADR 0023; spec 2026-09-28 §3.4). Roda na
# cidade pela conexão dela (CityConnection.with — nunca Current.city solto).
# Idempotente: cria só o que falta. Sem arquivo para a cidade: mensagem e
# saída sem erro. Rollout: depois de city:migrate:all.
namespace :city do
  namespace :territory do
    # Lambda (não método): um `def` dentro de `namespace` vaza para o escopo
    # top-level do processo Rake (mesma razão de lib/tasks/city.rake).
    territory_seed = lambda do |city|
      path = Territory::Seed.path_for(city.slug)
      unless File.file?(path)
        puts "[city:territory:seed] #{city.slug}: sem semente (db/seeds/territory/#{city.slug}.yml) — nada a fazer"
        next
      end

      report = CityConnection.with(city) { Territory::Seed.call(path: path) }
      report.warnings.each { |warning| puts "[city:territory:seed] #{city.slug}: aviso — #{warning}" }
      puts "[city:territory:seed] #{city.slug}: #{report.created} criados, #{report.existing} já existentes, " \
           "#{report.warnings.size} avisos"
    end

    desc "Carrega a semente de bairros de uma cidade (idempotente). Uso: city:territory:seed[slug]"
    task :seed, %i[slug] => :environment do |_t, args|
      abort "uso: rails 'city:territory:seed[slug]'" if args[:slug].blank?
      city = City.find_by(slug: args[:slug]) || abort("[city:territory:seed] cidade #{args[:slug]} não existe")
      abort "[city:territory:seed] cidade #{city.slug} está archived — não tem banco" if city.status == "archived"

      territory_seed.call(city)
    end

    namespace :seed do
      desc "Carrega a semente de bairros de toda cidade active/suspended (idempotente)."
      task all: :environment do
        failed = []
        City.where(status: %w[active suspended]).order(:slug).each do |city|
          territory_seed.call(city)
        rescue StandardError => e
          failed << city.slug
          warn "[city:territory:seed:all] #{city.slug} falhou — #{e.class}"
        end
        abort "[city:territory:seed:all] falharam: #{failed.join(', ')}" if failed.any?
      end
    end
  end
end
