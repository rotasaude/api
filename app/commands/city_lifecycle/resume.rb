# Retoma uma cidade suspensa (spec banco-por-cidade §4). Se o schema dela ficou
# para trás durante a suspensão, o resolver responde 503 até city:migrate:all.
module CityLifecycle
  module Resume
    def self.call(city:)
      unless city.status == "suspended"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} não está suspended (status=#{city.status})")
      end

      PlatformRecord.transaction do
        city.update!(status: "active")
        Platform.audit("city.resumed", city_id: city.id)
      end
      CityCatalog.reset_cache!
      Result.ok(city: city)
    end
  end
end
