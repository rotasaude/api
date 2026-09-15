module CityWorkers
  # O que roda dentro do fork de uma unidade (spec §4, spike 2): liga o Solid Queue
  # ao banco certo e entra no supervisor.
  #   - cidade: o padrão do SolidQueue::Record passa a ser o banco da cidade para o
  #     processo inteiro (todas as threads do supervisor e dos workers que ele
  #     forka), e CityWorkers::Context marca a cidade do processo;
  #   - plataforma: o padrão já é o banco de plataforma (config.solid_queue.connects_to).
  # Uma cidade que deixou de estar active, ou atrasou o schema, entre a leitura do
  # catálogo e o fork levanta CityUnavailable: o filho sai com erro, o Manager
  # espera o backoff e a tira no próximo poll.
  module Child
    class CityUnavailable < StandardError; end

    module_function

    def run(unit)
      SolidQueue::Supervisor.start(**prepare(unit))
    end

    def prepare(unit)
      Process.setpgid(0, 0)

      if unit.kind == :city
        city = City.find_by(slug: unit.city_slug)
        unless city&.servable? && !CitySchema.behind?(city)
          raise CityUnavailable, "cidade #{unit.city_slug} fora do ar ou com schema atrasado"
        end

        CityWorkers::Context.city_slug = city.slug
        CityConnection.ensure_pool(city)
        SolidQueue::Record.establish_connection(CityConnection.database_config(city))
      end

      {
        mode: :fork,
        config_file: Rails.root.join(unit.config_file),
        recurring_schedule_file: Rails.root.join(unit.recurring_schedule_file)
      }
    end
  end
end
