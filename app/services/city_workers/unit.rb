module CityWorkers
  # Um supervisor Solid Queue gerido pelo Manager: o da plataforma ou o de uma
  # cidade (Plano 5). Cada tipo tem sua configuração de filas e de recorrência.
  Unit = Data.define(:kind, :city_slug) do
    def self.platform = new(kind: :platform, city_slug: nil)
    def self.city(slug) = new(kind: :city, city_slug: slug)

    def key = kind == :platform ? "platform" : "city:#{city_slug}"
    def config_file = kind == :platform ? "config/queue_platform.yml" : "config/queue.yml"
    def recurring_schedule_file = kind == :platform ? "config/recurring_platform.yml" : "config/recurring.yml"
  end
end
