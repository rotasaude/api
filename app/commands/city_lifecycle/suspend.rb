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

      PlatformRecord.transaction do
        city.update!(status: "suspended")
        Platform.audit("city.suspended", city_id: city.id)
      end
      CityConnection.forget(city.shard)
      CityCatalog.reset_cache!
      Result.ok(city: city)
    end
  end
end
