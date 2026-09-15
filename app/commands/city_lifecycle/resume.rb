# Retoma uma cidade suspensa (spec banco-por-cidade §4). Se o schema dela ficou
# para trás durante a suspensão, o resolver responde 503 até city:migrate:all.
module CityLifecycle
  module Resume
    def self.call(city:)
      unless city.status == "suspended"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} não está suspended (status=#{city.status})")
      end

      # Transição guardada: só muda a linha que AINDA está suspended.
      changed = false
      PlatformRecord.transaction do
        guard = City.where(id: city.id, status: "suspended").update_all(status: "active", updated_at: Time.current)
        raise ActiveRecord::Rollback if guard.zero?

        Platform.audit("city.resumed", city_id: city.id)
        changed = true
      end
      return Result.fail(:invalid_status, message: "cidade #{city.slug} mudou de status durante a operação") unless changed

      city.reload
      CityCatalog.reset_cache!
      Result.ok(city: city)
    end
  end
end
