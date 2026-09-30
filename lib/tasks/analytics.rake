# lib/tasks/analytics.rake
# Rebuild do Analytics por cidade (ADR 0025; spec 2026-09-30 §4.3, §12). Roda
# na conexão da cidade (CityConnection.with — nunca Current.city solto). Sem
# `from`: desde o cru mais antigo; sem `to`: ontem. Rollout: depois de
# city:migrate:all, city:analytics:rebuild:all.
namespace :city do
  namespace :analytics do
    # Lambda (não método): um `def` dentro de `namespace` vaza para o escopo
    # top-level do processo Rake (mesma razão de lib/tasks/city.rake).
    analytics_rebuild = lambda do |city, from, to|
      parse = ->(value) { value.presence && Date.iso8601(value) }
      report = CityConnection.with(city) { Analytics::Rebuild.call(from: parse.call(from), to: parse.call(to)) }
      raise "#{city.slug}: outra consolidação em curso — tente de novo" if report.busy
      if report.runs.empty?
        puts "[city:analytics:rebuild] #{city.slug}: sem dado cru a consolidar"
        next
      end

      puts "[city:analytics:rebuild] #{city.slug}: #{report.runs.size} blocos de #{report.from} a #{report.to}, " \
           "#{report.runs.count { |run| run.published_at.nil? }} sem publicação"
      if report.failed
        raise "#{city.slug}: bloco #{report.failed.window_from}..#{report.failed.window_to} falhou — " \
              "#{report.failed.error}"
      end
    end

    desc "Reconsolida o Analytics de uma cidade. Uso: city:analytics:rebuild[slug,from,to] (datas AAAA-MM-DD, opcionais)"
    task :rebuild, %i[slug from to] => :environment do |_t, args|
      abort "uso: rails 'city:analytics:rebuild[slug,from,to]'" if args[:slug].blank?
      city = City.find_by(slug: args[:slug]) || abort("[city:analytics:rebuild] cidade #{args[:slug]} não existe")
      abort "[city:analytics:rebuild] cidade #{city.slug} não está active" unless city.servable?
      abort "[city:analytics:rebuild] #{city.slug} com schema atrasado — rode city:migrate:all" if CitySchema.behind?(city)

      analytics_rebuild.call(city, args[:from], args[:to])
    rescue Date::Error
      abort "[city:analytics:rebuild] data inválida (use AAAA-MM-DD)"
    rescue RuntimeError => e
      abort "[city:analytics:rebuild] #{e.message}"
    end

    namespace :rebuild do
      desc "Reconsolida o Analytics de toda cidade active. Uso: city:analytics:rebuild:all[from,to]"
      task :all, %i[from to] => :environment do |_t, args|
        failed = []
        City.where(status: "active").order(:slug).each do |city|
          raise "schema atrasado — rode city:migrate:all" if CitySchema.behind?(city)

          analytics_rebuild.call(city, args[:from], args[:to])
        rescue StandardError => e
          failed << city.slug
          warn "[city:analytics:rebuild:all] #{city.slug} falhou — #{e.class}: #{e.message}"
        end
        abort "[city:analytics:rebuild:all] falharam: #{failed.join(', ')}" if failed.any?
      end
    end
  end
end
