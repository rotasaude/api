# Suspende uma cidade (spec banco-por-cidade §4): o resolver passa a responder 403
# city_suspended, EachCityJob deixa de rodá-la e CityScopedJob levanta
# CityNotServable. Nada é apagado; CityLifecycle::Resume desfaz.
#
# Este processo derruba o pool na hora. Os demais convergem pelo TTL do
# CityCatalog (30 s): até lá ainda servem a cidade.
module CityLifecycle
  module Suspend
    def self.call(city:)
      unless city.status == "active"
        return Result.fail(:invalid_status, message: "cidade #{city.slug} não está active (status=#{city.status})")
      end

      # Transição guardada: só muda a linha que AINDA está active (outro processo
      # pode ter mudado o status depois que esta cidade foi carregada).
      changed = false
      PlatformRecord.transaction do
        guard = City.where(id: city.id, status: "active").update_all(status: "suspended", updated_at: Time.current)
        raise ActiveRecord::Rollback if guard.zero?

        Platform.audit("city.suspended", city_id: city.id)
        changed = true
      end
      return Result.fail(:invalid_status, message: "cidade #{city.slug} mudou de status durante a operação") unless changed

      city.reload
      CityConnection.forget(city.shard)
      CityCatalog.reset_cache!
      Result.ok(city: city)
    end
  end
end
